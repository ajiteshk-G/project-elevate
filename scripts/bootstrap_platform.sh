#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${PROJECT_NUMBER:?PROJECT_NUMBER is required}"
: "${REGION:?REGION is required}"
: "${CONFIG_DIR:?CONFIG_DIR is required}"

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

render() {
  sed -e "s/__PROJECT_ID__/${PROJECT_ID}/g" -e "s/__REGION__/${REGION}/g" "$1" >"$2"
}

for source in "$CONFIG_DIR"/*.yaml.tmpl; do
  target="$render_dir/$(basename "${source%.tmpl}")"
  render "$source" "$target"
done

access_token="$(gcloud auth print-access-token)"

wait_for_network_services_operation() {
  local api_version="$1"
  local operation_name="$2"
  local operation_file
  operation_file="$(mktemp)"
  for _ in $(seq 1 240); do
    curl -fsS \
      -H "Authorization: Bearer ${access_token}" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      "https://networkservices.googleapis.com/${api_version}/${operation_name}" \
      >"$operation_file"
    if [ "$(jq -r '.done // false' "$operation_file")" = "true" ]; then
      if jq -e '.error' "$operation_file" >/dev/null; then
        jq '.error' "$operation_file" >&2
        return 1
      fi
      rm -f "$operation_file"
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for ${operation_name}" >&2
  rm -f "$operation_file"
  return 1
}

ensure_gateway() {
  local gateway_id="$1"
  local governed_path="$2"
  local resource_path="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${gateway_id}"
  local endpoint="https://networkservices.googleapis.com/v1alpha1/${resource_path}"
  local response_file body_file status operation_name
  response_file="$(mktemp)"
  body_file="$(mktemp)"

  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [ "$status" = "200" ]; then
    echo "Agent Gateway ${gateway_id} already exists."
    rm -f "$response_file" "$body_file"
    return 0
  fi
  if [ "$status" != "404" ]; then
    echo "Unable to inspect Agent Gateway ${gateway_id} (HTTP ${status}):" >&2
    jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
    rm -f "$response_file" "$body_file"
    return 1
  fi

  if [ "$governed_path" = "AGENT_TO_ANYWHERE" ]; then
    jq -n \
      --arg registry "//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}" \
      '{protocols:["MCP"],googleManaged:{governedAccessPath:"AGENT_TO_ANYWHERE"},registries:[$registry]}' \
      >"$body_file"
  else
    jq -n \
      --arg path "$governed_path" \
      '{protocols:["MCP"],googleManaged:{governedAccessPath:$path}}' \
      >"$body_file"
  fi

  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${body_file}" \
    "https://networkservices.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/agentGateways?agentGatewayId=${gateway_id}")"
  if [[ ! "$status" =~ ^2 ]] && [ "$status" != "409" ]; then
    echo "Agent Gateway ${gateway_id} creation failed with HTTP ${status}:" >&2
    jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
    rm -f "$response_file" "$body_file"
    return 1
  fi

  if [ "$status" = "409" ]; then
    echo "Agent Gateway ${gateway_id} already exists."
    rm -f "$response_file" "$body_file"
    return 0
  fi

  operation_name="$(jq -er '.name' "$response_file")"
  echo "Creating Agent Gateway ${gateway_id}: ${operation_name}"
  rm -f "$response_file" "$body_file"
  wait_for_network_services_operation v1alpha1 "$operation_name"
}

ensure_gateway hr-agent-egress AGENT_TO_ANYWHERE
ensure_gateway hr-agent-ingress CLIENT_TO_AGENT

gateway_member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"
for role in roles/modelarmor.calloutUser roles/modelarmor.user roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$gateway_member" --role="$role" --quiet >/dev/null || true
done

ensure_authz_extension() {
  local extension_id="$1"
  local extension_type="$2"
  local resource_path="projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${extension_id}"
  local endpoint="https://networkservices.googleapis.com/v1/${resource_path}"
  local response_file body_file status operation_name method request_endpoint
  response_file="$(mktemp)"
  body_file="$(mktemp)"

  if [ "$extension_type" = "iap" ]; then
    jq -n \
      --arg name "$resource_path" \
      '{name:$name,service:"iap.googleapis.com",failOpen:true,timeout:"1s",metadata:{iapPolicyVersion:"V1"}}' \
      >"$body_file"
  else
    # Model Armor templates are regional: Terraform creates them in ${REGION}
    # and there is no global Model Armor endpoint. Pointing an authz extension
    # at locations/global makes the callout fail template lookup, and because
    # the extension is fail-closed the gateway then rejects traffic with 404
    # without ever recording a sanitize operation.
    local template_path="projects/${PROJECT_ID}/locations/${REGION}/templates/hr-agent-${extension_type}"
    local settings
    settings="$(jq -nc --arg template "$template_path" '[{request_template_id:$template,response_template_id:$template}]')"
    jq -n \
      --arg name "$resource_path" \
      --arg service "modelarmor.${REGION}.rep.googleapis.com" \
      --arg settings "$settings" \
      '{name:$name,service:$service,failOpen:false,timeout:"5s",metadata:{model_armor_settings:$settings}}' \
      >"$body_file"
  fi

  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [ "$status" = "200" ]; then
    if [ "$(jq -Sc '{service,failOpen:(.failOpen // false),timeout,metadata}' "$response_file")" = "$(jq -Sc '{service,failOpen:(.failOpen // false),timeout,metadata}' "$body_file")" ]; then
      echo "Authorization extension ${extension_id} is current."
      rm -f "$response_file" "$body_file"
      return 0
    fi
    method=PATCH
    request_endpoint="${endpoint}?updateMask=service,metadata,failOpen,timeout"
  elif [ "$status" = "404" ]; then
    method=POST
    request_endpoint="https://networkservices.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/authzExtensions?authzExtensionId=${extension_id}"
  else
    echo "Unable to inspect authorization extension ${extension_id} (HTTP ${status}):" >&2
    jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
    rm -f "$response_file" "$body_file"
    return 1
  fi

  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${body_file}" \
    "$request_endpoint")"
  if [[ ! "$status" =~ ^2 ]]; then
    echo "Authorization extension ${extension_id} configuration failed with HTTP ${status}:" >&2
    jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
    rm -f "$response_file" "$body_file"
    return 1
  fi

  operation_name="$(jq -er '.name' "$response_file")"
  echo "Configuring authorization extension ${extension_id}: ${operation_name}"
  rm -f "$response_file" "$body_file"
  wait_for_network_services_operation v1 "$operation_name"
}

ensure_authz_extension hr-egress-iap iap
ensure_authz_extension hr-egress-model-armor egress
ensure_authz_extension hr-ingress-model-armor ingress

wait_for_network_security_operation() {
  local operation_name="$1"
  local operation_file
  operation_file="$(mktemp)"
  for _ in $(seq 1 240); do
    curl -fsS \
      -H "Authorization: Bearer ${access_token}" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      "https://networksecurity.googleapis.com/v1beta1/${operation_name}" \
      >"$operation_file"
    if [ "$(jq -r '.done // false' "$operation_file")" = "true" ]; then
      if jq -e '.error' "$operation_file" >/dev/null; then
        jq '.error' "$operation_file" >&2
        return 1
      fi
      rm -f "$operation_file"
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for ${operation_name}" >&2
  rm -f "$operation_file"
  return 1
}

ensure_authz_policy() {
  local policy_id="$1"
  local gateway_id="$2"
  local extension_id="$3"
  local policy_profile="$4"
  local resource_path="projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${policy_id}"
  local gateway_path="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${gateway_id}"
  local extension_path="projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${extension_id}"
  local endpoint="https://networksecurity.googleapis.com/v1beta1/${resource_path}"
  local response_file body_file status operation_name method request_endpoint
  response_file="$(mktemp)"
  body_file="$(mktemp)"

  if [ "$policy_id" = "hr-egress-iap-policy" ]; then
    jq -n \
      --arg name "$resource_path" \
      --arg gateway "$gateway_path" \
      --arg extension "$extension_path" \
      --arg profile "$policy_profile" \
      '{name:$name,target:{resources:[$gateway]},policyProfile:$profile,action:"CUSTOM",customProvider:{authzExtension:{resources:[$extension]}},httpRules:[{to:{operations:[{paths:[{prefix:"/"}]}]},when:"!request.host.endsWith(\u0027googleapis.com\u0027)"}]}' \
      >"$body_file"
  elif [ "$policy_profile" = "CONTENT_AUTHZ" ] && [ "$gateway_id" = "hr-agent-egress" ]; then
    jq -n \
      --arg name "$resource_path" \
      --arg gateway "$gateway_path" \
      --arg extension "$extension_path" \
      --arg profile "$policy_profile" \
      '{name:$name,target:{resources:[$gateway]},policyProfile:$profile,action:"CUSTOM",customProvider:{authzExtension:{resources:[$extension]}},httpRules:[{to:{operations:[{paths:[{prefix:"/"}]}]},when:"!request.host.endsWith(\u0027googleapis.com\u0027) && (request.headers[\u0027content-type\u0027].startsWith(\u0027application/json\u0027) || request.headers[\u0027content-type\u0027].startsWith(\u0027text/\u0027))"}]}' \
      >"$body_file"
  else
    jq -n \
      --arg name "$resource_path" \
      --arg gateway "$gateway_path" \
      --arg extension "$extension_path" \
      --arg profile "$policy_profile" \
      '{name:$name,target:{resources:[$gateway]},policyProfile:$profile,action:"CUSTOM",customProvider:{authzExtension:{resources:[$extension]}}}' \
      >"$body_file"
  fi

  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [ "$status" = "200" ]; then
    if [ "$(jq -Sc '{target,policyProfile,action,customProvider,httpRules:(.httpRules // [])}' "$response_file")" = "$(jq -Sc '{target,policyProfile,action,customProvider,httpRules:(.httpRules // [])}' "$body_file")" ]; then
      echo "Authorization policy ${policy_id} is current."
      rm -f "$response_file" "$body_file"
      return 0
    fi
    method=PATCH
    request_endpoint="${endpoint}?updateMask=target,action,customProvider,httpRules"
  elif [ "$status" = "404" ]; then
    method=POST
    request_endpoint="https://networksecurity.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies?authzPolicyId=${policy_id}"
  else
    echo "Unable to inspect authorization policy ${policy_id} (HTTP ${status}):" >&2
    jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
    rm -f "$response_file" "$body_file"
    return 1
  fi

  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -H 'Content-Type: application/json' \
    --data-binary "@${body_file}" \
    "$request_endpoint")"
  if [[ ! "$status" =~ ^2 ]]; then
    echo "Authorization policy ${policy_id} configuration failed with HTTP ${status}:" >&2
    jq . "$response_file" >&2 || sed -n '1,120p' "$response_file" >&2
    rm -f "$response_file" "$body_file"
    return 1
  fi

  operation_name="$(jq -er '.name' "$response_file")"
  echo "Configuring authorization policy ${policy_id}: ${operation_name}"
  rm -f "$response_file" "$body_file"
  wait_for_network_security_operation "$operation_name"
}

ensure_authz_policy hr-egress-iap-policy hr-agent-egress hr-egress-iap REQUEST_AUTHZ
ensure_authz_policy hr-egress-model-armor-policy hr-agent-egress hr-egress-model-armor CONTENT_AUTHZ
ensure_authz_policy hr-ingress-model-armor-policy hr-agent-ingress hr-ingress-model-armor CONTENT_AUTHZ

delete_authz_policy_if_exists() {
  local policy_id="$1"
  local endpoint="https://networksecurity.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies/${policy_id}"
  local response_file status operation_name
  response_file="$(mktemp)"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [ "$status" = "404" ]; then
    rm -f "$response_file"
    return 0
  fi
  if [ "$status" != "200" ]; then
    echo "Unable to inspect legacy authorization policy ${policy_id} (HTTP ${status})." >&2
    rm -f "$response_file"
    return 1
  fi
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [[ ! "$status" =~ ^2 ]]; then
    echo "Unable to delete legacy authorization policy ${policy_id} (HTTP ${status})." >&2
    rm -f "$response_file"
    return 1
  fi
  operation_name="$(jq -er '.name' "$response_file")"
  rm -f "$response_file"
  wait_for_network_security_operation "$operation_name"
}

delete_authz_extension_if_exists() {
  local extension_id="$1"
  local endpoint="https://networkservices.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${extension_id}"
  local response_file status operation_name
  response_file="$(mktemp)"
  status="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [ "$status" = "404" ]; then
    rm -f "$response_file"
    return 0
  fi
  if [ "$status" != "200" ]; then
    echo "Unable to inspect legacy authorization extension ${extension_id} (HTTP ${status})." >&2
    rm -f "$response_file"
    return 1
  fi
  status="$(curl -sS -o "$response_file" -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${access_token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "$endpoint")"
  if [[ ! "$status" =~ ^2 ]]; then
    echo "Unable to delete legacy authorization extension ${extension_id} (HTTP ${status})." >&2
    rm -f "$response_file"
    return 1
  fi
  operation_name="$(jq -er '.name' "$response_file")"
  rm -f "$response_file"
  wait_for_network_services_operation v1 "$operation_name"
}

# IAP service extensions are supported for Agent-to-Anywhere egress, not
# Client-to-Agent ingress. Remove the earlier dry-run resources after the
# enforced egress policy points to its replacement extension.
delete_authz_policy_if_exists hr-ingress-iap-policy
delete_authz_extension_if_exists hr-ingress-iap-dryrun
delete_authz_extension_if_exists hr-egress-iap-dryrun

if gcloud alpha agent-registry services describe workweek-mcp --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
  gcloud alpha agent-registry services delete workweek-mcp --project="$PROJECT_ID" --location="$REGION" --quiet
fi
gcloud alpha agent-registry services create workweek-mcp \
  --project="$PROJECT_ID" --location="$REGION" \
  --display-name="External WorkWeek MCP" \
  --description="Externally hosted WorkWeek MCP server" \
  --mcp-server-spec-type=tool-spec \
  --mcp-server-spec-content="$CONFIG_DIR/workweek-toolspec.json" \
  --interfaces=url=https://mock-saas.aishprabhat.demo.altostrat.com/work-week/mcp,protocolBinding=JSONRPC \
  --quiet

if gcloud alpha agent-registry services describe serviceimmediately-mcp --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
  gcloud alpha agent-registry services delete serviceimmediately-mcp --project="$PROJECT_ID" --location="$REGION" --quiet
fi
gcloud alpha agent-registry services create serviceimmediately-mcp \
  --project="$PROJECT_ID" --location="$REGION" \
  --display-name="External ServiceImmediately MCP" \
  --description="Externally hosted ServiceImmediately MCP server" \
  --mcp-server-spec-type=tool-spec \
  --mcp-server-spec-content="$CONFIG_DIR/serviceimmediately-toolspec.json" \
  --interfaces=url=https://mock-saas.aishprabhat.demo.altostrat.com/service-immediately/mcp,protocolBinding=JSONRPC \
  --quiet

# Register Google API endpoints for egress
for svc_info in \
  "vertex-ai-regional|https://${REGION}-aiplatform.googleapis.com" \
  "vertex-ai-regional-mtls|https://${REGION}-aiplatform.mtls.googleapis.com" \
  "vertex-ai-global|https://aiplatform.googleapis.com" \
  "vertex-ai-global-mtls|https://aiplatform.mtls.googleapis.com" \
  "generative-language|https://generativelanguage.googleapis.com" \
  "discovery-engine|https://discoveryengine.googleapis.com" \
  "discovery-engine-mtls|https://discoveryengine.mtls.googleapis.com" \
  "secret-manager|https://secretmanager.googleapis.com" \
  "secret-manager-mtls|https://secretmanager.mtls.googleapis.com" \
  "google-oauth|https://oauth2.googleapis.com" \
  "google-apis|https://www.googleapis.com" \
  "telemetry|https://telemetry.googleapis.com" \
  "telemetry-mtls|https://telemetry.mtls.googleapis.com" \
  "cloud-resource-manager|https://cloudresourcemanager.googleapis.com" \
  "cloud-resource-manager-mtls|https://cloudresourcemanager.mtls.googleapis.com"; do
  svc_id="${svc_info%%|*}"
  svc_url="${svc_info#*|}"
  if ! gcloud alpha agent-registry services describe "$svc_id" --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
    gcloud alpha agent-registry services create "$svc_id" \
      --project="$PROJECT_ID" --location="$REGION" \
      --display-name="$svc_id" \
      --description="Google API endpoint approved for governed HR Agent egress." \
      --endpoint-spec-type=no-spec \
      --interfaces="url=${svc_url},protocolBinding=http-json" \
      --quiet || true
  fi
done

echo "Agent Gateway, enforced egress IAP authorization, Model Armor inspection, and MCP registrations configured."
