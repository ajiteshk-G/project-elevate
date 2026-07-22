#!/usr/bin/env python3
import json
from pathlib import Path

def main():
    results_path = Path("/usr/local/google/home/nishantmk/project-elevate/artifacts/grade_results/results_20260722_140302.json")
    traces_path = Path("/usr/local/google/home/nishantmk/project-elevate/artifacts/traces/traces_new.json")
    
    if not results_path.exists():
        print("Results file not found!")
        return
    if not traces_path.exists():
        print("Traces file not found!")
        return
        
    results_data = json.loads(results_path.read_text())
    traces_data = json.loads(traces_path.read_text())
    
    cases = traces_data.get("eval_cases", [])
    case_mapping = {}
    for i, case in enumerate(cases):
        # Find prompt
        prompt = ""
        agent_data = case.get("agent_data", {})
        turns = agent_data.get("turns", [])
        if turns:
            events = turns[0].get("events", [])
            for ev in events:
                if ev.get("author") == "user":
                    parts = ev.get("content", {}).get("parts", [])
                    if parts:
                        prompt = parts[0].get("text", "")
                        break
        case_mapping[i] = {
            "id": case.get("eval_case_id", f"case_{i}"),
            "prompt": prompt
        }
        
    print("=== SUMMARY OF EVALUATION RUN ===")
    print(f"Total Cases: {len(results_data.get('eval_case_results', []))}")
    print()
    
    print("| Case Index | Case ID | mas_task_success | mas_trajectory_quality | safety_v1 |")
    print("|---|---|---|---|---|")
    for case_res in results_data.get("eval_case_results", []):
        idx = case_res.get("eval_case_index")
        case_info = case_mapping.get(idx, {"id": f"case_{idx}", "prompt": "Unknown"})
        
        metrics = case_res.get("response_candidate_results", [{}])[0].get("metric_results", {})
        
        task_success = metrics.get("mas_task_success", {})
        traj_quality = metrics.get("mas_trajectory_quality", {})
        safety = metrics.get("safety_v1", {})
        
        ts_score = task_success.get("score")
        tj_score = traj_quality.get("score")
        sf_score = safety.get("score")
        
        print(f"| {idx} | {case_info['id']} | {ts_score} | {tj_score} | {sf_score} |")
        
    print("\n=== DETAILED FAILURE ANALYSIS (Score < 5) ===")
    for case_res in results_data.get("eval_case_results", []):
        idx = case_res.get("eval_case_index")
        case_info = case_mapping.get(idx, {"id": f"case_{idx}", "prompt": "Unknown"})
        
        metrics = case_res.get("response_candidate_results", [{}])[0].get("metric_results", {})
        
        task_success = metrics.get("mas_task_success", {})
        traj_quality = metrics.get("mas_trajectory_quality", {})
        
        ts_score = task_success.get("score")
        tj_score = traj_quality.get("score")
        
        if (ts_score is not None and ts_score < 5.0) or (tj_score is not None and tj_score < 5.0):
            print(f"\n❌ Case {idx}: {case_info['id']}")
            print(f"   Prompt: {case_info['prompt']}")
            if ts_score is not None and ts_score < 5.0:
                print(f"   - mas_task_success Score: {ts_score}")
                print(f"     Explanation: {task_success.get('explanation')}")
            if tj_score is not None and tj_score < 5.0:
                print(f"   - mas_trajectory_quality Score: {tj_score}")
                print(f"     Explanation: {traj_quality.get('explanation')}")
            print("-" * 80)

if __name__ == "__main__":
    main()
