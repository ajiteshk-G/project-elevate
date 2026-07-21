from datetime import date, timedelta
from types import SimpleNamespace

import pytest

from hr_agent.guardrails import _find_employee_id
from hr_agent.guardrails import enforce_tool_policy
from hr_agent.guardrails import validate_tool_call


EMPLOYEE = "E-1001"


def test_unknown_tool_is_default_denied() -> None:
    assert validate_tool_call("admin_reset", {}, expected_employee_id=EMPLOYEE)


def test_other_employee_is_denied() -> None:
    denial = validate_tool_call(
        "get_employee_balances",
        {"employee_id": "E-9999"},
        expected_employee_id=EMPLOYEE,
    )
    assert denial and "authenticated session" in denial


def test_identity_mapping_is_required() -> None:
    denial = validate_tool_call(
        "create_ticket",
        {
            "requested_by": EMPLOYEE,
            "category": "IT",
            "short_description": "Laptop issue",
            "priority": "3 - Moderate",
        },
        expected_employee_id=None,
    )
    assert denial and "mapping" in denial


def test_leave_of_absence_is_not_substituted() -> None:
    future = date.today() + timedelta(days=10)
    denial = validate_tool_call(
        "request_time_off",
        {
            "employee_id": EMPLOYEE,
            "start_date": future.isoformat(),
            "end_date": future.isoformat(),
            "leave_type": "Leave of Absence",
            "days": 1,
        },
        expected_employee_id=EMPLOYEE,
    )
    assert denial and "Vacation and Sick" in denial


@pytest.mark.parametrize(
    "priority,description,allowed",
    [
        ("1 - Critical", "Email is slow", False),
        ("1 - Critical", "Production system outage", True),
        ("3 - Moderate", "Email is slow", True),
        ("P1", "Production outage", False),
    ],
)
def test_ticket_priority_rules(
    priority: str, description: str, allowed: bool
) -> None:
    denial = validate_tool_call(
        "create_ticket",
        {
            "requested_by": EMPLOYEE,
            "category": "IT",
            "short_description": description,
            "priority": priority,
        },
        expected_employee_id=EMPLOYEE,
    )
    assert (denial is None) is allowed


def test_valid_future_vacation_is_allowed() -> None:
    start = date.today() + timedelta(days=20)
    end = start + timedelta(days=1)
    assert (
        validate_tool_call(
            "request_time_off",
            {
                "employee_id": EMPLOYEE,
                "start_date": start.isoformat(),
                "end_date": end.isoformat(),
                "leave_type": "Vacation",
                "days": 2,
            },
            expected_employee_id=EMPLOYEE,
        )
        is None
    )


def test_closing_ticket_requires_resolution_notes() -> None:
    denial = validate_tool_call(
        "update_ticket_status",
        {"ticket_id": "INC001", "status": "Closed", "resolution_notes": ""},
        expected_employee_id=EMPLOYEE,
    )
    assert denial and "resolution notes" in denial


def test_identity_is_extracted_from_structured_mcp_content() -> None:
    response = {
        "content": [{"type": "text", "text": '{"employee_id":"E-1001"}'}]
    }
    assert _find_employee_id(response) == EMPLOYEE


def test_identity_is_extracted_from_vendor_result_shape() -> None:
    response = {
        "structuredContent": {"result": EMPLOYEE},
        "isError": False,
    }
    assert _find_employee_id(response) == EMPLOYEE


def test_identity_is_not_extracted_from_error_or_unstructured_text() -> None:
    assert _find_employee_id({"isError": True, "employee_id": EMPLOYEE}) is None
    assert _find_employee_id({"content": [{"text": EMPLOYEE}]}) is None


@pytest.mark.asyncio
async def test_ticket_create_requires_a_fresh_owned_ticket_list() -> None:
    tool = SimpleNamespace(name="serviceimmediately_create_ticket")
    context = SimpleNamespace(state={"user:employee_id": EMPLOYEE})
    denial = await enforce_tool_policy(
        tool,
        {
            "requested_by": EMPLOYEE,
            "category": "IT",
            "short_description": "Laptop issue",
            "priority": "3 - Moderate",
        },
        context,
    )
    assert denial and "listed immediately" in denial["error"]


@pytest.mark.asyncio
async def test_ticket_create_allowed_after_owned_ticket_list() -> None:
    tool = SimpleNamespace(name="serviceimmediately_create_ticket")
    context = SimpleNamespace(
        state={
            "user:employee_id": EMPLOYEE,
            "user:service_tickets_listed": True,
        }
    )
    denial = await enforce_tool_policy(
        tool,
        {
            "requested_by": EMPLOYEE,
            "category": "IT",
            "short_description": "Laptop issue",
            "priority": "3 - Moderate",
        },
        context,
    )
    assert denial is None
