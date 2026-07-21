# M3 HR Agent — Deployment and Evaluation Report

## Outcome

The enterprise-controlled solution is deployed and operational in test project `m3-hr-agent-20260720-zken` (`195828323714`), region `us-central1`. Terraform tracks 62 objects, 43 project services are enabled, and the final Terraform plan reports **No changes**. The managed Agent Runtime, both Agent Gateway paths, both Model Armor templates, fully managed Vertex AI Search policy retrieval, Secret Manager authentication, and both externally hosted MCP integrations have been exercised end to end.

This is engineering test evidence, not production approval. Product, HR, ITSM, Security, Privacy/Legal, SRE, and vendor sign-off remain external approval gates.

## Deployed resources

| Area | Deployed state |
| :--- | :--- |
| Agent Runtime | `projects/195828323714/locations/us-central1/reasoningEngines/8335671978320986112`; Agent Identity; min 0/max 2 instances; 24-hour Memory Bank TTL; platform telemetry enabled. |
| Ingress | `hr-agent-ingress` Client-to-Agent Agent Gateway with fail-closed Model Armor content authorization for the supported ADK stream path. Gemini Enterprise/Agent Runtime IAM authenticates and authorizes client invocation. IAP Service Extensions are not attached because Client-to-Agent mode does not support them. |
| Egress | `hr-agent-egress` Agent-to-Anywhere Agent Gateway with regional Agent Registry allow-list, exact Agent Identity egress IAM, enforced IAP request authorization, and fail-closed Model Armor inspection. |
| Policy RAG | Approved handbook in a private, versioned GCS bucket, `hr-policy-data-store`, and Enterprise Search Engine `hr-policy-search`. These are fully managed Vertex AI Search/GCP resources; no Cloud Run or MCP-based RAG service exists. |
| External MCP | Third-party WorkWeek at `https://mock-saas.aishprabhat.demo.altostrat.com/work-week/mcp/*` and ServiceImmediately at `https://mock-saas.aishprabhat.demo.altostrat.com/service-immediately/mcp/*`; neither service is deployed in this project. |
| Secrets | `external-mcp-token` version 1 is enabled. The Agent Runtime identity has secret-level accessor permission and retrieves the token just in time. The payload is absent from source, Terraform state inputs, and artifacts. |
| Safety and audit | Separate ingress/egress Model Armor templates with inspect-and-block behavior; Data Access audit logging on core services; sanitized evaluation trajectories. |
| Registry | Managed runtime, required Google endpoints, and both external MCP services are registered for governed egress. |

## Approved MCP authentication design

The documented direct MCP contract succeeds with `X-MCP-Token` alone. On the live Agent Gateway path, the vendor evaluates the standard `Authorization` header ahead of `X-MCP-Token`; the managed runtime therefore intentionally sends the same just-in-time Secret Manager PAT in both headers outside model-visible context. Product has approved this dual-header design and the current token for the test deployment. Header values remain excluded from source, state inputs, prompts, artifacts, and telemetry.

## Test evidence

| Test | Result | Evidence |
| :--- | :--- | :--- |
| Python guardrail regression | 15/15 passed | `PYTHONPATH=. .venv/bin/pytest -q` |
| BRD-linked live quality/safety evaluation | 12/12 passed; 6.836 s average, 10.177 s maximum total completion | [`artifacts/eval.json`](artifacts/eval.json) |
| Post-Terraform deployed remote E2E | 5/5 passed | [`artifacts/remote-e2e.json`](artifacts/remote-e2e.json) |
| Enforced IAP audit verification | 85 allowed, 0 denied, 0 dry-run decisions in the final 5/5 run; rollout also proved unregistered destinations are denied | Cloud Logging IAP audit records, 2026-07-21 02:02–02:04 UTC |
| Direct authenticated MCP operations/catalog | 2/2 approved reads passed; accepted extra WorkWeek tools remain excluded | [`artifacts/mcp-contract-e2e.json`](artifacts/mcp-contract-e2e.json) |
| Managed confirmation workflow | 2/2 passed: rejection wrote nothing; explicit confirmation wrote once | [`artifacts/mcp-write-confirmation.json`](artifacts/mcp-write-confirmation.json) |
| Concurrent first-event smoke benchmark | 6/6 passed at concurrency 3; P50 5.270 s, P95 5.690 s, max 5.767 s | [`artifacts/remote-performance.json`](artifacts/remote-performance.json) |
| Model Armor malicious-prompt test | Passed; blocked at ingress in 0.378 s | [`artifacts/remote-e2e.json`](artifacts/remote-e2e.json) |
| Terraform reconciliation | Passed; final detailed-exit-code plan returned 0 and **No changes** | `infra/terraform.tfstate` and final command output |
| Credential-pattern scan | Passed; zero token-shaped strings in source/artifacts and zero in matching Cloud Logging entries | Metadata-only scan; no secret payload printed |

The final enforced remote suite measured first events at 4.746 s for policy, 4.230 s for the unsupported-operation guard, 3.562 s for WorkWeek, and 4.410 s for ServiceImmediately. Total completion ranged from 4.230 s to 14.362 s for response-generating cases. Product accepted the existing bounded concurrency smoke evidence for this MVP test cycle.

## Write-test impact

Three uniquely tagged, low-priority synthetic IT tickets were created in the external mock ServiceImmediately tenant during authorized hill-climb testing. Rejection cases produced no write. No WorkWeek mutation was attempted because HR records have higher data-integrity impact and a safe disposable test identity/calendar rule was not supplied. Artifacts intentionally omit employee IDs, ticket IDs, arguments, and response bodies.

## Hill-climb record

| Iteration | Finding | Change and verified outcome |
| :--- | :--- | :--- |
| Policy retrieval 1 | Standard snippets truncated policy facts. | Added focused retrieval and retained evidence-only refusal. |
| Policy retrieval 2 | Correct but variable multi-search retrieval increased latency. | Added the fully managed Enterprise Search serving layer with extractive answers/segments; final BRD suite passed 12/12. |
| MCP authentication | Direct `X-MCP-Token` passed, but the gateway/vendor path returned 401. | Loaded the PAT from Secret Manager at connection time and added the approved dual-header behavior; managed WorkWeek and ServiceImmediately reads passed. |
| Trusted identity | Vendor identity response used `structuredContent.result`. | Restricted parsing of that shape to the authenticated identity callback and bound it to session state; cross-user deterministic tests pass. |
| Ticket creation | The model could skip `list_tickets` before a create attempt. | Promoted the sequence from prompt guidance to a deterministic fresh-session-state guard; managed trace proves identity → list → create → confirmation. |
| Confirmation fixture | Similar synthetic descriptions were correctly treated as potential duplicates. | Used distinct tagged incidents; rejection and explicit confirmation both passed without weakening duplicate checking. |
| MCP catalog comparison | Live WorkWeek advertised two tools absent from the supplied specification. | Product accepted them as unused; `cancel_leave_request` and `get_personal_info` remain outside the runtime allow-list and cannot be invoked by the agent. |
| IAP enforcing rollout | Enforcing IAP denied the gRPC Secret Manager and Vertex AI Search calls because the governed entries were HTTP/JSON endpoints. | Switched both clients to REST transports, retained hostname-scoped HTTP/JSON registry entries, redeployed, and passed 5/5 with no dry-run decisions. |

## Remaining production gaps

- Complete ownership-negative, revoked/expired-token, schema-drift, 429/5xx/timeout, unknown-write-outcome, gateway-bypass, response-block/redaction, and cross-session isolation suites.
- Obtain a disposable WorkWeek test identity and approved calendar/day-count rules before any live HR mutation tests.
- Resolve BRD-to-contract gaps for department/hire date/remote-work status, Leave of Absence, holiday calendar, and leave compensation.
- Obtain the approvals and operational decisions listed in Section 10 of the solution design.

## Files

- [Solution design](HR_Agentic_Solution_Design_Document.md)
- [Terraform](infra/main.tf)
- [ADK agent](hr_agent/agent.py)
- [Evaluation cases](evaluation/eval_cases.json)
- [Remote E2E evidence](artifacts/remote-e2e.json)
- [MCP contract evidence](artifacts/mcp-contract-e2e.json)
- [Write-confirmation evidence](artifacts/mcp-write-confirmation.json)
- [Performance evidence](artifacts/remote-performance.json)
