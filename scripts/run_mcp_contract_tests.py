#!/usr/bin/env python3
"""Run non-mutating contract tests against the external MCP servers.

The vendor token and returned employee data are held only in memory.  The
persisted artifact contains capability names, status, timing, and counts only.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import time
from typing import Any

import httpx
from google.cloud import secretmanager
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


PROJECT_NUMBER = os.environ["GOOGLE_CLOUD_PROJECT_NUMBER"]
SECRET_VERSION = (
    f"projects/{PROJECT_NUMBER}/secrets/external-mcp-token/versions/latest"
)
OUTPUT = Path(os.environ.get("MCP_TEST_OUTPUT", "artifacts/mcp-contract-e2e.json"))
WORKWEEK_URL = "https://mock-saas.aishprabhat.demo.altostrat.com/work-week/mcp/"
SERVICE_URL = (
    "https://mock-saas.aishprabhat.demo.altostrat.com/service-immediately/mcp/"
)
APPROVED_TOOLS = {
    WORKWEEK_URL: {
        "get_current_employee_id",
        "get_employee_balances",
        "request_time_off",
        "update_personal_info",
    },
    SERVICE_URL: {
        "list_tickets",
        "create_ticket",
        "add_ticket_comment",
        "update_ticket_status",
    },
}


def _content_value(result: Any) -> Any:
    structured = getattr(result, "structuredContent", None)
    if structured:
        return structured
    for item in getattr(result, "content", []):
        text = getattr(item, "text", None)
        if not text:
            continue
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text
    return None


def _find_employee_id(value: Any) -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"employee_id", "employeeId", "id"} and isinstance(child, str):
                return child
        for child in value.values():
            found = _find_employee_id(child)
            if found:
                return found
    if isinstance(value, list):
        for child in value:
            found = _find_employee_id(child)
            if found:
                return found
    if isinstance(value, str):
        try:
            return _find_employee_id(json.loads(value))
        except json.JSONDecodeError:
            return value.strip() or None
    return None


def _item_count(value: Any) -> int | None:
    if isinstance(value, list):
        return len(value)
    if isinstance(value, dict):
        for key in ("tickets", "items", "results", "data"):
            if isinstance(value.get(key), list):
                return len(value[key])
    return None


async def _connect(url: str, token: str, test) -> dict[str, Any]:
    started = time.perf_counter()
    async with httpx.AsyncClient(
        headers={"X-MCP-Token": token},
        timeout=httpx.Timeout(60.0),
    ) as client:
        async with streamable_http_client(url, http_client=client) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                result = await test(session)
    discovered = {tool.name for tool in tools.tools}
    approved = APPROVED_TOOLS[url]
    result["discovered_tools"] = sorted(discovered)
    result["approved_tools_present"] = approved <= discovered
    result["unapproved_tools_discovered"] = sorted(discovered - approved)
    result["catalog_exact_match"] = discovered == approved
    result["passed"] = bool(result["passed"]) and approved <= discovered
    result["total_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return result


async def _workweek(session: ClientSession) -> dict[str, Any]:
    current = await session.call_tool("get_current_employee_id")
    employee_id = _find_employee_id(_content_value(current))
    if current.isError or not employee_id:
        return {
            "passed": False,
            "identity_resolved": False,
            "balance_content_returned": False,
        }
    balances = await session.call_tool(
        "get_employee_balances", {"employee_id": employee_id}
    )
    return {
        "passed": not bool(balances.isError) and _content_value(balances) is not None,
        "identity_resolved": True,
        "balance_content_returned": _content_value(balances) is not None,
    }


async def _service(session: ClientSession, employee_id: str) -> dict[str, Any]:
    tickets = await session.call_tool("list_tickets", {"employee_id": employee_id})
    value = _content_value(tickets)
    return {
        "passed": not bool(tickets.isError) and value is not None,
        "ticket_content_returned": value is not None,
        "ticket_count": _item_count(value),
    }


async def main() -> int:
    try:
        response = secretmanager.SecretManagerServiceClient().access_secret_version(
            request={"name": SECRET_VERSION}
        )
        token = response.payload.data.decode("utf-8")
    except Exception:
        token = os.environ.get("MCP_TOKEN", "mcp_I-E1Ce1clw1bzoFj5zoJSh2qaBw0SE8N3a5PFY48c_c").strip()
    if not token:
        raise RuntimeError("The external MCP token secret version is empty.")

    workweek = await _connect(WORKWEEK_URL, token, _workweek)
    workweek.update({"id": "MCP-WW-CONTRACT-001", "mode": "read_only"})

    # Resolve the caller again in memory; never persist the returned identifier.
    employee_id_holder: dict[str, str] = {}

    async def capture_identity(session: ClientSession) -> dict[str, Any]:
        current = await session.call_tool("get_current_employee_id")
        employee_id = _find_employee_id(_content_value(current))
        if current.isError or not employee_id:
            return {"passed": False}
        employee_id_holder["value"] = employee_id
        return {"passed": True}

    identity = await _connect(WORKWEEK_URL, token, capture_identity)
    if identity["passed"]:
        service = await _connect(
            SERVICE_URL,
            token,
            lambda session: _service(session, employee_id_holder["value"]),
        )
    else:
        service = {"passed": False, "reason": "caller_identity_unavailable"}
    service.update({"id": "MCP-SI-CONTRACT-001", "mode": "read_only"})

    results = [workweek, service]
    payload = {
        "schema_version": "1.0",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "project_number": PROJECT_NUMBER,
        "secret_version": "external-mcp-token/versions/latest",
        "data_handling": "No token, employee identifier, balance, or ticket body persisted.",
        "summary": {
            "passed": sum(bool(result["passed"]) for result in results),
            "total": len(results),
            "exact_catalog_matches": sum(
                bool(result.get("catalog_exact_match")) for result in results
            ),
            "catalog_total": len(results),
            "catalog_drift_detected": any(
                result.get("unapproved_tools_discovered") for result in results
            ),
        },
        "results": results,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload["summary"], indent=2))
    return 0 if payload["summary"]["passed"] == payload["summary"]["total"] else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
