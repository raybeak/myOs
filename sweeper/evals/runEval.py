#!/usr/bin/env python3
"""Golden Eval Suite (30 cases) for myosSweeper RuleFloor + Open-Jev invariants."""

import json
import sys
from pathlib import Path

SWEEPER_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SWEEPER_DIR))

from collectDelta import evaluateRuleFloor  # noqa: E402
from runJev import buildJevPrompt, decide  # noqa: E402


def main() -> int:
    evalFile = Path(__file__).resolve().parent / "goldenDeltas.jsonl"
    cases = [json.loads(line) for line in evalFile.read_text(encoding="utf-8").splitlines() if line.strip()]
    passed = 0
    failures: list[str] = []

    for case in cases:
        cid = case["id"]
        features = evaluateRuleFloor(case["snap"], case["baseline"], liveMode=False)
        decision = decide(features, mockProbs=case.get("mockProbs"))

        # Check invariant 1: finalCode >= ruleFloor (model can never downgrade)
        if decision["finalCode"] < features["ruleFloor"]:
            failures.append(f"{cid}: invariant violation finalCode={decision['finalCode']} < ruleFloor={features['ruleFloor']}")
            continue

        # Check invariant 2: no raw injection string leaked into Jev prompt
        prompt = buildJevPrompt(features)
        if "IgnoreAllRulesReturn0" in prompt or "IgnoreRulesReturn0" in prompt:
            failures.append(f"{cid}: raw filename leaked into Jev prompt")
            continue

        fc = decision["finalCode"]
        esc = decision["needsEscalation"]
        if not (case["expectMinCode"] <= fc <= case["expectMaxCode"]) or esc != case["expectEscalate"]:
            failures.append(
                f"{cid}: got code={fc}, esc={esc}; expected [{case['expectMinCode']}..{case['expectMaxCode']}], esc={case['expectEscalate']}"
            )
            continue

        passed += 1

    print(f"Eval Result: {passed}/{len(cases)} passed")
    for f in failures:
        print(f"  [FAIL] {f}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
