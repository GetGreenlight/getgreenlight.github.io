#!/bin/bash
# Greenlight - Permission Hook for Claude Code
# Forwards permission requests to the Greenlight relay server.
#
# Usage: greenlight-hook.sh --device-id ID [--project NAME] [--timeout SECONDS]
#
# Install:
#   curl -o ~/greenlight-hook.sh https://getgreenlight.github.io/greenlight-hook.sh
#   chmod +x ~/greenlight-hook.sh

# Defaults
DEVICE_ID=""
GREENLIGHT_SERVER="https://permit.dnmfarrell.com"
TIMEOUT="60"
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
        --timeout)
            TIMEOUT="$2"
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

# Read permission request from stdin
INPUT=$(cat)

# Send to Greenlight server (include project if specified)
if [ -n "$PROJECT" ]; then
    PAYLOAD=$(echo "$INPUT" | jq --arg did "$DEVICE_ID" --arg proj "$PROJECT" '. + {device_id: $did, project: $proj}')
else
    PAYLOAD=$(echo "$INPUT" | jq --arg did "$DEVICE_ID" '. + {device_id: $did}')
fi

RESPONSE=$(curl -s --max-time "$TIMEOUT" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${GREENLIGHT_SERVER}/request")

# Check if curl succeeded
if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
    cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Failed to reach Greenlight server (timeout or connection error)"
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
