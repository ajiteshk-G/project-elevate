#!/usr/bin/env python3
import json
from pathlib import Path

def main():
    src_path = Path("evaluation/golden_mas_eval.evalset.json")
    dst_path = Path("tests/eval/datasets/evalset.json")
    
    if not src_path.exists():
        print(f"Error: source file {src_path} does not exist.")
        return 1
        
    data = json.loads(src_path.read_text())
    cases = data.get("eval_cases", [])
    
    new_cases = []
    for c in cases:
        eval_id = c.get("eval_id")
        conv = c.get("conversation", [])
        if not conv:
            continue
            
        user_content = conv[0].get("user_content")
        if not user_content:
            continue
            
        new_case = {
            "eval_case_id": eval_id,
            "prompt": user_content
        }
        new_cases.append(new_case)
        
    new_data = {
        "eval_cases": new_cases
    }
    
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    dst_path.write_text(json.dumps(new_data, indent=2) + "\n")
    print(f"Successfully converted {len(new_cases)} cases and wrote to {dst_path}")
    return 0

if __name__ == "__main__":
    main()
