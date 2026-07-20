# Analysis and Mapping Report: HR Agentic Solution (MVP 1)

This report maps the business requirements from `HR Agentic Solution BRD.pdf` to the structural template defined in `Enterprise Agentic Solution Design Document .pdf`.

---

## Document Control Mapping

### Document Metadata
| Field | Target Value / Proposed Content | Notes |
| :--- | :--- | :--- |
| **Author(s)** | Explorer Agent (`explorer_m0`) | Prepared as part of the initial discovery phase. |
| **Date** | 2026-07-20 | Current date of analysis. |
| **Status** | Draft | Ready for orchestrator review. |
| **Target Audience** | Engineering Team, Project Stakeholders, Security Auditors | Defined based on the technical and compliance requirements in the BRD. |

### Revision History
| Version | Date | Author | Description of Change |
| :--- | :--- | :--- | :--- |
| 0.1 | 2026-07-20 | Explorer Agent (`explorer_m0`) | Initial analysis and mapping of BRD to Design Document template. |

---

## Section 1: Executive Summary & Scope Boundaries

### 1.1. Business Overview & Context
- **Business Challenge & Pain Points**: 
  - Employees need immediate, conversational access to HR services without navigating complex backend UIs (WorkWeek and ServiceImmediately).
  - High volume of routine Tier 1 HR and IT helpdesk queries that consume valuable agent time.
- **High-Level Business Goals**:
  - Deflect routine Tier 1 HR/IT ticket volume by at least 40% within the first six months.
  - Streamline HR transactions (leave submission, incident ticket updates) via a conversational user interface.
  - Validate cross-system orchestration across HR policies, WorkWeek, and ServiceImmediately.
  - Mitigate AI risks to achieve zero policy violations and data leaks.
  - Maintain 100% visibility over solution deployment state, versioning, and authorized tool access.

### 1.2. Scope Boundaries
- **In-Scope for MVP 1**:
  - **Conversational UI**: Standard web-based chat interface or integration with an enterprise chat client.
  - **Policy & Informational Queries (RAG)**: Answers questions based on static HR documents (Leave, Expense, Remote Work, Code of Conduct).
  - **Employee Self-Service (WorkWeek)**: Read profile details and leave balances; write contact details and submit leave requests.
  - **Support Desk Management (ServiceImmediately)**: Read ticket status/comments; write incident tickets, comments, and update status to 'Resolved'.
  - **Cross-System Orchestration**: Action chaining across RAG, WorkWeek, and ServiceImmediately (Equipment Procurement UC-2.1, Medical Leave UC-2.2, Relocation UC-2.3).
  - **Governance & Security**: Tool access limits, origin verification, prompt injection/jailbreak/off-topic blocks, SPII redaction, RBAC.
- **Out-of-Scope for MVP 1**:
  - Integration with systems other than WorkWeek, ServiceImmediately, and the designated Policy Repository.
  - Multi-lingual capabilities.
  - Processing of payroll data, performance reviews, or compensation details.
  - Voice-based interactions.

### 1.3. Target Architecture Overview
- **System Components**:
  1. **Conversational Front-End**: Web chat client.
  2. **AI Orchestration / Agent Platform**: Core logic to manage multi-turn dialog, parse intents (NLU), track state, and invoke tools.
  3. **RAG / Knowledge Base Engine**: Vector store containing ingested, chunked, and indexed static HR policies.
  4. **Security & Guardrail Module**: Inline input/output scanner (safety, off-topic, SPII redaction, RBAC checks).
  5. **Enterprise System Connectors**: API clients connecting to WorkWeek (HCM) and ServiceImmediately (ITSM).
- **Hosting Environment**: Single-tenant environment enforcing traceably bounded execution and authenticating origin.
- *Note: Diagram placeholder to be populated by the Implementer.*

### 1.4. Alternatives Considered
- **Direct LLM Integration vs. Agent Platform**: Directly using LLM APIs lacks traceably bounded execution, session isolation, and lifecycle governance. The Agent platform is chosen to satisfy governance (FR-1.1) and security (FR-1.2) requirements.
- **Caching Profiles vs. Real-time Fetch**: Caching profile/PTO data in the AI layer could lead to stale data and security compliance issues. Real-time fetch (FR-3.4) guarantees correctness.
- **Synchronous vs. Asynchronous Execution**: Sync execution could cause conversational timeouts. Async execution (NFR-2.3) for long-running writes/orchestration keeps the interface responsive.

---

## Section 2: Production-Ready Future State Design

- **Authentication Evolution**: Transition from MVP 1 functional test credentials to enterprise identity management systems (SSO, Active Directory, Okta) to support secure, real-world delegated authorization (FR-3.1).
- **Scale and Tenancy**: Evolve from a single-tenant MVP deployment to multi-tenancy as the solution scales across enterprise subsidiaries.
- **Channel Expansion**: Support voice-based interactions and deep integrations with other enterprise collaboration tools.
- **Domain Expansion**: Expand conversational capabilities to encompass payroll, performance evaluations, and compensation management (out of scope for MVP 1).

---

## Section 3: System Flows, Sequence Diagrams & Agent Design

### 3.1. General Request Flow Sequence
1. **User Prompt** submitted to Conversational UI.
2. **Input Safety Scanning**: Intercept prompt injection, jailbreaks, and off-topic requests (FR-1.3). Block and log if unsafe.
3. **Intent Parsing & Entity Extraction (NLU)**: Check user intent, resolving typos/synonyms (FR-2.1).
4. **RBAC & Authorization Check**: Validate if the specific employee is authorized to perform the action or query the data (FR-1.5, FR-3.1).
5. **Tool Invocation**:
   - **RAG Lookup**: For policy Q&A, query vectorized policy repository, return grounded answer with citation metadata (FR-5.1 - FR-5.4).
   - **WorkWeek API**: Retrieve profiles or submit leave (FR-3.2).
   - **ServiceImmediately API**: Query status or update incidents (FR-4.2).
6. **Orchestration Chaining (UC-2.x)**: Execute sequence of tools, verifying each step.
7. **Output Validation & Redaction**: Check output for toxicity, hallucinations, and sensitive PII. Redact SPII before logging/displaying (FR-1.3, FR-1.4).
8. **Response Rendered** to User with citations if policy-related.

### 3.2. Agent Design & Tool Boundaries
- The agent must be restricted to a traceably bounded execution context. Tools exposed to the agent:
  - `query_policy_knowledge_base(query)`
  - `get_employee_profile(employee_id)`
  - `update_contact_information(employee_id, address, phone)`
  - `get_time_off_balances(employee_id)`
  - `submit_leave_request(employee_id, start_date, end_date, type, work_days)`
  - `get_incident_ticket_details(ticket_id)`
  - `create_incident_ticket(employee_id, category, short_description, priority)`
  - `post_ticket_comment(ticket_id, comment)`
  - `update_ticket_status(ticket_id, status, resolution_notes)`

---

## Section 4: Security, Governance & Identity

- **Delegated Authorization & Authentication Origin**:
  - MVP 1 uses functional test credentials.
  - All calls must pass a composite token scoping data retrieval strictly to the specific employee querying the system (FR-3.1) and verifying the authorized automation origin (FR-1.2).
- **Role-Based Access Control (RBAC)**:
  - Users are strictly isolated from other users' data. Access to employee profile, contact info, and leave balances is restricted to the owner (FR-1.5).
- **PII & Conversation History Isolation**:
  - Enforce real-time detection and redaction of SPII (FR-1.4) in logs.
  - Session memory must be isolated; no caching of dynamic employee data or cross-session leakage (FR-2.2, FR-3.4).

---

## Section 5: Integration Details & Error Handling

### 5.1. Integration Methods
- **WorkWeek (HCM)**: REST/SOAP APIs supporting read and write actions for employee records.
- **ServiceImmediately (ITSM)**: REST APIs supporting incident creation, updates, and lifecycle changes.
- **Policy Repository**: Document indexing connector for static policy documents.

### 5.2. Integration Guardrails
- **WorkWeek Guardrails (FR-3.3)**:
  - *Balance Constraints*: Verify that requested leave days do not exceed accrued Vacation/Sick balances.
  - *Temporal Validity*: Reject past dates and ensure start dates precede end dates.
  - *Format Restrictions*: Validate email and phone formats before profile updates.
- **ServiceImmediately Guardrails (FR-4.3)**:
  - *Transition Constraints*: Prevent invalid status hops (e.g., direct transition from 'New' to 'Closed').
  - *Duplication Mitigation*: Reject duplicate tickets submitted in quick succession.
  - *Priority Verification*: Match description keywords to priority tiers.
- **Policy Retrieval Guardrails (FR-5.4)**:
  - *Strict Grounding*: Refuse response if retrieved context is insufficient.
  - *Domain Containment*: Reject prompts outside corporate HR policy scope.
  - *Citation Integrity*: Citations must link to verified policy documents.

### 5.3. Error Handling and Fallbacks
- **Graceful Failure (NFR-4.1)**: User receives a friendly, non-technical message ("Service is temporarily unavailable") instead of stack traces.
- **Transient Fault Tolerance (NFR-4.2)**: Automated retries with exponential backoff for timeouts/rate limits.
- **Orchestration Consistency (NFR-4.3)**: Detailed error logging and manual follow-up instructions or compensating actions (e.g., if a ticket fails after leave submission, notify the user with a manual reference number).

---

## Section 6: Cost Estimation & FinOps

- **Cost Drivers**:
  - LLM input/output tokens (highest driver during multi-turn dialogs and RAG searches).
  - Hosting costs for the security/guardrails scanning module.
  - Database and Vector Search storage fees for HR policies.
  - Downstream api execution volume.

---

## Section 7: Deployment & Delivery Plan

- **Phased Milestones**:
  - **Phase 1**: Environment setup, Policy RAG ingestion, and UC-1.1 validation.
  - **Phase 2**: WorkWeek and ServiceImmediately single-system API integrations (UC-1.2, UC-1.3) using test credentials.
  - **Phase 3**: Agent orchestration logic & cross-system chaining (UC-2.1, UC-2.2, UC-2.3).
  - **Phase 4**: Security and safety guardrails implementation (Input/Output scanning, SPII redaction, RBAC enforcement).
  - **Phase 5**: Execution of benchmark evaluation and UAT.

---

## Section 8: Assumptions, Constraints, Risk & Mitigations

- **Assumptions**:
  - Static policies are fully curated and up to date in the repository.
  - Test environments for WorkWeek and ServiceImmediately are available and pre-populated with test users.
- **Constraints**:
  - MVP 1 is strictly single-tenant.
  - No SSO integration in MVP 1.
- **Risks & Mitigations**:
  - *Risk*: Data exposure or PII leakage in logs. *Mitigation*: Implementation of automated SPII redaction scanning (FR-1.4).
  - *Risk*: Prompt injections executing malicious actions. *Mitigation*: Pre-execution input validation (FR-1.3).
  - *Risk*: Inconsistent state in cross-system transactions. *Mitigation*: Compensating actions and fallback logs (NFR-4.3).

---

## Section 9: Quality Evaluation & UAT Framework

### Acceptance Criteria Metrics
| Success Metric | Target / Benchmark |
| :--- | :--- |
| **Policy Q&A Accuracy** | >= 95% accuracy on benchmark questions; 0% hallucination of policy facts. |
| **Transaction Integrity** | 100% transaction correctness (no data corruption or unauthorized updates). |
| **Cross-System Orchestration** | Pass/Fail on all defined Cross-System Use Cases (UC-2.x). |
| **Safety & Guardrail Efficacy** | 100% detection of known prompt injection/jailbreak test cases; < 1% false positives. |
| **Response Latency** | < 10.0 seconds average response time; safety scanning overhead < 300ms. |
| **Auditability & Traceability** | 100% log coverage for all API interactions and safety blocks. |
| **Resilience & Error Handling** | 100% graceful degradation; no technical leaks; clear fallback instructions. |
| **User Experience (NLU)** | Qualitative "Pass" on ease of use and natural flow. |

---

## Section 10: Assumptions / Open Questions

1. **Document Sync Latency Parameter (FR-5.5)**:
   - **Open Question**: The BRD specifies a placeholder latency "[X]" for reflecting updates to policy documents in the vector knowledge base.
   - **Recommendation**: Define a sync window of **4 hours** as a starting target, subject to business review.
2. **Specific Chat Channel Integration**:
   - **Open Question**: The exact chat client for Conversational UI integration is not specified (standard web UI vs. specific enterprise client like Slack or Microsoft Teams).
   - **Recommendation**: Deploy a standalone web-based chat widget first, with hooks ready for Slack/Teams integration in Phase 2.
3. **Compensating Action Definitions**:
   - **Open Question**: Specific compensating actions for failures during UC-2.x (Cross-System Orchestration) need detailed mapping.
   - **Recommendation**: If a downstream step fails, log it as an error and create a priority ticket in ServiceImmediately tracking the partial transaction state.
