import re
import sys

def validate_mermaid(file_path):
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Find all mermaid blocks
    mermaid_blocks = re.findall(r"```mermaid\n(.*?)\n```", content, re.DOTALL)
    if not mermaid_blocks:
        print("ERROR: No mermaid blocks found!")
        return False

    print(f"Found {len(mermaid_blocks)} mermaid blocks.")
    
    all_valid = True
    for idx, block in enumerate(mermaid_blocks, 1):
        print(f"\nValidating Diagram {idx}...")
        lines = block.strip().split("\n")
        if not lines:
            print("  ERROR: Diagram is empty.")
            all_valid = False
            continue

        first_line = lines[0].strip()
        if not first_line.startswith("sequenceDiagram"):
            print(f"  Skipping non-sequence diagram (starts with: '{first_line}')")
            continue

        declared_participants = set()
        diagram_valid = True

        for line_num, line in enumerate(lines[1:], 2):
            line = line.strip()
            if not line or line.startswith("%%"):
                continue
            if line == "autonumber":
                continue
            if line.startswith("alt ") or line.startswith("else ") or line.startswith("opt ") or line.startswith("loop ") or line == "end":
                continue

            # Check participant or actor declarations
            dec_match = re.match(r"^(participant|actor)\s+([a-zA-Z0-9_]+)(\s+as\s+\"([^\"]+)\")?$", line)
            if dec_match:
                p_type, p_id, _, p_label = dec_match.groups()
                declared_participants.add(p_id)
                print(f"  Declared {p_type}: {p_id} ({p_label if p_label else p_id})")
                continue

            # Check notes
            note_over_match = re.match(r"^Note\s+over\s+([a-zA-Z0-9_,\s]+):\s*(.*)$", line)
            if note_over_match:
                p_ids_str, note_text = note_over_match.groups()
                p_ids = [pid.strip() for pid in p_ids_str.split(",")]
                for pid in p_ids:
                    if pid not in declared_participants:
                        print(f"  WARNING (Line {line_num}): Participant '{pid}' used in Note over without declaration.")
                continue

            note_lr_match = re.match(r"^Note\s+(left\s+of|right\s+of)\s+([a-zA-Z0-9_]+):\s*(.*)$", line)
            if note_lr_match:
                _, pid, note_text = note_lr_match.groups()
                if pid not in declared_participants:
                    print(f"  WARNING (Line {line_num}): Participant '{pid}' used in Note left/right of without declaration.")
                continue

            # Check interactions/messages
            msg_match = re.match(r"^([a-zA-Z0-9_]+)\s*(\-\-\>\>|\-\>\>|\-\-\>|\-\>|\-x|\-\-x)\s*([a-zA-Z0-9_]+)\s*:\s*(.*)$", line)
            if msg_match:
                sender, arrow, receiver, msg_text = msg_match.groups()
                if sender not in declared_participants:
                    print(f"  ERROR (Line {line_num}): Sender '{sender}' is not declared.")
                    diagram_valid = False
                if receiver not in declared_participants:
                    print(f"  ERROR (Line {line_num}): Receiver '{receiver}' is not declared.")
                    diagram_valid = False
                continue

            # If it doesn't match anything
            print(f"  ERROR (Line {line_num}): Syntactically invalid line: '{line}'")
            diagram_valid = False

        if diagram_valid:
            print(f"  Diagram {idx}: VALID")
        else:
            print(f"  Diagram {idx}: INVALID")
            all_valid = False

    return all_valid

if __name__ == "__main__":
    file_path = "/Users/ajiteshk/Desktop/project-elevate/HR_Agentic_Solution_Design_Document.md"
    success = validate_mermaid(file_path)
    if not success:
        sys.exit(1)
    else:
        sys.exit(0)
