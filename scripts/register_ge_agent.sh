#!/usr/bin/env bash
# Register the deployed ADK reasoning engine as an agent under the Gemini
# Enterprise app assistant. The agents collection is a Discovery Engine v1alpha
# preview surface not yet modeled by the Terraform provider, so registration
# runs through the documented REST fallback. The operation is idempotent: an
# existing agent with the same display name is updated in place.
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER is required}"
: "${LOCATION:?LOCATION is required}"
: "${APP_ID:?APP_ID is required}"
: "${ASSISTANT_ID:?ASSISTANT_ID is required}"
: "${RUNTIME_JSON:?RUNTIME_JSON is required}"

DISPLAY_NAME="M3 HR Enterprise Agent"
DESCRIPTION="Governed HR policy, WorkWeek, and ServiceImmediately agent"
TOOL_DESCRIPTION="Answers HR policy questions and performs authorized WorkWeek and ServiceImmediately self-service actions."
SHARING_SCOPE="${SHARING_SCOPE:-ALL_USERS}"

if [ ! -f "$RUNTIME_JSON" ]; then
  echo "Agent Runtime metadata not found at ${RUNTIME_JSON}; deploy the runtime first." >&2
  exit 1
fi
reasoning_engine="$(jq -er '.name' "$RUNTIME_JSON")"

access_token="$(gcloud auth print-access-token)"
base="https://discoveryengine.googleapis.com/v1alpha/projects/${PROJECT_ID}/locations/${LOCATION}/collections/default_collection/engines/${APP_ID}/assistants/${ASSISTANT_ID}"

body_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$body_file" "$response_file"' EXIT

# sharingConfig is required for the agent to appear in the Gemini Enterprise
# agent gallery. Without it the agent registers and reports state ENABLED but
# stays invisible to users, which looks like a silent registration failure.
jq -n \
  --arg display "$DISPLAY_NAME" \
  --arg description "$DESCRIPTION" \
  --arg tool "$TOOL_DESCRIPTION" \
  --arg engine "$reasoning_engine" \
  --arg scope "$SHARING_SCOPE" \
  '{
     displayName: $display,
     description: $description,
     sharingConfig: { scope: $scope },
     adkAgentDefinition: {
       toolSettings: { toolDescription: $tool },
       provisionedReasoningEngine: { reasoningEngine: $engine }
     }
   }' >"$body_file"

# Look for an existing agent with the same display name to update in place.
status="$(curl -sS -o "$response_file" -w '%{http_code}' \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  "${base}/agents")"
if [[ ! "$status" =~ ^2 ]]; then
  echo "Unable to list assistant agents (HTTP ${status}):" >&2
  jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
  exit 1
fi
existing="$(jq -r --arg d "$DISPLAY_NAME" '.agents[]? | select(.displayName == $d) | .name' "$response_file" | head -n1)"

if [ -n "$existing" ]; then
  echo "Updating existing agent registration: ${existing}"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X PATCH \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${body_file}" \
    "https://discoveryengine.googleapis.com/v1alpha/${existing}?updateMask=displayName,description,sharingConfig,adkAgentDefinition")"
else
  echo "Creating agent registration under ${APP_ID}/${ASSISTANT_ID}"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${body_file}" \
    "${base}/agents")"
fi

if [[ ! "$status" =~ ^2 ]]; then
  echo "Agent registration failed with HTTP ${status}:" >&2
  jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
  exit 1
fi

agent_name="$(jq -er '.name' "$response_file")"
echo "Registered Gemini Enterprise agent: ${agent_name}"
