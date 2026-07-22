#!/usr/bin/env python3
import json
from pathlib import Path

def main():
    results_path = Path("/usr/local/google/home/nishantmk/project-elevate/artifacts/grade_results/results_20260722_091159.json")
    traces_path = Path("/usr/local/google/home/nishantmk/project-elevate/artifacts/traces/traces_20260722_090311.json")
    
    if not results_path.exists() or not traces_path.exists():
        print("Required files not found!")
        return
        
    results_data = json.loads(results_path.read_text())
    traces_data = json.loads(traces_path.read_text())
    
    # Map index to trace case ID and actual prompt
    cases = traces_data.get("eval_cases", [])
    print(f"Traces count: {len(cases)}")
    print(f"Results count: {len(results_data.get('eval_case_results', []))}")
    
    for i, case_res in enumerate(results_data.get("eval_case_results", [])):
        idx = case_res.get("eval_case_index")
        trace_case = cases[idx] if idx < len(cases) else {}
        case_id = trace_case.get("eval_case_id", "unknown")
        
        # Extract prompt from trace_case
        prompt = ""
        agent_data = trace_case.get("agent_data", {})
        turns = agent_data.get("turns", [])
        if turns:
            events = turns[0].get("events", [])
            for ev in events:
                if ev.get("author") == "user":
                    parts = ev.get("content", {}).get("parts", [])
                    if parts:
                        prompt = parts[0].get("text", "")
                        break
                        
        print(f"Index {idx} -> ID: {case_id}")
        print(f"  Prompt: {prompt}")
        print("-" * 50)

if __name__ == "__main__":
    main()
