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
# log "Fetching template data from Harness API..."
# TEMPLATE_RESPONSE=$(curl -s -X GET \
#     "https://localhost:8080/template/api/templates/$PLUGIN_TEMPLATE_IDENTIFIER?accountIdentifier=kmpySmUISimoRrJL6NL73w&versionLabel=v1&deleted=false" \
#     -H "x-api-key: $PLUGIN_HARNESS_API_KEY" \
#     -H "content-type: application/json")

# Use hardcoded template response
log "Fetching AI workflow template data..."
TEMPLATE_RESPONSE='{"status":"SUCCESS","data":{"accountId":"kmpySmUISimoRrJL6NL73w","identifier":"n2","name":"n2","description":"","tags":{},"yaml":"template:\n  name: n2\n  identifier: n2\n  versionLabel: v1\n  type: AIWorkflow\n  tags: {}\n  spec:\n    body:\n      history: |-\n        {\n          \"sampleKey\": \"value\"\n        }\n      promptHistory: \"Fetch me the details of the latest hotfix for ng-manager. Get me the service, Environment and Tag for the latest hotfix done in json format. Output format {\\n  \\\"service\\\": \\\"value\\\",\\n  \\\"environment\\\": \\\"value\\\",\\n  \\\"tag\\\": \\\"value\\\"\\n}\"\n    model: gpt-4.1\n    serverUrl: https://mcp.pipedream.net/157bd7bd-f742-4050-bf48-8160231be586\n    registryAuthServer: https://api.pipedream.com/v1/oauth/token\n    clientIdRef: clientIdRef\n    clientSecretRef: clientSecretRef\n    appSlug: confluence\n  variables: []\n","versionLabel":"v1","templateEntityType":"AIWorkflow","templateScope":"account","version":0,"gitDetails":{"objectId":null,"branch":null,"repoIdentifier":null,"rootFolder":null,"filePath":null,"repoName":null,"commitId":null,"fileUrl":null,"repoUrl":null,"parentEntityConnectorRef":null,"parentEntityRepoName":null,"isHarnessCodeRepo":null},"entityValidityDetails":{"valid":true,"invalidYaml":null},"lastUpdatedAt":1749160085054,"storeType":"INLINE","yamlVersion":"0","isInlineHCEntity":false,"stableTemplate":true},"metaData":null,"correlationId":"b0731b02-c7a5-4ff8-85c1-61dae39c9656"}'


# Check if response is successful
if [ "$(echo "$TEMPLATE_RESPONSE" | jq -r '.status')" != "SUCCESS" ]; then
    log "Error: Failed to fetch template data"
    log "Response: $TEMPLATE_RESPONSE"
    exit 1
fi

# Extract and parse YAML from response
log "Extracting YAML from response..."
YAML_DATA=$(echo "$TEMPLATE_RESPONSE" | jq -r '.data.yaml')

# Parse required values from YAML
log "Parsing values from YAML..."

# Function to extract value from YAML using yq
get_yaml_value() {
    local path=$1
    echo "$YAML_DATA" | yq eval "$path" -
}

# Extract values from YAML
PLUGIN_MCP_CLIENT_ID="KYEmLxK2eSQdQqN0REpquycY6QklwrOTvaFUmK4sJ8c"
PLUGIN_MCP_CLIENT_REF="yw-bzm1YFIgKRnzkTt1Bhv1Oqrfpye_LyzcLlkVcEgA"
PLUGIN_REGISTRY_AUTH_SERVER=${PLUGIN_REGISTRY_AUTH_SERVER:-$(get_yaml_value '.template.spec.registryAuthServer')}
PLUGIN_APP_SLUG=${PLUGIN_APP_SLUG:-$(get_yaml_value '.template.spec.appSlug')}
PLUGIN_SERVER_URL=${PLUGIN_SERVER_URL:-$(get_yaml_value '.template.spec.serverUrl')}
PLUGIN_PROMPT=${PLUGIN_PROMPT:-$(get_yaml_value '.template.spec.body.promptHistory')}
PLUGIN_PREVIOUS_RESPONSE_ID=${PLUGIN_PREVIOUS_RESPONSE_ID:-$(get_yaml_value '.template.spec.body.previousResponseId')}

# Check if required variables are now set
log "Checking required variables..."
required_vars=("PLUGIN_MCP_CLIENT_ID" "PLUGIN_MCP_CLIENT_REF" "PLUGIN_REGISTRY_AUTH_SERVER" "PLUGIN_OPENAI_API_KEY" "PLUGIN_APP_SLUG" "PLUGIN_SERVER_URL" "PLUGIN_PROMPT")
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
    --url 'https://app.harness.io/gateway/pipeline/api/webhook/custom/v2?accountIdentifier=vRvDt5iuS7uwyGSo8S0biA&orgIdentifier=default&projectIdentifier=SourabhProject&pipelineIdentifier=shell_script_pipeline&triggerIdentifier=t1' \
    -d "$JSON_CONTENT")

log "Webhook response:"
echo "$WEBHOOK_RESPONSE" | jq '.' || echo "$WEBHOOK_RESPONSE"
