#!/usr/bin/env python3
"""Create or update the governed ADK agent on Agent Runtime."""

from __future__ import annotations

import json
import os
from pathlib import Path

from google.genai import types as genai_types
import vertexai
from vertexai import agent_engines
from vertexai import types

from hr_agent.agent import root_agent


PROJECT_ID = os.environ["PROJECT_ID"]
PROJECT_NUMBER = os.environ["PROJECT_NUMBER"]
REGION = os.environ["REGION"]
STAGING_BUCKET = os.environ["STAGING_BUCKET"]
# Agent Identity principals are scoped to the project's organization, so the
# principal reported below must follow the deployment target rather than a
# single hard-coded org.
ORGANIZATION_ID = os.environ.get("ORGANIZATION_ID", "654680440018")
OUTPUT_FILE = Path(os.environ["DEPLOY_OUTPUT"])
DISPLAY_NAME = "M3 HR Enterprise Agent"
ROOT = Path(__file__).resolve().parents[1]


def agent_gateway_config() -> dict:
    """Governed ingress/egress bindings.

    Client-to-Agent ingress is bound by default. It can be omitted to isolate
    whether the ingress gateway is interfering with the ADK stream path, which
    surfaces as an executed operation whose response returns NOT_FOUND.
    """
    config = {
        "agent_to_anywhere_config": {
            "agent_gateway": (
                f"projects/{PROJECT_ID}/locations/{REGION}/agentGateways/hr-agent-egress"
            )
        },
    }
    if os.environ.get("BIND_CLIENT_TO_AGENT_GATEWAY", "true").lower() != "false":
        config["client_to_agent_config"] = {
            "agent_gateway": (
                f"projects/{PROJECT_ID}/locations/{REGION}/agentGateways/hr-agent-ingress"
            )
        }
    return config


def deployment_config() -> dict:
    return {
        "display_name": DISPLAY_NAME,
        "description": "Governed HR policy, WorkWeek, and ServiceImmediately agent",
        "identity_type": types.IdentityType.AGENT_IDENTITY,
        "staging_bucket": f"gs://{STAGING_BUCKET}",
        "requirements": (ROOT / "hr_agent" / "requirements.txt").read_text().splitlines(),
        # Agent Engine preserves relative archive paths.  Uploading an absolute
        # path nests the package below /home/... and makes `hr_agent`
        # unimportable when the service unpickles the ADK application.
        "extra_packages": ["hr_agent"],
        "env_vars": {
            "GOOGLE_GENAI_USE_VERTEXAI": "TRUE",
            "GOOGLE_CLOUD_LOCATION": REGION,
            "GOOGLE_CLOUD_PROJECT_NUMBER": PROJECT_NUMBER,
            "GRPC_DNS_RESOLVER": "native",
            "HR_POLICY_SEARCH_ENGINE": (
                f"projects/{PROJECT_NUMBER}/locations/global/collections/"
                "default_collection/engines/hr-policy-search"
            ),
            "MCP_TOKEN_SECRET_VERSION": (
                f"projects/{PROJECT_NUMBER}/secrets/external-mcp-token/versions/latest"
            ),
            "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES": "False",
            "GOOGLE_API_USE_MTLS_ENDPOINT": "never",
            "GOOGLE_API_USE_CLIENT_CERTIFICATE": "false",
        },
        "context_spec": {
            "memory_bank_config": {
                "ttl_config": {
                    "default_ttl": "86400s",
                    "memory_revision_default_ttl": "86400s",
                }
            }
        },
        "agent_gateway_config": agent_gateway_config(),
        # A warm instance avoids cold-start NOT_FOUND responses while set_up()
        # initializes the MCP toolsets on a newly scaled instance.
        "min_instances": int(os.environ.get("MIN_INSTANCES", "0")),
        "max_instances": 2,
        "python_version": "3.11",
        "labels": {
            "environment": "test",
            "workload": "m3-hr-agent",
            "managed-by": "terraform",
        },
    }


def main() -> None:
    os.chdir(ROOT)
    # AdkApp still reads deployment context from the legacy Vertex AI global
    # initializer when it is serialized.  Initialize it explicitly so the
    # managed session and memory clients do not inherit the operator's local
    # default project.
    vertexai.init(
        project=PROJECT_ID,
        location=REGION,
        staging_bucket=f"gs://{STAGING_BUCKET}",
    )
    client = vertexai.Client(
        project=PROJECT_ID,
        location=REGION,
        http_options=genai_types.HttpOptions(api_version="v1beta1"),
    )
    matches = [
        engine
        for engine in client.agent_engines.list()
        if engine.api_resource.display_name == DISPLAY_NAME
    ]
    if len(matches) > 1:
        raise RuntimeError(f"Multiple Agent Runtime instances named {DISPLAY_NAME!r}")

    # Leave telemetry under the Agent Runtime console/environment control.
    # Forcing the legacy tracing flag performs a synchronous mTLS telemetry
    # probe during set_up(), before the per-agent gateway IAM can be granted.
    app = agent_engines.AdkApp(agent=root_agent)
    config = deployment_config()
    if matches:
        remote = client.agent_engines.update(
            name=matches[0].api_resource.name,
            agent=app,
            config=config,
        )
        action = "updated"
    else:
        remote = client.agent_engines.create(agent=app, config=config)
        action = "created"

    api_resource = remote.api_resource
    engine_id = api_resource.name.rsplit("/", 1)[-1]
    output = {
        "action": action,
        "name": api_resource.name,
        "engine_id": engine_id,
        "display_name": api_resource.display_name,
        "principal": (
            f"principal://agents.global.org-{ORGANIZATION_ID}.system.id.goog/"
            f"resources/aiplatform/projects/{PROJECT_NUMBER}/locations/{REGION}/"
            f"reasoningEngines/{engine_id}"
        ),
    }
    OUTPUT_FILE.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
