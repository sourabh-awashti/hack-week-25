#!/bin/bash

# Set up logging
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] $1"
}

# Check initial required environment variables
log "Checking initial environment variables..."
initial_vars=("PLUGIN_HARNESS_API_KEY" "PLUGIN_TEMPLATE_IDENTIFIER")
for var in "${initial_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set"
        exit 1
    fi
done

# Fetch template data from Harness API
log "Fetching template data from Harness API..."
TEMPLATE_RESPONSE=$(curl -s --location "https://namangoenka.pr2.harness.io/gateway/template/api/templates/$PLUGIN_TEMPLATE_IDENTIFIER?accountIdentifier=JjwsoDSvRD6cC_7L51ruJA&versionLabel=v1" \
  --header 'content-type: application/json' \
  --header "x-api-key: $PLUGIN_HARNESS_API_KEY")

log "Template Response:"
echo "$TEMPLATE_RESPONSE" | jq '.'

# Parse and validate the template response
log "Validating template response..."

# Check if response is successful
if [ "$(echo "$TEMPLATE_RESPONSE" | jq -r '.status')" != "SUCCESS" ]; then
    log "Error: Failed to fetch template data. Status is not SUCCESS"
    log "Response: $TEMPLATE_RESPONSE"
    exit 1
fi


log "Template validation successful"

# Extract and parse YAML from response
log "Extracting YAML from response..."
YAML_DATA=$(echo "$TEMPLATE_RESPONSE" | jq -r '.data.yaml')

# Parse required values from YAML
log "Parsing values from YAML..."

# Function to extract value from YAML
get_yaml_value() {
    local path=$1
    # Parse the YAML string into a JSON structure first
    local json_data=$(echo "$YAML_DATA" | jq -R -s '.')
    # Now extract the value using the path
    case "$path" in
        'registryAuthServer') echo "$json_data" | jq -r 'match(".*registryAuthServer: ([^\n]*).*"; "m").captures[0].string' ;;
        'appSlug') echo "$json_data" | jq -r 'match(".*appSlug: ([^\n]*).*"; "m").captures[0].string' ;;
        'serverUrl') echo "$json_data" | jq -r 'match(".*serverUrl: ([^\n]*).*"; "m").captures[0].string' ;;
        'body.promptHistory') echo "$json_data" | jq -r 'match(".*promptHistory: \"([^\"]*).*"; "m").captures[0].string' ;;
    esac
}

# Extract values from YAML
PLUGIN_MCP_CLIENT_ID="KYEmLxK2eSQdQqN0REpquycY6QklwrOTvaFUmK4sJ8c"
PLUGIN_MCP_CLIENT_REF="yw-bzm1YFIgKRnzkTt1Bhv1Oqrfpye_LyzcLlkVcEgA"

log "Extracting values from YAML..."
PLUGIN_REGISTRY_AUTH_SERVER=${PLUGIN_REGISTRY_AUTH_SERVER:-$(get_yaml_value 'registryAuthServer')}
log "PLUGIN_REGISTRY_AUTH_SERVER: $PLUGIN_REGISTRY_AUTH_SERVER"

PLUGIN_APP_SLUG=${PLUGIN_APP_SLUG:-$(get_yaml_value 'appSlug')}
log "PLUGIN_APP_SLUG: $PLUGIN_APP_SLUG"

PLUGIN_SERVER_URL=${PLUGIN_SERVER_URL:-$(get_yaml_value 'serverUrl')}
log "PLUGIN_SERVER_URL: $PLUGIN_SERVER_URL"

PLUGIN_PROMPT=${PLUGIN_PROMPT:-$(get_yaml_value 'body.promptHistory')}
log "PLUGIN_PROMPT: $PLUGIN_PROMPT"

log "Raw YAML_DATA for debugging:"
echo "$YAML_DATA" | jq '.'

# Check if required variables are now set
log "Checking required variables..."
required_vars=("PLUGIN_REGISTRY_AUTH_SERVER" "PLUGIN_APP_SLUG" "PLUGIN_SERVER_URL" "PLUGIN_PROMPT")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set after parsing template"
        exit 1
    fi
done
log "All required variables are set"

# Process prompt
log "Processing prompt"
PROCESSED_PROMPT="A have give reference of our previous conversion, now perform same action for this prompt. Current Task: ${PLUGIN_PROMPT} \n\nNote that the last output_text of your response should be a valid json as asked."
log "Processed prompt: $PROCESSED_PROMPT"

# Escape the prompt for JSON
ESCAPED_PROMPT=$(echo "$PROCESSED_PROMPT" | jq -R .)
log "Escaped prompt: $ESCAPED_PROMPT"

# Generate MCP access token
log "Generating MCP access token"
TOKEN_RESPONSE=$(curl -s -X POST "${PLUGIN_REGISTRY_AUTH_SERVER}" \
    -H "Content-Type: application/json" \
    -d "{
        \"grant_type\": \"client_credentials\",
        \"client_id\": \"${PLUGIN_MCP_CLIENT_ID}\",
        \"client_secret\": \"${PLUGIN_MCP_CLIENT_REF}\"
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
    $([ ! -z "$PLUGIN_PREVIOUS_RESPONSE_ID" ] && echo "\"previous_response_id\": \"$PLUGIN_PREVIOUS_RESPONSE_ID\",")
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
        "server_label": "${PLUGIN_APP_SLUG}",
        "server_url": "${PLUGIN_SERVER_URL}/${PLUGIN_APP_SLUG}",
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
    -H "Authorization: Bearer ${PLUGIN_OPENAI_API_KEY}" \
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

# Send webhook with parsed JSON
log "Sending webhook..."
WEBHOOK_RESPONSE=$(curl -s -X POST \
    -H 'content-type: application/json' \
    --url 'https://namangoenka.pr2.harness.io/gateway/pipeline/api/webhook/custom/x9rbsrIsQA6VcO6XF0no2Q/v3?accountIdentifier=JjwsoDSvRD6cC_7L51ruJA&orgIdentifier=default&projectIdentifier=WDPR_Adaptive_Payment_Platform_Card_Not_Present_Service_Guest_facing&pipelineIdentifier=cdpipeline&triggerIdentifier=webhook' \
    -d "$JSON_CONTENT")

log "Webhook response:"
echo "$WEBHOOK_RESPONSE" | jq '.' || echo "$WEBHOOK_RESPONSE"
