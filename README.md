# Project Elevate — M3 HR Agent

This repository contains the solution design, Terraform, ADK application, gateway policy, tests, and evaluation evidence for the M3 HR Agent.

The deployed design uses:

- Gemini Enterprise Agent Platform Agent Runtime with Agent Identity and Memory Bank.
- Platform IAM plus Client-to-Agent Agent Gateway for ingress, and Agent-to-Anywhere Agent Gateway with enforced IAP for governed egress.
- Regional Model Armor prompt/response inspection on both gateway paths.
- A fully managed Vertex AI Search Enterprise Search Engine backed by the HR Policy Data Store. There is no Cloud Run or MCP-based RAG service.
- Secret Manager for the third-party MCP PAT. The agent fetches the current secret version just in time and adds authentication outside model-visible context. Direct contract tests use `X-MCP-Token`; the managed path intentionally sends the approved PAT as both `X-MCP-Token` and Bearer authorization.
- Externally hosted WorkWeek and ServiceImmediately MCP servers at `mock-saas.aishprabhat.demo.altostrat.com`.

## Repository layout

- `HR_Agentic_Solution_Design_Document.md` — template-aligned solution design and BRD traceability.
- `infra/` — Terraform for the project, APIs, storage, Secret Manager container, Vertex AI Search, Model Armor, audit policy, registry entries, and post-configuration.
- `gateway-config/` — Agent Gateway, authorization, and MCP tool-catalog inputs.
- `hr_agent/` — multi-agent ADK application and deterministic tool guardrails.
- `scripts/` — policy import, preview-API bootstrap, runtime deployment, local evaluation, and deployed E2E tests.
- `evaluation/` — BRD-linked quality and safety cases.
- `artifacts/` — non-secret deployment and evaluation evidence. `artifacts/private/` is ignored.

## Prerequisites

- An authenticated Google Cloud user with organization/project creation, billing, API enablement, IAM, Agent Platform, Discovery Engine, Model Armor, IAP, and Agent Registry permissions.
- Terraform 1.14 or later, Google provider 7.40.0, `gcloud`, `curl`, and `jq`.
- Python 3.11.
- An authorized third-party MCP PAT for the vendor test tenant.

Never place the PAT in Terraform variables, source, shell history, evaluation data, or logs.

## Deploy — Complete Step-by-Step Guide

### 1. Environment Setup

Export required environment variables (adjust for your deployment):

```bash
export PROJECT_ID="m3-hr-agent-$(date +%Y%m%d)-$(whoami)"
export PROJECT_NUMBER="YOUR_PROJECT_NUMBER"  # Set after project creation
export ORGANIZATION_ID="YOUR_ORG_ID"
export BILLING_ACCOUNT="YOUR_BILLING_ACCOUNT_ID"
export REGION="us-central1"
export DATA_STORE_LOCATION="global"
```

### 2. Prepare Local Environment

Create and activate the Python virtual environment:

```bash
cd /path/to/project-elevate
python3 -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 3. Initialize and Plan Terraform Deployment

Initialize Terraform and create the deployment plan:

```bash
terraform -chdir=infra init

terraform -chdir=infra plan \
  -var="project_id=$PROJECT_ID" \
  -var="organization_id=$ORGANIZATION_ID" \
  -var="billing_account=$BILLING_ACCOUNT" \
  -var="region=$REGION" \
  -var="data_store_location=$DATA_STORE_LOCATION" \
  -out=deploy.tfplan
```

Review the plan output to verify 62 resources will be created. This includes:
- Google Cloud Project
- 43+ GCP services (AI Platform, Discovery Engine, Model Armor, IAP, Secret Manager, etc.)
- Storage buckets for HR policy and agent staging
- Vertex AI Search Data Store and Search Engine
- Model Armor templates (ingress and egress)
- Secret Manager for MCP PAT
- IAM roles and audit logging

### 4. Apply Terraform Configuration

Deploy all infrastructure-as-code managed resources:

```bash
terraform -chdir=infra apply deploy.tfplan
```

**Output**: Terraform creates 62 resources. The final state file is saved to `infra/terraform.tfstate`.

### 5. Obtain and Secure the MCP PAT

Obtain the vendor-issued Personal Access Token through your authorized procurement process. **Never commit or log this token.**

Add the token to Secret Manager:

```bash
gcloud secrets versions add external-mcp-token \
  --project="$PROJECT_ID" \
  --data-file=-
```

When prompted, paste the token into the terminal and press `Ctrl+D` to send EOF. The token is now encrypted in Secret Manager; the Agent Runtime will fetch it just-in-time at startup.

### 6. Deploy Agent Gateway Infrastructure (REST/Preview API)

Agent Gateways use preview v1alpha1 APIs not yet supported by Terraform. Deploy via the bootstrap script:

```bash
export CONFIG_DIR="$(pwd)/gateway-config"

PROJECT_ID="$PROJECT_ID" \
PROJECT_NUMBER="$PROJECT_NUMBER" \
REGION="$REGION" \
CONFIG_DIR="$CONFIG_DIR" \
bash scripts/bootstrap_platform.sh
```

This script:
- Creates `hr-agent-ingress` Client-to-Agent gateway (platform IAM + Model Armor authorization)
- Creates `hr-agent-egress` Agent-to-Anywhere gateway (enforced IAP + registered MCP services)
- Waits for completion and validates both gateways are operational
- Registers the agent in the Agent Registry

**Expected output**: Both gateways exist and are ready for runtime binding.

### 7. Deploy Agent Runtime

Deploy the ADK-based Agent Runtime with Gemini model and guardrails:

```bash
export DEPLOY_OUTPUT="artifacts/deployment-output.json"

PROJECT_ID="$PROJECT_ID" \
PROJECT_NUMBER="$PROJECT_NUMBER" \
REGION="$REGION" \
STAGING_BUCKET="$PROJECT_ID-agent-staging" \
DEPLOY_OUTPUT="$DEPLOY_OUTPUT" \
python3 scripts/deploy_agent.py
```

This script:
- Packages the `hr_agent` ADK application and guardrails
- Creates or updates the Agent Runtime on Agent Platform
- Binds the ingress and egress gateways to the runtime
- Configures 24-hour Memory Bank TTL for multi-turn sessions
- Outputs the runtime resource name and principal (save for RBAC)

**Expected output**: JSON with runtime name like `projects/{PROJECT_NUMBER}/locations/{REGION}/reasoningEngines/{ID}`.

### 8. Import HR Policy Documents

Upload the approved HR policy handbook to the Discovery Engine Data Store:

```bash
PROJECT_ID="$PROJECT_ID" \
bash scripts/import_policy.sh
```

This script:
- Uploads `project-specs/ALTOSTRAT SINGAPORE EMPLOYEE POLICY HANDBOOK & CONDUCT GUIDELINES.pdf` to the Data Store
- Triggers document indexing in the Vertex AI Search Enterprise Search Engine
- Waits for indexing to complete

### 9. Configure MCP Tool Catalog and Registrations

Register the external MCP services (WorkWeek and ServiceImmediately) in the Agent Registry:

```bash
# Register WorkWeek
gcloud agents registry tools add \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --tool-source-kind=MCP \
  --mcp-server-uri="https://mock-saas.aishprabhat.demo.altostrat.com/work-week/mcp/" \
  --tool-source-name="WorkWeek"

# Register ServiceImmediately
gcloud agents registry tools add \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --tool-source-kind=MCP \
  --mcp-server-uri="https://mock-saas.aishprabhat.demo.altostrat.com/service-immediately/mcp/" \
  --tool-source-name="ServiceImmediately"
```

These registrations are referenced in the Agent Gateway egress configuration to enforce which MCP services the runtime can access.

### 10. Verify Deployment

Run the complete verification suite:

```bash
# Python guardrail unit tests
PYTHONPATH=. python3 -m pytest -q

# Live quality and safety evaluation (requires deployed runtime)
export HR_POLICY_SEARCH_ENGINE="projects/$PROJECT_NUMBER/locations/global/collections/default_collection/engines/hr-policy-search"

GOOGLE_GENAI_USE_VERTEXAI=true \
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_PROJECT_NUMBER="$PROJECT_NUMBER" \
GOOGLE_CLOUD_LOCATION="$REGION" \
HR_POLICY_SEARCH_ENGINE="$HR_POLICY_SEARCH_ENGINE" \
PYTHONPATH=. \
python3 scripts/run_evaluation.py --live

# Deployed remote E2E tests (5 core journeys)
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_remote_e2e.py

# MCP direct contract tests (WorkWeek and ServiceImmediately)
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
python3 scripts/run_mcp_contract_tests.py

# Concurrent performance benchmark (P95 latency)
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_remote_performance.py

# Write confirmation tests (rejection and approval workflows)
# WARNING: This creates real records in the vendor test tenant if EXECUTE_VENDOR_WRITE=true
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_mcp_write_confirmation.py
```

### 11. Validate Terraform State

Ensure all infrastructure remains in sync:

```bash
terraform -chdir=infra plan \
  -var="project_id=$PROJECT_ID" \
  -var="organization_id=$ORGANIZATION_ID" \
  -var="billing_account=$BILLING_ACCOUNT" \
  -var="region=$REGION" \
  -var="data_store_location=$DATA_STORE_LOCATION"
```

**Expected output**: `No changes.` This confirms all 62 Terraform resources are synchronized with the deployed state.

## Testing & Validation

### Unit Tests (Local, No Cloud Dependencies)

Fast guardrail regression tests — run after code changes:

```bash
PYTHONPATH=. python3 -m pytest -v
```

Expected: 15/15 passed. These tests verify:
- Cross-user access blocked (GUARD-001)
- Unmapped ticket identities rejected (GUARD-002)
- Critical priority keyword constraint (GUARD-003)
- Unknown capability default deny (GUARD-004)

### Quality & Safety Evaluation (Live Agent Runtime)

Full BRD-linked evaluation suite — 12 tests across policy accuracy, safety, and transaction correctness:

```bash
export HR_POLICY_SEARCH_ENGINE="projects/$PROJECT_NUMBER/locations/global/collections/default_collection/engines/hr-policy-search"

GOOGLE_GENAI_USE_VERTEXAI=true \
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_PROJECT_NUMBER="$PROJECT_NUMBER" \
GOOGLE_CLOUD_LOCATION="$REGION" \
HR_POLICY_SEARCH_ENGINE="$HR_POLICY_SEARCH_ENGINE" \
PYTHONPATH=. \
python3 scripts/run_evaluation.py --live
```

Expected: 12/12 passed in ~6.8 seconds average. Validates:
- **Policy tests** (POL-001 to POL-005): Accuracy, grounding, hallucination prevention
- **Safety tests** (SAFE-001 to SAFE-003): Prompt injection defense, cross-user isolation, unsupported-operation handling

Results saved to `artifacts/eval.json`.

### Remote E2E Tests (Agent Runtime via API Gateway)

End-to-end journeys through both Agent Gateways with Model Armor inspection:

```bash
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_remote_e2e.py
```

Expected: 5/5 passed. Tests:
1. Policy Q&A with grounding
2. Leave balance query
3. Leave submission workflow
4. Ticket creation
5. Malicious prompt blocked at ingress

Results saved to `artifacts/remote-e2e.json`.

### MCP Contract Tests (Direct Authentication)

Validates WorkWeek and ServiceImmediately MCP catalog and authentication:

```bash
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_PROJECT_NUMBER="$PROJECT_NUMBER" \
python3 scripts/run_mcp_contract_tests.py
```

Expected: 2/2 passed (approved reads). Tests:
- WorkWeek identity resolution and profile read
- ServiceImmediately ticket list operation

Notes:
- Token retrieved from Secret Manager at test time (not hardcoded)
- Unused tools (`cancel_leave_request`, `get_personal_info`) remain outside the runtime allow-list

Results saved to `artifacts/mcp-contract-e2e.json`.

### Performance Benchmark (Concurrent Load)

Measures first-event latency under concurrency:

```bash
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_remote_performance.py
```

Expected: 6/6 passed at concurrency 3; P95 ~5.7 seconds. Metrics:
- Policy retrieval: ~4.7 s
- WorkWeek operations: ~3.6 s
- ServiceImmediately operations: ~4.4 s

Results saved to `artifacts/remote-performance.json`.

### Write Confirmation Tests (Optional: Creates Records)

Tests rejection and approval workflows for write operations:

```bash
# WITHOUT this flag: dry-run only (safe, no records created)
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_mcp_write_confirmation.py

# WITH this flag: creates real records in vendor test tenant (authorized use only)
EXECUTE_VENDOR_WRITE=true \
GOOGLE_CLOUD_PROJECT="$PROJECT_ID" \
GOOGLE_CLOUD_LOCATION="$REGION" \
python3 scripts/run_mcp_write_confirmation.py
```

Expected: 2/2 passed. The write-confirmation script is intentionally omitted from the default verification flow because `EXECUTE_VENDOR_WRITE=true` creates a real record in the configured vendor tenant.

**Caution**: Only enable `EXECUTE_VENDOR_WRITE=true` if authorized. This creates live records in the external mock ServiceImmediately tenant.

### Infrastructure Reconciliation

Final validation that all 62 Terraform-managed resources are in sync:

```bash
terraform -chdir=infra plan \
  -var="project_id=$PROJECT_ID" \
  -var="organization_id=$ORGANIZATION_ID" \
  -var="billing_account=$BILLING_ACCOUNT" \
  -var="region=$REGION" \
  -var="data_store_location=$DATA_STORE_LOCATION"
```

Expected: `No changes.` The remote and MCP suites require a deployed runtime and an enabled Secret Manager token version.

## Deployment Architecture Reference

### Resources in Terraform (62 tracked objects)

| Component | Resource Type | Purpose |
|-----------|---------------|---------|
| Project | `google_project` | Test GCP project with auto-created network disabled |
| Services | `google_project_service` | 43 required APIs enabled |
| Policy Storage | `google_storage_bucket` | Immutable HR policy handbook versioning |
| Staging | `google_storage_bucket` | Agent code/package staging area |
| Policy Data Store | `google_discovery_engine_data_store` | Vertex AI Search indexing corpus |
| Search Engine | `google_discovery_engine_search_engine` | Enterprise Search serving layer with LLM add-on |
| Model Armor (Ingress) | `google_model_armor_template` | Prompt/response inspection for Client-to-Agent |
| Model Armor (Egress) | `google_model_armor_template` | Prompt/response inspection for Agent-to-Anywhere |
| MCP PAT Secret | `google_secret_manager_secret` | Encrypted third-party authentication token |
| Audit Logging | `google_project_iam_audit_config` | Data Access logs for core services |
| IAM | `google_project_iam_member` | Model Armor callout user roles |
| Registry | `google_agent_registry_service` | Google-managed endpoints for egress registry |

### Resources NOT in Terraform (Deployed via Scripts)

| Component | Deployment | Reason |
|-----------|------------|--------|
| Agent Gateway (Ingress) | `bootstrap_platform.sh` + REST v1alpha1 | Preview API not in provider |
| Agent Gateway (Egress) | `bootstrap_platform.sh` + REST v1alpha1 | Preview API not in provider |
| Agent Runtime | `deploy_agent.py` + Vertex AI SDK | Dynamic Python application upload |
| MCP Tool Registrations | `gcloud agents registry` | Registry entries post-infrastructure |
| Policy Import | `import_policy.sh` | Document ingestion after Data Store creation |

### External Resources (Vendor-Hosted)

| Component | Location | Responsibility |
|-----------|----------|-----------------|
| WorkWeek MCP | `mock-saas.aishprabhat.demo.altostrat.com/work-week/mcp/*` | Third party |
| ServiceImmediately MCP | `mock-saas.aishprabhat.demo.altostrat.com/service-immediately/mcp/*` | Third party |
| MCP PAT Token | Secret Manager v1 | Obtained from vendor; managed by us |

## Post-Deployment Checklist

After completing all deployment steps:

- [ ] All 62 Terraform resources created (verify: `terraform -chdir=infra state list | wc -l`)
- [ ] Agent Gateways operational (`hr-agent-ingress`, `hr-agent-egress`)
- [ ] Agent Runtime deployed and accessible
- [ ] Secret Manager contains MCP PAT version 1
- [ ] HR Policy documents indexed (check Discovery Engine logs)
- [ ] Unit tests pass: 15/15
- [ ] Live evaluation passes: 12/12
- [ ] Remote E2E passes: 5/5
- [ ] MCP contract tests pass: 2/2
- [ ] Performance benchmark complete with results
- [ ] Terraform plan reports "No changes"
- [ ] Deployment evidence saved to `artifacts/`

## Troubleshooting

### Agent Gateway Creation Timeout
If `bootstrap_platform.sh` times out waiting for gateway creation, check:
- Ensure APIs are enabled: `gcloud services list --project=$PROJECT_ID | grep -E "networkservices|agentregistry"`
- Verify IAM permissions: Project Editor or custom role with `networkservices.agentGateways.*`

### Model Armor Template Not Found
If scripts fail with "Model Armor not found", check:
- `google_model_armor_template` resources exist: `terraform -chdir=infra state list`
- Service is enabled: `gcloud services list --project=$PROJECT_ID | grep modelarmor`

### MCP Authentication Failure
If tests fail with `401 Unauthorized` from WorkWeek or ServiceImmediately:
- Verify token in Secret Manager: `gcloud secrets versions list --project=$PROJECT_ID external-mcp-token`
- Check token is valid (not expired)
- Confirm the managed path sends the PAT as both `X-MCP-Token` and Bearer authorization

### Policy Search Not Returning Results
If policy Q&A returns "I cannot find information", check:
- Documents indexed in the `hr-policy-data-store` Data Store
- Search engine `hr-policy-search` status is active

## Current test deployment

- Project: `m3-hr-agent-20260720-zken`
- Region: `us-central1`
- Runtime: `projects/195828323714/locations/us-central1/reasoningEngines/8335671978320986112`
- Final BRD-linked live evaluation: 12/12 passed.
- Deployed remote E2E suite: 5/5 passed.
- Direct authenticated MCP reads: 2/2 passed. WorkWeek advertises two accepted-but-unused extra tools that remain excluded by the runtime allow-list.
- Enforced IAP verification: final E2E window recorded 85 allowed, 0 denied, and 0 dry-run decisions; rollout also proved unregistered destinations are denied.
- Managed rejection/confirmation workflow: 2/2 passed.
- Concurrent time-to-first-event smoke benchmark: 6/6 passed at concurrency 3; P95 5.690 seconds.
- Final Terraform reconciliation: no changes.
- Accepted project decisions: current MCP token, managed dual-header authentication, unused extra WorkWeek tools, and bounded load smoke evidence.

See `DEPLOYMENT_AND_EVALUATION_REPORT.md` for the detailed result and limitations.
