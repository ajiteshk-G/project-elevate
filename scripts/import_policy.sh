#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${DATA_STORE_ID:?DATA_STORE_ID is required}"
: "${POLICY_OBJECT_URI:?POLICY_OBJECT_URI is required}"

request_file="$(mktemp)"
trap 'rm -f "$request_file"' EXIT

jq -n \
  --arg uri "$POLICY_OBJECT_URI" \
  '{gcsSource:{inputUris:[$uri],dataSchema:"content"},reconciliationMode:"FULL"}' \
  >"$request_file"

access_token="$(gcloud auth print-access-token)"
endpoint="https://discoveryengine.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/collections/default_collection/dataStores/${DATA_STORE_ID}/branches/default_branch/documents:import"
response_file="$(mktemp)"
trap 'rm -f "$request_file" "$response_file"' EXIT
http_status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${access_token}" \
  -H "X-Goog-User-Project: ${PROJECT_ID}" \
  -H 'Content-Type: application/json' \
  --data-binary "@${request_file}" \
  "$endpoint")"

if [[ ! "$http_status" =~ ^2 ]]; then
  echo "Vertex AI Search import request failed with HTTP ${http_status}:" >&2
  jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
  exit 1
fi

response="$(<"$response_file")"

operation_name="$(jq -er '.name' <<<"$response")"
echo "Vertex AI Search import started: ${operation_name}"

for _ in $(seq 1 240); do
  operation="$(curl -fsS \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "https://discoveryengine.googleapis.com/v1/${operation_name}")"
  if [ "$(jq -r '.done // false' <<<"$operation")" = "true" ]; then
    if jq -e '.error' >/dev/null <<<"$operation"; then
      jq '.error' <<<"$operation" >&2
      exit 1
    fi
    jq '{done, response, metadata}' <<<"$operation"
    exit 0
  fi
  sleep 5
done

echo "Timed out waiting for Vertex AI Search import" >&2
exit 1
