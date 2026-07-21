#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER is required}"
: "${REGION:?REGION is required}"
: "${STAGING_BUCKET:?STAGING_BUCKET is required}"
: "${PYTHON_BIN:?PYTHON_BIN is required}"

deploy_output="$(mktemp)"
trap 'rm -f "$deploy_output"' EXIT
export DEPLOY_OUTPUT="$deploy_output"

PYTHONPATH="$(cd "$(dirname "$0")/.." && pwd)" "$PYTHON_BIN" "$(dirname "$0")/deploy_agent.py"

principal="$(jq -er '.principal' "$deploy_output")"
engine_name="$(jq -er '.name' "$deploy_output")"

for role in \
  roles/aiplatform.expressUser \
  roles/serviceusage.serviceUsageConsumer \
  roles/browser \
  roles/cloudapiregistry.viewer \
  roles/logging.logWriter \
  roles/monitoring.metricWriter \
  roles/discoveryengine.viewer \
  roles/agentregistry.viewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$principal" --role="$role" --quiet >/dev/null
done

gcloud secrets add-iam-policy-binding external-mcp-token \
  --project="$PROJECT_ID" --member="$principal" \
  --role=roles/secretmanager.secretAccessor --quiet >/dev/null

# The current Cloud SDK predates the Agent Registry flags for `gcloud iap`.
# Use the documented registry-wide IAP IAM REST resource.  The registry
# contains only the explicitly approved Google endpoints and external MCP
# servers, so this remains a bounded egress allowlist.
iap_policy="$(mktemp)"
iap_request="$(mktemp)"
iap_response="$(mktemp)"
access_token="$(gcloud auth print-access-token)"
iap_resource="projects/${PROJECT_NUMBER}/locations/${REGION}/iap_web/agentRegistry"

curl -fsS -X POST \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -H 'Content-Type: application/json' \
  --data '{}' \
  "https://iap.googleapis.com/v1/${iap_resource}:getIamPolicy" >"$iap_policy"

jq --arg member "$principal" --arg role roles/iap.egressor '
  .bindings = (
    (.bindings // []) as $bindings
    | if any($bindings[]; .role == $role) then
        $bindings | map(
          if .role == $role then
            .members = (((.members // []) + [$member]) | unique)
          else . end
        )
      else
        $bindings + [{role: $role, members: [$member]}]
      end
  )
  | {policy: .}
' "$iap_policy" >"$iap_request"

curl -fsS -X POST \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -H 'Content-Type: application/json' \
  --data-binary "@${iap_request}" \
  "https://iap.googleapis.com/v1/${iap_resource}:setIamPolicy" >"$iap_response"
jq -e --arg member "$principal" '
  any(.bindings[]?; .role == "roles/iap.egressor" and any(.members[]?; . == $member))
' "$iap_response" >/dev/null
rm -f "$iap_policy" "$iap_request" "$iap_response"

mkdir -p "$(dirname "$0")/../artifacts"
jq . "$deploy_output" >"$(dirname "$0")/../artifacts/agent-runtime.json"
echo "Agent Runtime ${engine_name} deployed and authorized through Agent Gateway."
