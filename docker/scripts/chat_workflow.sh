#!/bin/bash

# Set up logging
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] $1"
}

# Check required environment variables
log "Checking environment variables..."
required_vars=("MCP_CLIENT_ID" "MCP_CLIENT_REF" "REGISTRY_AUTH_SERVER" "OPENAI_API_KEY" "APP_SLUG" "SERVER_URL" "PROMPT")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set"
        exit 1
    fi
done
log "All required environment variables are set"

# Process prompt
log "Processing prompt"
PROCESSED_PROMPT="A have give reference of our previous conversion, now perform same action for this prompt. Current Task: ${PROMPT} \n\nNote that the last output_text of your response should be a valid json as asked."
log "Processed prompt: $PROCESSED_PROMPT"

# Escape the prompt for JSON
ESCAPED_PROMPT=$(echo "$PROCESSED_PROMPT" | jq -R .)
log "Escaped prompt: $ESCAPED_PROMPT"

# Generate MCP access token
log "Generating MCP access token"
TOKEN_RESPONSE=$(curl -s -X POST "${REGISTRY_AUTH_SERVER}" \
    -H "Content-Type: application/json" \
    -d "{
        \"grant_type\": \"client_credentials\",
        \"client_id\": \"${MCP_CLIENT_ID}\",
        \"client_secret\": \"${MCP_CLIENT_REF}\"
    }")
log "Token response: $TOKEN_RESPONSE"

ACCESS_TOKEN=$(echo $TOKEN_RESPONSE | jq -r '.access_token')
if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    log "Error: Failed to get access token"
    exit 1
fi
log "Successfully got access token"

# Make chat request
log "Making chat request"

# Prepare payload
PAYLOAD=$(cat << EOF
{
    "model": "gpt-4.1",
    $([ ! -z "$PREVIOUS_RESPONSE_ID" ] && echo "\"previous_response_id\": \"$PREVIOUS_RESPONSE_ID\",")
    "input": [{
        "role": "user",
        "content": [{
            "type": "input_text",
            "text": $ESCAPED_PROMPT
        }]
    }],
    "text": {"format": {"type": "text"}},
    "reasoning": {},
    "tools": [{
        "type": "mcp",
        "server_label": "$APP_SLUG",
        "server_url": "$SERVER_URL/$APP_SLUG",
        "headers": {
            "Authorization": "Bearer $ACCESS_TOKEN"
        },
        "require_approval": "never"
    }],
    "temperature": 1,
    "max_output_tokens": 2048,
    "top_p": 1,
    "store": true
}
EOF
)

log "Request payload (raw):"
echo "$PAYLOAD"

log "Request payload (formatted):"
echo "$PAYLOAD" | jq '.' || echo "Failed to parse payload as JSON"

log "Making request to OpenAI API"
CHAT_RESPONSE=$(curl -s -X POST "https://api.openai.com/v1/responses" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

log "Chat response received:"
echo "$CHAT_RESPONSE" | jq '.'

# Extract and process JSON from response
log "Processing response"
LAST_OUTPUT=$(echo "$CHAT_RESPONSE" | jq -r '.output[] | select(.type == "message" and .role == "assistant") | .content[] | select(.type == "output_text") | .text')
log "Assistant message: $LAST_OUTPUT"

# Extract JSON content
JSON_CONTENT=$(echo "$LAST_OUTPUT" | awk '/```json/{p=1;next}/```/{p=0;next}p')
if [ -z "$JSON_CONTENT" ]; then
    log "No JSON block found in message"
    exit 1
fi

log "Extracted JSON:"
echo "$JSON_CONTENT" | jq '.' || {
    log "Failed to parse JSON. Raw content:"
    echo "$JSON_CONTENT"
    exit 1
}
