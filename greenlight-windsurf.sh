#!/bin/bash
# Greenlight - Permission Hook for Windsurf (Cascade)
# Forwards pre-action hooks to the Greenlight relay server for mobile approval.
#
# Usage: greenlight-windsurf.sh --device-id ID [--project NAME]
#
# Install:
#   1. Download this script and make it executable:
#      curl -o ~/greenlight-windsurf.sh https://getgreenlight.github.io/greenlight-windsurf.sh
#      chmod +x ~/greenlight-windsurf.sh
#
#   2. Configure hooks in one of:
#      - User:      ~/.codeium/windsurf/hooks.json
#      - Workspace:  .windsurf/hooks.json
#
#      {
#        "hooks": {
#          "pre_run_command": [{
#            "command": "~/greenlight-windsurf.sh --device-id YOUR_DEVICE_ID",
#            "show_output": true
#          }],
#          "pre_write_code": [{
#            "command": "~/greenlight-windsurf.sh --device-id YOUR_DEVICE_ID",
#            "show_output": true
#          }],
#          "pre_read_code": [{
#            "command": "~/greenlight-windsurf.sh --device-id YOUR_DEVICE_ID",
#            "show_output": true
#          }],
#          "pre_mcp_tool_use": [{
#            "command": "~/greenlight-windsurf.sh --device-id YOUR_DEVICE_ID",
#            "show_output": true
#          }]
#        }
#      }
#
# Blocking: exit 0 = allow, exit 2 = deny (stderr shown to user)

# Defaults
DEVICE_ID=""
GREENLIGHT_SERVER="https://permit.dnmfarrell.com"
TIMEOUT="595"
PROJECT=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --device-id)
            DEVICE_ID="$2"
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

# Fall back to environment variables if args not provided
DEVICE_ID="${DEVICE_ID:-$GREENLIGHT_DEVICE_ID}"
PROJECT="${PROJECT:-$GREENLIGHT_PROJECT}"

if ! command -v jq >/dev/null 2>&1; then
    echo "Greenlight hook requires jq but it's not installed. Install it with: brew install jq (macOS) or apt-get install jq (Linux)" >&2
    exit 2
fi

if [ -z "$DEVICE_ID" ]; then
    echo "Greenlight device ID not configured. See https://getgreenlight.github.io/support.html" >&2
    exit 2
fi

if [ -z "$PROJECT" ]; then
    echo "Greenlight hook is missing the --project flag. Add --project PROJECT_NAME to the hook command in your hooks.json config. See https://getgreenlight.github.io/guide-windsurf.html" >&2
    exit 2
fi

# Read Windsurf hook input from stdin
# Format: { "agent_action_name": "pre_run_command", "trajectory_id": "...",
#            "execution_id": "...", "timestamp": "...", "tool_info": {...} }
INPUT=$(cat)

ACTION=$(echo "$INPUT" | jq -r '.agent_action_name // empty')
TOOL_INFO=$(echo "$INPUT" | jq -c '.tool_info // {}')

# Map Windsurf hook events to Greenlight tool names and tool_input
case "$ACTION" in
    pre_run_command)
        TOOL_NAME="Bash"
        # Windsurf: {"command_line": "...", "cwd": "/..."}
        COMMAND_LINE=$(echo "$TOOL_INFO" | jq -r '.command_line // empty')
        CWD=$(echo "$TOOL_INFO" | jq -r '.cwd // empty')
        TOOL_INPUT=$(jq -n --arg cmd "$COMMAND_LINE" '{command: $cmd}')
        # Use cwd basename as project if not set via flag
        if [ -z "$PROJECT" ] && [ -n "$CWD" ]; then
            PROJECT=$(basename "$CWD")
        fi
        ;;
    pre_write_code)
        TOOL_NAME="Edit"
        # Windsurf: {"file_path": "...", "edits": [{"old_string": "...", "new_string": "..."}]}
        TOOL_INPUT="$TOOL_INFO"
        if [ -z "$PROJECT" ]; then
            FILE_PATH=$(echo "$TOOL_INFO" | jq -r '.file_path // empty')
            if [ -n "$FILE_PATH" ]; then
                PROJECT=$(basename "$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null)")
            fi
        fi
        ;;
    pre_read_code)
        TOOL_NAME="Read"
        # Windsurf: {"file_path": "..."}
        TOOL_INPUT="$TOOL_INFO"
        if [ -z "$PROJECT" ]; then
            FILE_PATH=$(echo "$TOOL_INFO" | jq -r '.file_path // empty')
            if [ -n "$FILE_PATH" ]; then
                PROJECT=$(basename "$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null)")
            fi
        fi
        ;;
    pre_mcp_tool_use)
        # Windsurf: {"mcp_server_name": "...", "mcp_tool_name": "...", "mcp_tool_arguments": {...}}
        MCP_SERVER=$(echo "$TOOL_INFO" | jq -r '.mcp_server_name // empty')
        MCP_TOOL=$(echo "$TOOL_INFO" | jq -r '.mcp_tool_name // empty')
        TOOL_NAME="mcp__${MCP_SERVER}__${MCP_TOOL}"
        TOOL_INPUT=$(echo "$TOOL_INFO" | jq -c '.mcp_tool_arguments // {}')
        ;;
    *)
        # Unknown action type - allow by default
        exit 0
        ;;
esac

# Build payload for Permit Cloud
if [ -n "$PROJECT" ]; then
    PAYLOAD=$(jq -n \
        --arg did "$DEVICE_ID" \
        --arg tn "$TOOL_NAME" \
        --argjson ti "$TOOL_INPUT" \
        --arg proj "$PROJECT" \
        '{device_id: $did, tool_name: $tn, tool_input: $ti, project: $proj, agent: "windsurf"}')
else
    PAYLOAD=$(jq -n \
        --arg did "$DEVICE_ID" \
        --arg tn "$TOOL_NAME" \
        --argjson ti "$TOOL_INPUT" \
        '{device_id: $did, tool_name: $tn, tool_input: $ti, agent: "windsurf"}')
fi

# POST to Permit Cloud and wait for response
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
    echo "Failed to reach Greenlight server (timeout or connection error)" >&2
    exit 2
fi

# Check for HTTP error status
if [ "$HTTP_CODE" -ge 400 ] 2>/dev/null; then
    echo "Greenlight server error (HTTP $HTTP_CODE): $RESPONSE" >&2
    exit 2
fi

# Check for error response
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
if [ -n "$ERROR" ]; then
    echo "Greenlight error: $ERROR" >&2
    exit 2
fi

# Parse response
BEHAVIOR=$(echo "$RESPONSE" | jq -r '.behavior // "deny"')
MESSAGE=$(echo "$RESPONSE" | jq -r '.message // empty')

if [ "$BEHAVIOR" = "allow" ]; then
    # Allow - exit 0
    exit 0
else
    # Deny - exit 2 with message on stderr
    echo "${MESSAGE:-Permission denied via Greenlight}" >&2
    exit 2
fi
