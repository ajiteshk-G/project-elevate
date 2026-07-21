#!/usr/bin/env python3
"""Verify managed ADK rejection and confirmation for one benign test ticket."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import time
from typing import Any

from google.genai import types
import vertexai

from scripts.run_remote_e2e import DISPLAY_NAME, summarize_event


PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
REGION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
OUTPUT = Path(
    os.environ.get("WRITE_TEST_OUTPUT", "artifacts/mcp-write-confirmation.json")
)
EXECUTE_WRITE = os.environ.get("EXECUTE_VENDOR_WRITE", "false").lower() == "true"
TEST_TAG = os.environ.get("WRITE_TEST_TAG", "baseline")

def _prompt(case: str) -> str:
    return (
        "Create a ServiceImmediately ticket with category IT, priority 4 - Low, "
        "and short description 'Mouse cursor intermittently freezes during "
        f"spreadsheet editing ({TEST_TAG}-{case}); synthetic test, no action required'. "
        "The parenthesized tag identifies a distinct synthetic incident; only an exact "
        "matching tag should be treated as a duplicate."
    )


def _stream(
    client: vertexai.Client,
    runtime_name: str,
    *,
    user_id: str,
    session_id: str,
    message: str | dict[str, Any],
) -> tuple[list[dict[str, Any]], float]:
    started = time.perf_counter()
    events = [
        summarize_event(response)
        for response in client.agent_engines._stream_query(
            name=runtime_name,
            config={
                "class_method": "stream_query",
                "input": {
                    "user_id": user_id,
                    "session_id": session_id,
                    "message": message,
                },
            },
        )
    ]
    return events, round((time.perf_counter() - started) * 1000, 1)


def _raw_stream(
    client: vertexai.Client,
    runtime_name: str,
    *,
    user_id: str,
    session_id: str,
    message: str | dict[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], float]:
    started = time.perf_counter()
    raw_events = []
    summaries = []
    for response in client.agent_engines._stream_query(
        name=runtime_name,
        config={
            "class_method": "stream_query",
            "input": {
                "user_id": user_id,
                "session_id": session_id,
                "message": message,
            },
        },
    ):
        body = getattr(response, "body", None)
        if body:
            raw_events.append(json.loads(body))
        summaries.append(summarize_event(response))
    return raw_events, summaries, round((time.perf_counter() - started) * 1000, 1)


def _function_calls(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    calls = []
    for event in events:
        for part in ((event.get("content") or {}).get("parts") or []):
            call = part.get("functionCall") or part.get("function_call")
            if call:
                calls.append(call)
    return calls


def _tool_responses(
    summaries: list[dict[str, Any]], tool_suffix: str
) -> list[dict[str, Any]]:
    return [
        part
        for event in summaries
        for part in event.get("parts", [])
        if part.get("type") == "function_response"
        and str(part.get("name", "")).endswith(tool_suffix)
    ]


def _new_session(
    client: vertexai.Client, runtime_name: str, user_id: str
) -> str:
    operation = client.agent_engines.sessions.create(name=runtime_name, user_id=user_id)
    if not operation.done or operation.error or not operation.response:
        raise RuntimeError("Managed session creation did not complete successfully.")
    return operation.response.name.rsplit("/", 1)[-1]


def _confirmation_message(call: dict[str, Any], confirmed: bool) -> dict[str, Any]:
    return {
        "role": "user",
        "parts": [
            {
                "functionResponse": {
                    "id": call["id"],
                    "name": "adk_request_confirmation",
                    "response": {"confirmed": confirmed},
                }
            }
        ],
    }


def _exercise(
    client: vertexai.Client,
    runtime_name: str,
    *,
    user_id: str,
    confirmed: bool,
    case: str,
) -> dict[str, Any]:
    session_id = _new_session(client, runtime_name, user_id)
    raw_initial, initial, initial_ms = _raw_stream(
        client,
        runtime_name,
        user_id=user_id,
        session_id=session_id,
        message=_prompt(case),
    )
    confirmations = [
        call
        for call in _function_calls(raw_initial)
        if call.get("name") == "adk_request_confirmation"
    ]
    if len(confirmations) != 1:
        return {
            "passed": False,
            "confirmation_requested": False,
            "initial_ms": initial_ms,
            "initial_events": initial,
            "resume_events": [],
        }

    _, resumed, resume_ms = _raw_stream(
        client,
        runtime_name,
        user_id=user_id,
        session_id=session_id,
        message=_confirmation_message(confirmations[0], confirmed),
    )
    ticket_responses = _tool_responses(resumed, "create_ticket")
    successful_write = any(not response.get("is_error") for response in ticket_responses)
    return {
        "passed": successful_write if confirmed else not successful_write,
        "confirmation_requested": True,
        "confirmed": confirmed,
        "write_succeeded": successful_write,
        "initial_ms": initial_ms,
        "resume_ms": resume_ms,
        "initial_events": initial,
        "resume_events": resumed,
    }


def main() -> int:
    client = vertexai.Client(
        project=PROJECT_ID,
        location=REGION,
        http_options=types.HttpOptions(api_version="v1beta1"),
    )
    matches = [
        engine
        for engine in client.agent_engines.list()
        if engine.api_resource.display_name == DISPLAY_NAME
    ]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one deployed {DISPLAY_NAME!r}, found {len(matches)}")
    runtime_name = matches[0].api_resource.name

    rejection = _exercise(
        client,
        runtime_name,
        user_id="remote-e2e-ticket-rejection",
        confirmed=False,
        case="rejection",
    )
    rejection["id"] = "REMOTE-MCP-SI-REJECT-001"

    results = [rejection]
    if EXECUTE_WRITE:
        confirmation = _exercise(
            client,
            runtime_name,
            user_id="remote-e2e-ticket-confirmation",
            confirmed=True,
            case="confirmation",
        )
        confirmation["id"] = "REMOTE-MCP-SI-CONFIRM-001"
        results.append(confirmation)

    payload = {
        "schema_version": "1.0",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "project_id": PROJECT_ID,
        "runtime": runtime_name,
        "data_handling": (
            "No token, employee identifier, ticket identifier, arguments, or response body "
            "is persisted."
        ),
        "write_execution_enabled": EXECUTE_WRITE,
        "summary": {
            "passed": sum(bool(result["passed"]) for result in results),
            "total": len(results),
        },
        "results": results,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload["summary"], indent=2))
    return 0 if payload["summary"]["passed"] == payload["summary"]["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
