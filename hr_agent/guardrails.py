"""Deterministic policy checks at the MCP tool boundary."""

from __future__ import annotations

from datetime import date
import os
import re
from typing import Any

from google.adk.agents.callback_context import CallbackContext
from google.adk.agents.context import Context
from google.adk.tools.base_tool import BaseTool


WRITE_TOOLS = {
    "request_time_off",
    "update_personal_info",
    "create_ticket",
    "add_ticket_comment",
    "update_ticket_status",
}
PRIORITIES = {
    "1 - Critical",
    "2 - High",
    "3 - Moderate",
    "4 - Low",
    "5 - Planning",
}
CRITICAL_KEYWORDS = ("outage", "crash", "down", "downtime", "unavailable")
PHONE_PATTERN = re.compile(r"^\+?[\d\s\-()]{7,20}$")


def canonical_tool_name(name: str) -> str:
    """Remove the namespace added to MCP tools without weakening allowlists."""

    for prefix in ("workweek_", "serviceimmediately_"):
        if name.startswith(prefix):
            return name.removeprefix(prefix)
    return name


def _find_employee_id(value: Any) -> str | None:
    """Extract an identity only from the token-bound identity tool response."""

    if isinstance(value, dict):
        if value.get("isError") or value.get("error"):
            return None
        for key in (
            "employee_id",
            "employeeId",
            "current_employee_id",
            # The vendor's authenticated identity tool returns
            # structuredContent.result as the opaque employee identifier.
            "result",
        ):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return candidate.strip()
        for child in value.values():
            found = _find_employee_id(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_employee_id(child)
            if found:
                return found
    elif isinstance(value, str):
        # MCP text content commonly wraps the structured result as JSON.
        import json

        try:
            return _find_employee_id(json.loads(value))
        except json.JSONDecodeError:
            return None
    return None


def validate_tool_call(
    tool_name: str,
    args: dict[str, Any],
    *,
    expected_employee_id: str | None,
) -> str | None:
    """Return a denial reason, or ``None`` when a tool call is allowed."""

    tool_name = canonical_tool_name(tool_name)
    if tool_name not in {
        "get_current_employee_id",
        "get_employee_balances",
        "request_time_off",
        "update_personal_info",
        "list_tickets",
        "create_ticket",
        "add_ticket_comment",
        "update_ticket_status",
    }:
        return "The capability is not in the approved MCP catalog."

    identity_fields = ("employee_id", "requested_by", "author")
    supplied_identities = [str(args[field]) for field in identity_fields if args.get(field)]
    if supplied_identities:
        if not expected_employee_id:
            return "The enterprise-user to employee mapping is not configured."
        if any(value != expected_employee_id for value in supplied_identities):
            return "The requested employee does not match the authenticated session."

    if tool_name == "request_time_off":
        if args.get("leave_type") not in {"Vacation", "Sick"}:
            return "Only Vacation and Sick leave are supported by the approved contract."
        try:
            start = date.fromisoformat(str(args["start_date"]))
            end = date.fromisoformat(str(args["end_date"]))
            days = float(args["days"])
        except (KeyError, TypeError, ValueError):
            return "Leave dates and days must use the approved schema."
        if start < date.today() or start > end or days <= 0:
            return "Leave dates or days violate the approved chronology rules."

    if tool_name == "update_personal_info":
        address = str(args.get("address", ""))
        phone = str(args.get("phone", ""))
        if len(address.strip()) < 5 or not PHONE_PATTERN.fullmatch(phone):
            return "The address or phone does not satisfy the approved WorkWeek format."

    if tool_name == "create_ticket":
        priority = str(args.get("priority", ""))
        description = str(args.get("short_description", "")).lower()
        if priority not in PRIORITIES:
            return "The ticket priority is not one of the approved exact values."
        if priority == "1 - Critical" and not any(
            keyword in description for keyword in CRITICAL_KEYWORDS
        ):
            return "Critical priority requires an active outage, crash, or downtime."

    if tool_name == "update_ticket_status":
        status = str(args.get("status", ""))
        if status not in {"In Progress", "Resolved", "Closed"}:
            return "The requested ticket status is not approved."
        if status == "Closed" and not str(args.get("resolution_notes", "")).strip():
            return "Closing a ticket requires resolution notes and a verified transition."

    return None


async def initialize_session_identity(callback_context: CallbackContext) -> None:
    """Seed only an operator-configured trusted identity mapping."""

    expected = os.environ.get("EXPECTED_EMPLOYEE_ID", "").strip()
    if expected and not callback_context.state.get("user:employee_id"):
        callback_context.state["user:employee_id"] = expected


async def enforce_tool_policy(
    tool: BaseTool,
    args: dict[str, Any],
    tool_context: Context,
) -> dict[str, Any] | None:
    """ADK callback that blocks calls before the MCP request is dispatched."""

    tool_name = canonical_tool_name(tool.name)
    # transfer_to_agent is the ADK framework hand-off control, not an MCP
    # capability. The catalog check below is scoped to vendor MCP tools, so let
    # a peer/parent transfer through; without this it is denied as "not in the
    # approved MCP catalog" and multi-part requests lose their second specialist.
    if tool_name == "transfer_to_agent":
        return None
    expected = tool_context.state.get("user:employee_id")
    if tool_name == "create_ticket" and not tool_context.state.get(
        "user:service_tickets_listed"
    ):
        return {
            "status": "denied",
            "error": "Owned tickets must be listed immediately before ticket creation.",
        }
    denial = validate_tool_call(
        tool_name,
        args,
        expected_employee_id=str(expected) if expected else None,
    )
    if denial:
        return {"status": "denied", "error": denial}
    return None


async def capture_session_identity(
    tool: BaseTool,
    args: dict[str, Any],
    tool_context: Context,
    tool_response: dict[str, Any],
) -> None:
    """Bind the vendor-resolved employee ID to this managed agent session."""

    del args
    tool_name = canonical_tool_name(tool.name)
    # transfer_to_agent is the ADK hand-off control and returns None, so it has
    # no MCP response to inspect. Skip it before the .get() calls below.
    if tool_name == "transfer_to_agent" or tool_response is None:
        return
    if tool_name == "get_current_employee_id":
        employee_id = _find_employee_id(tool_response)
        if employee_id:
            tool_context.state["user:employee_id"] = employee_id
        return

    response_error = bool(tool_response.get("error") or tool_response.get("isError"))
    if tool_name == "list_tickets" and not response_error:
        tool_context.state["user:service_tickets_listed"] = True
        return

    if tool_name == "create_ticket":
        error = str(tool_response.get("error", "")).lower()
        if "requires confirmation" not in error:
            # Success, rejection, or a terminal error all consume the freshness
            # check. A later create must obtain current owned-ticket context.
            tool_context.state["user:service_tickets_listed"] = False
