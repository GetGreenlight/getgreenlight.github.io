#!/bin/bash
# Greenlight - Permission Hook for Claude Code
# Forwards permission requests to the Greenlight relay server.
#
# Usage: greenlight-hook.sh --device-id ID --project NAME
#
# Install:
#   curl -o ~/greenlight-hook.sh https://getgreenlight.github.io/greenlight-hook.sh
#   chmod +x ~/greenlight-hook.sh

# Defaults
DEVICE_ID=""
GREENLIGHT_SERVER=${GREENLIGHT_SERVER-"https://permit.dnmfarrell.com"}
TIMEOUT="595"
PROJECT=""

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
        *)
            shift
            ;;
    esac
done

# Fall back to environment variable if arg not provided
DEVICE_ID="${DEVICE_ID:-$GREENLIGHT_DEVICE_ID}"

if ! command -v jq >/dev/null 2>&1; then
    cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Greenlight hook requires jq but it's not installed. Install it with: brew install jq (macOS) or apt-get install jq (Linux)"
    }
  }
}
EOF
    exit 0
fi

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

if [ -z "$PROJECT" ]; then
    cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Greenlight hook is missing the --project flag. Add --project PROJECT_NAME to the hook command in .claude/settings.json hooks config. See https://getgreenlight.github.io/guide-claude-code.html"
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
    local path="$1" session_id="$2" device_id="$3" project="$4" server="$5" relay_id="$6"
    local pid_file="/tmp/greenlight-stream-${session_id}.pid"
    local tail_pid_file="/tmp/greenlight-tail-${session_id}.pid"

    local pipe="/tmp/greenlight-pipe-${session_id}"
    rm -f "$pipe"
    mkfifo "$pipe"

    # Start tail writing to named pipe so we can track and kill it
    # Read last 50 lines for backfill, then follow for new entries
    tail -n 50 -f "$path" > "$pipe" 2>/dev/null &
    local tail_pid=$!
    echo "$tail_pid" > "$tail_pid_file"

    trap 'kill '"$tail_pid"' 2>/dev/null; rm -f "'"$pid_file"'" "'"$tail_pid_file"'" "'"$pipe"'"' EXIT

    while IFS= read -r -t 300 line; do
        [ -z "$line" ] && continue
        # Send raw JSONL line with metadata; server handles parsing
        # Construct JSON directly — no jq dependency, transcript lines are valid JSON
        PAYLOAD="{\"device_id\":\"${device_id}\",\"session_id\":\"${session_id}\",\"project\":\"${project}\",\"relay_id\":\"${relay_id}\",\"data\":${line}}"

        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "${server}/transcript" 2>/dev/null)

        # Exit on fatal client errors (session deleted, unauthorized, etc.)
        # Keep going on 429 (rate limit) and 5xx (transient server errors)
        if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" -ge 400 ] 2>/dev/null && [ "$HTTP_CODE" -lt 500 ] 2>/dev/null && [ "$HTTP_CODE" != "429" ]; then
            break
        fi
    done < "$pipe"
}

# Enroll session with the server. Uses a marker file to avoid re-enrollment.
# Returns 0 on success or if already enrolled, 1 on failure.
enroll_session() {
    local relay_id="$1" device_id="$2" server="$3"
    local marker="/tmp/greenlight-enrolled-${relay_id}"

    # Already enrolled this session
    if [ -f "$marker" ]; then
        return 0
    fi

    local payload
    payload=$(jq -n \
        --arg did "$device_id" \
        --arg sid "$relay_id" \
        '{device_id: $did, session_id: $sid}')

    local response
    response=$(curl -s --max-time 65 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${server}/session/enroll")

    local approved
    approved=$(echo "$response" | jq -r '.approved // false')
    if [ "$approved" = "true" ]; then
        touch "$marker"
        return 0
    fi
    return 1
}

# Start or restart the transcript streamer if needed.
# Checks PID file and relay_id to avoid duplicates or stale streamers.
maybe_start_streamer() {
    local transcript_path="$1" session_id="$2" relay_id="$3"

    [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ] || [ -z "$session_id" ] && return

    local pid_file="/tmp/greenlight-stream-${session_id}.pid"
    local need_stream=1

    if [ -f "$pid_file" ]; then
        local existing_pid existing_relay
        existing_pid=$(awk '{print $1}' "$pid_file" 2>/dev/null)
        existing_relay=$(awk '{print $2}' "$pid_file" 2>/dev/null)
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            if [ "$existing_relay" = "$relay_id" ]; then
                need_stream=0
            else
                # Relay ID changed — kill old streamer
                kill "$existing_pid" 2>/dev/null
                local tail_pid_file="/tmp/greenlight-tail-${session_id}.pid"
                if [ -f "$tail_pid_file" ]; then
                    kill "$(cat "$tail_pid_file")" 2>/dev/null
                    rm -f "$tail_pid_file"
                fi
            fi
        fi
    fi

    if [ "$need_stream" = "1" ]; then
        local tail_pid_file="/tmp/greenlight-tail-${session_id}.pid"
        if [ -f "$tail_pid_file" ]; then
            kill "$(cat "$tail_pid_file")" 2>/dev/null
            rm -f "$tail_pid_file"
        fi
        rm -f "/tmp/greenlight-pipe-${session_id}"
        stream_transcript "$transcript_path" "$session_id" "$DEVICE_ID" "$PROJECT" "$GREENLIGHT_SERVER" "$relay_id" </dev/null >/dev/null 2>&1 &
        echo "$! $relay_id" > "$pid_file"
        disown
    fi
}

# Read hook input from stdin
INPUT=$(cat)

# Detect hook event type
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PermissionRequest"')

# Derive relay_id: prefer REMUX_ID (remux session), fall back to Claude session_id
RELAY_ID="${REMUX_ID:-}"
if [ -z "$RELAY_ID" ]; then
    RELAY_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
fi

if [ "$HOOK_EVENT" = "UserPromptSubmit" ]; then
    # UserPromptSubmit: start transcript streamer early, before Claude processes
    if [ -n "$RELAY_ID" ]; then
        TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

        # Enroll eagerly before starting streamer
        enroll_session "$RELAY_ID" "$DEVICE_ID" "$GREENLIGHT_SERVER"

        maybe_start_streamer "$TRANSCRIPT_PATH" "$SESSION_ID" "$RELAY_ID"
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

# Fork transcript streamer if not already running
if [ -n "$RELAY_ID" ]; then
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

    # Enroll eagerly before starting streamer
    enroll_session "$RELAY_ID" "$DEVICE_ID" "$GREENLIGHT_SERVER"

    maybe_start_streamer "$TRANSCRIPT_PATH" "$SESSION_ID" "$RELAY_ID"
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

# Session not enrolled — enroll and retry
if [ "$HTTP_CODE" = "401" ] && [ -n "$RELAY_ID" ]; then
    # Clear marker in case it's stale
    rm -f "/tmp/greenlight-enrolled-${RELAY_ID}"
    if enroll_session "$RELAY_ID" "$DEVICE_ID" "$GREENLIGHT_SERVER"; then
        # Retry the request
        HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time "$TIMEOUT" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "${GREENLIGHT_SERVER}/request")
        CURL_EXIT=$?
        HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
        RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

        if [ $CURL_EXIT -ne 0 ] || [ -z "$RESPONSE" ]; then
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
    else
        cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Greenlight session enrollment was rejected"
    }
  }
}
EOF
        exit 0
    fi
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
