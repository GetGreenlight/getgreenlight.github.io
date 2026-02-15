#!/bin/bash
# Greenlight - Permission Hook for Claude Code
# Forwards permission requests to the Greenlight relay server.
#
# Usage: greenlight-hook.sh --device-id ID [--project NAME] [--activity]
#
# Install:
#   curl -o ~/greenlight-hook.sh https://getgreenlight.github.io/greenlight-hook.sh
#   chmod +x ~/greenlight-hook.sh

# Defaults
DEVICE_ID=""
GREENLIGHT_SERVER=${GREENLIGHT_SERVER-"https://permit.dnmfarrell.com"}
TIMEOUT="595"
PROJECT=""
ACTIVITY=""
RELAY_ID="${PERMIT_RELAY_ID:-}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --device-id)
            DEVICE_ID="$2"
            shift 2
            ;;
        --server)
            GREENLIGHT_SERVER="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --activity)
            ACTIVITY="1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Fall back to environment variable if arg not provided
DEVICE_ID="${DEVICE_ID:-$GREENLIGHT_DEVICE_ID}"

if [ -z "$DEVICE_ID" ]; then
    cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Greenlight device ID not configured. See https://getgreenlight.github.io/support.html"
    }
  }
}
EOF
    exit 0
fi

# Stream transcript in the background. Tails the JSONL transcript file,
# extracts summaries, and POSTs them to the server. PID-guarded so only
# one streamer runs per session. Caller writes PID file using $!.
stream_transcript() {
    local path="$1" session_id="$2" device_id="$3" project="$4" server="$5"
    local pid_file="/tmp/greenlight-stream-${session_id}.pid"
    local tail_pid_file="/tmp/greenlight-tail-${session_id}.pid"

    local pipe="/tmp/greenlight-pipe-${session_id}"
    rm -f "$pipe"
    mkfifo "$pipe"

    # Start tail writing to named pipe so we can track and kill it
    tail -n 0 -f "$path" > "$pipe" 2>/dev/null &
    local tail_pid=$!
    echo "$tail_pid" > "$tail_pid_file"

    trap 'kill '"$tail_pid"' 2>/dev/null; rm -f "'"$pid_file"'" "'"$tail_pid_file"'" "'"$pipe"'"' EXIT

    while IFS= read -r -t 300 line; do
        [ -z "$line" ] && continue
        # Send raw JSONL line with metadata; server handles parsing
        # Construct JSON directly — no jq dependency, transcript lines are valid JSON
        PAYLOAD="{\"device_id\":\"${device_id}\",\"session_id\":\"${session_id}\",\"project\":\"${project}\",\"relay_id\":\"${RELAY_ID}\",\"data\":${line}}"

        curl -s --max-time 5 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "${server}/transcript" >/dev/null 2>&1 &
    done < "$pipe"
}

# Read hook input from stdin
INPUT=$(cat)

# Detect hook event type
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PermissionRequest"')

if [ "$HOOK_EVENT" = "UserPromptSubmit" ]; then
    # UserPromptSubmit: start transcript streamer early, before Claude processes
    if [ -n "$ACTIVITY" ]; then
        TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

        if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -n "$SESSION_ID" ]; then
            PID_FILE="/tmp/greenlight-stream-${SESSION_ID}.pid"
            NEED_STREAM=1

            if [ -f "$PID_FILE" ]; then
                EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
                if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
                    NEED_STREAM=0
                fi
            fi

            if [ "$NEED_STREAM" = "1" ]; then
                TAIL_PID_FILE="/tmp/greenlight-tail-${SESSION_ID}.pid"
                if [ -f "$TAIL_PID_FILE" ]; then
                    kill "$(cat "$TAIL_PID_FILE")" 2>/dev/null
                    rm -f "$TAIL_PID_FILE"
                fi
                rm -f "/tmp/greenlight-pipe-${SESSION_ID}"
                stream_transcript "$TRANSCRIPT_PATH" "$SESSION_ID" "$DEVICE_ID" "$PROJECT" "$GREENLIGHT_SERVER" </dev/null >/dev/null 2>&1 &
                echo "$!" > "$PID_FILE"
                disown
            fi
        fi
    fi
    exit 0
fi

if [ "$HOOK_EVENT" = "Notification" ]; then
    # Notification hook (idle_prompt, etc.): fire-and-forget to server
    NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')
    MESSAGE=$(echo "$INPUT" | jq -r '.message // empty')
    TITLE=$(echo "$INPUT" | jq -r '.title // empty')

    TOOL_INPUT=$(jq -n \
        --arg nt "$NOTIFICATION_TYPE" \
        --arg msg "$MESSAGE" \
        --arg title "$TITLE" \
        '{notification_type: $nt, message: $msg, title: $title}')

    if [ -n "$PROJECT" ]; then
        PAYLOAD=$(jq -n \
            --arg did "$DEVICE_ID" \
            --arg tn "$NOTIFICATION_TYPE" \
            --arg proj "$PROJECT" \
            --arg rid "$RELAY_ID" \
            --argjson ti "$TOOL_INPUT" \
            '{device_id: $did, tool_name: $tn, tool_input: $ti, project: $proj, relay_id: $rid, agent: "claude-code"}')
    else
        PAYLOAD=$(jq -n \
            --arg did "$DEVICE_ID" \
            --arg tn "$NOTIFICATION_TYPE" \
            --arg rid "$RELAY_ID" \
            --argjson ti "$TOOL_INPUT" \
            '{device_id: $did, tool_name: $tn, tool_input: $ti, relay_id: $rid, agent: "claude-code"}')
    fi

    # Send notification to server in background (don't block Claude)
    curl -s --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${GREENLIGHT_SERVER}/request" >/dev/null 2>&1 &

    exit 0
fi

# Only handle events we care about
if [ "$HOOK_EVENT" != "PermissionRequest" ] && [ "$HOOK_EVENT" != "Notification" ]; then
    exit 0
fi

# PermissionRequest hook: forward to server, optionally start transcript streamer

# Fork transcript streamer if --activity is set and not already running
if [ -n "$ACTIVITY" ]; then
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -n "$SESSION_ID" ]; then
        PID_FILE="/tmp/greenlight-stream-${SESSION_ID}.pid"
        NEED_STREAM=1

        if [ -f "$PID_FILE" ]; then
            EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
                NEED_STREAM=0
            fi
        fi

        if [ "$NEED_STREAM" = "1" ]; then
            # Kill any orphaned tail from a previous streamer
            TAIL_PID_FILE="/tmp/greenlight-tail-${SESSION_ID}.pid"
            if [ -f "$TAIL_PID_FILE" ]; then
                kill "$(cat "$TAIL_PID_FILE")" 2>/dev/null
                rm -f "$TAIL_PID_FILE"
            fi
            rm -f "/tmp/greenlight-pipe-${SESSION_ID}"
            stream_transcript "$TRANSCRIPT_PATH" "$SESSION_ID" "$DEVICE_ID" "$PROJECT" "$GREENLIGHT_SERVER" </dev/null >/dev/null 2>&1 &
            echo "$!" > "$PID_FILE"
            disown
        fi
    fi
fi

if [ -n "$PROJECT" ]; then
    PAYLOAD=$(echo "$INPUT" | jq --arg did "$DEVICE_ID" --arg proj "$PROJECT" --arg rid "$RELAY_ID" '. + {device_id: $did, project: $proj, relay_id: $rid, agent: "claude-code"}')
else
    PAYLOAD=$(echo "$INPUT" | jq --arg did "$DEVICE_ID" --arg rid "$RELAY_ID" '. + {device_id: $did, relay_id: $rid, agent: "claude-code"}')
fi

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time "$TIMEOUT" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${GREENLIGHT_SERVER}/request")
CURL_EXIT=$?

# Split response body and HTTP status code
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

# Check if curl succeeded
if [ $CURL_EXIT -ne 0 ] || [ -z "$RESPONSE" ]; then
    # Timeout or connection failure - deny and interrupt for safety
    cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Failed to reach Greenlight server (timeout or connection error)",
      "interrupt": true
    }
  }
}
EOF
    exit 2
fi

# Check for HTTP error status
if [ "$HTTP_CODE" -ge 400 ] 2>/dev/null; then
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Greenlight server error (HTTP $HTTP_CODE): $RESPONSE"
    }
  }
}
EOF
    exit 0
fi

# Check for error response
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
if [ -n "$ERROR" ]; then
    cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "$ERROR"
    }
  }
}
EOF
    exit 0
fi

# Parse the response
BEHAVIOR=$(echo "$RESPONSE" | jq -r '.behavior // "deny"')
MESSAGE=$(echo "$RESPONSE" | jq -r '.message // empty')
UPDATED_INPUT=$(echo "$RESPONSE" | jq '.updated_input // empty')
INTERRUPT=$(echo "$RESPONSE" | jq -r '.interrupt // false')

if [ "$BEHAVIOR" = "allow" ]; then
    if [ -n "$UPDATED_INPUT" ] && [ "$UPDATED_INPUT" != "null" ] && [ "$UPDATED_INPUT" != "" ]; then
        # AskUserQuestion with answers - include updatedInput
        jq -n --argjson ui "$UPDATED_INPUT" '{
          hookSpecificOutput: {
            hookEventName: "PermissionRequest",
            decision: {
              behavior: "allow",
              updatedInput: $ui
            }
          }
        }'
    else
        cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
EOF
    fi
else
    if [ "$INTERRUPT" = "true" ]; then
        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "${MESSAGE:-Permission denied}",
      "interrupt": true
    }
  }
}
EOF
    else
        cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "${MESSAGE:-Permission denied}"
    }
  }
}
EOF
    fi
fi
