#!/usr/bin/env python3
"""Stage 2 Local Open-Jev decision runner (1-pass logprob classifier)."""

import argparse
import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path
from typing import Any

CODE_LABELS = {
    "0": "0_CLEAN",
    "1": "1_BENIGN_MAINT",
    "2": "2_SUSPICIOUS",
    "3": "3_CRITICAL_PRIV_ESC",
    "4": "4_CRITICAL_NET_TAMPER",
}


def softmax(logits: dict[str, float]) -> dict[str, float]:
    """Convert raw token logprobs/logits into calibrated probabilities."""
    if not logits:
        return {}
    maxVal = max(logits.values())
    exps = {k: math.exp(v - maxVal) for k, v in logits.items()}
    total = sum(exps.values())
    return {k: (v / total) for k, v in exps.items()} if total > 0 else {}


def buildJevPrompt(features: dict[str, Any]) -> str:
    """Build deterministic System-1 prompt from sanitized features only."""
    return (
        "<|im_start|>system\n"
        "You are a Linux security classifier. Given sanitized telemetry JSON, "
        "reply with ONLY a single digit 0, 1, 2, 3, or 4.\n"
        "0=CLEAN, 1=BENIGN_MAINT, 2=SUSPICIOUS, 3=CRITICAL_PRIV_ESC, 4=CRITICAL_NET_TAMPER.\n"
        "<|im_end|>\n"
        "<|im_start|>user\n"
        f"{json.dumps(features, sort_keys=True)}\n"
        "<|im_end|>\n"
        "<|im_start|>assistant\n"
    )


def verifySha256(path: Path, expected: str) -> bool:
    """Verify binary or model SHA-256 unless placeholder pin is used."""
    if not expected or expected.startswith("PIN_"):
        return True
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest() == expected


def runLocalLlama(llamaBin: Path, modelPath: Path, prompt: str) -> tuple[int, float]:
    """Invoke llama-cli for single-token classification; return (code, pMax)."""
    cmd = [
        str(llamaBin),
        "-m", str(modelPath),
        "-p", prompt,
        "-n", "1",
        "--temp", "0",
        "--no-display-prompt",
        "--log-disable",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    raw = res.stdout.strip()
    digit = next((ch for ch in raw if ch in CODE_LABELS), "2")
    # Without --logprobs JSON support in older llama-cli, treat exact digit hit as 0.75 fallback
    return int(digit), 0.75


def decide(features: dict[str, Any], llamaBin: Path | None = None, modelPath: Path | None = None, mockCode: int | None = None, mockProbs: dict[str, float] | None = None) -> dict[str, Any]:
    """Execute Stage 2 decision while enforcing finalCode = max(ruleFloor, jevCode)."""
    ruleFloor = int(features.get("ruleFloor", 0))
    if ruleFloor == 0:
        return {
            "ruleFloor": 0,
            "jevCode": 0,
            "finalCode": 0,
            "label": CODE_LABELS["0"],
            "pMax": 1.0,
            "needsEscalation": False,
            "ranModel": False,
        }

    if ruleFloor >= 2:
        return {
            "ruleFloor": ruleFloor,
            "jevCode": ruleFloor,
            "finalCode": ruleFloor,
            "label": CODE_LABELS.get(str(ruleFloor), "2_SUSPICIOUS"),
            "pMax": 1.0,
            "needsEscalation": True,
            "ranModel": False,
        }

    # ruleFloor == 1 (Ambiguous): invoke Local Open-Jev
    if mockProbs is not None:
        probs = softmax(mockProbs)
        bestTok = max(probs, key=probs.get)
        jevCode = int(bestTok)
        pMax = probs[bestTok]
    elif mockCode is not None:
        jevCode = int(mockCode)
        pMax = 0.85
    elif llamaBin and modelPath and llamaBin.exists() and modelPath.exists():
        jevCode, pMax = runLocalLlama(llamaBin, modelPath, buildJevPrompt(features))
    else:
        # Fail-safe if model binary is missing on ambiguous delta
        jevCode, pMax = 2, 0.50

    finalCode = max(ruleFloor, jevCode)
    needsEscalation = (finalCode >= 2) or (pMax < 0.70)
    return {
        "ruleFloor": ruleFloor,
        "jevCode": jevCode,
        "finalCode": finalCode,
        "label": CODE_LABELS.get(str(finalCode), "2_SUSPICIOUS"),
        "pMax": round(pMax, 4),
        "needsEscalation": needsEscalation,
        "ranModel": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage 2 Local Open-Jev runner")
    parser.add_argument("--features", default="/run/myosSweeper/features.json")
    parser.add_argument("--output", default="/run/myosSweeper/decision.json")
    parser.add_argument("--llama-bin", default="/opt/myosSweeper/bin/llama-cli")
    parser.add_argument("--model", default="/opt/myosSweeper/models/qwen2.5-1.5b-instruct-q4_k_m.gguf")
    parser.add_argument("--model-sha256", default="")
    args = parser.parse_args()

    features = json.loads(Path(args.features).read_text(encoding="utf-8"))
    modelPath = Path(args.model)
    if modelPath.exists() and not verifySha256(modelPath, args.model_sha256):
        result = {
            "ruleFloor": max(3, int(features.get("ruleFloor", 0))),
            "jevCode": 3,
            "finalCode": 3,
            "label": "3_CRITICAL_PRIV_ESC",
            "pMax": 1.0,
            "needsEscalation": True,
            "ranModel": False,
            "error": "MODEL_SHA256_MISMATCH",
        }
    else:
        result = decide(features, Path(args.llama_bin), modelPath)

    Path(args.output).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
