#!/usr/bin/env python3
"""Run a small concurrent, read-only time-to-first-event benchmark."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import statistics
from typing import Any

from google.genai import types
import vertexai

from scripts.run_remote_e2e import DISPLAY_NAME, invoke


PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
REGION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
OUTPUT = Path(os.environ.get("PERF_OUTPUT", "artifacts/remote-performance.json"))
CONCURRENCY = int(os.environ.get("PERF_CONCURRENCY", "3"))

CASES = [
    (
        "policy",
        "What are the annual vacation accrual tiers for 1-6, 7-10, and 11+ years of service?",
    ),
    ("guardrail", "Can you submit a Leave of Absence through WorkWeek?"),
] * 3


def _client() -> vertexai.Client:
    return vertexai.Client(
        project=PROJECT_ID,
        location=REGION,
        http_options=types.HttpOptions(api_version="v1beta1"),
    )


def _percentile(values: list[float], percentile: int) -> float:
    return round(statistics.quantiles(values, n=100, method="inclusive")[percentile - 1], 1)


def _run(runtime_name: str, index: int, case: tuple[str, str]) -> dict[str, Any]:
    kind, prompt = case
    result = invoke(
        _client(),
        runtime_name,
        prompt,
        f"remote-perf-{kind}-{index}",
    )
    return {
        "id": f"PERF-{index + 1:03d}",
        "kind": kind,
        "first_event_ms": result["first_event_ms"],
        "total_ms": result["total_ms"],
        "received_text": bool(result["answer"]),
        "error_type": result["error"].split(":", 1)[0] if result["error"] else None,
        "passed": result["first_event_ms"] is not None
        and result["first_event_ms"] <= 10_000
        and not result["error"],
    }


def main() -> int:
    matches = [
        engine
        for engine in _client().agent_engines.list()
        if engine.api_resource.display_name == DISPLAY_NAME
    ]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one deployed {DISPLAY_NAME!r}, found {len(matches)}")
    runtime_name = matches[0].api_resource.name

    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = {
            executor.submit(_run, runtime_name, index, case): index
            for index, case in enumerate(CASES)
        }
        for future in as_completed(futures):
            results.append(future.result())
    results.sort(key=lambda result: result["id"])

    first_values = [result["first_event_ms"] for result in results if result["first_event_ms"]]
    total_values = [result["total_ms"] for result in results]
    payload = {
        "schema_version": "1.0",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "project_id": PROJECT_ID,
        "runtime": runtime_name,
        "concurrency": CONCURRENCY,
        "sample_count": len(results),
        "summary": {
            "passed": sum(bool(result["passed"]) for result in results),
            "total": len(results),
            "first_event_ms_p50": round(statistics.median(first_values), 1),
            "first_event_ms_p95": _percentile(first_values, 95),
            "first_event_ms_max": max(first_values),
            "total_ms_p50": round(statistics.median(total_values), 1),
            "total_ms_p95": _percentile(total_values, 95),
            "total_ms_max": max(total_values),
        },
        "results": results,
        "limitations": [
            "Six read-only samples at concurrency three are engineering smoke evidence, not a production load test.",
            "This measures time to the first streamed event, not isolated Model Armor overhead or monthly availability.",
        ],
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload["summary"], indent=2))
    return 0 if payload["summary"]["passed"] == payload["summary"]["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
