#!/usr/bin/env python3
"""Stage 3 Desktop escalation, persistent pending alerts, state.json & swaync notify."""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def sanitizeAscii(text: str, maxLen: int = 180) -> str:
    """Strip non-printable/non-ASCII characters from remote or untrusted text."""
    cleaned = re.sub(r"[^\x20-\x7E]", " ", text)
    return " ".join(cleaned.split())[:maxLen]


def queryDesktop(endpoint: str, tokenFile: Path, payload: dict[str, Any], timeoutSec: int = 5) -> str:
    """Send sanitized delta summary to Tailscale Desktop System 2 endpoint."""
    if not endpoint:
        return ""
    headers = {"Content-Type": "application/json"}
    if tokenFile.exists():
        token = tokenFile.read_text(encoding="utf-8").strip()
        if token:
            headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeoutSec) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            msg = body.get("summary") or body.get("choices", [{}])[0].get("message", {}).get("content", "")
            return sanitizeAscii(str(msg))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return ""


def sendSwayNotification(title: str, body: str, critical: bool) -> None:
    """Dispatch notification to active raybeak user session."""
    urgency = "critical" if critical else "normal"
    cmd = [
        "systemd-run", "--user", "--machine=raybeak@.host", "--wait", "--collect",
        "notify-send", "-u", urgency, title, body,
    ]
    try:
        subprocess.run(cmd, capture_output=True, timeout=5)
    except (subprocess.SubprocessError, OSError):
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage 3 escalation and alerting")
    parser.add_argument("--features", default="/run/myosSweeper/features.json")
    parser.add_argument("--decision", default="/run/myosSweeper/decision.json")
    parser.add_argument("--state-dir", default="/var/lib/myosSweeper")
    parser.add_argument("--log-dir", default="/var/log/myosSweeper")
    parser.add_argument("--desktop-endpoint", default="")
    parser.add_argument("--desktop-token-file", default="/etc/myosSweeper/desktop.token")
    parser.add_argument("--no-notify", action="store_true")
    args = parser.parse_args()

    stateDir = Path(args.state_dir)
    logDir = Path(args.log_dir)
    stateDir.mkdir(parents=True, exist_ok=True)
    logDir.mkdir(parents=True, exist_ok=True)

    features = json.loads(Path(args.features).read_text(encoding="utf-8"))
    decision = json.loads(Path(args.decision).read_text(encoding="utf-8"))

    pendingPath = stateDir / "pending.jsonl"
    now = int(time.time())
    finalCode = int(decision.get("finalCode", 0))
    needsEsc = bool(decision.get("needsEscalation", False))

    desktopNote = ""
    if needsEsc:
        desktopNote = queryDesktop(args.desktop_endpoint, Path(args.desktop_token_file), {"features": features, "decision": decision})
        entry = {
            "timestamp": now,
            "finalCode": finalCode,
            "label": decision.get("label"),
            "reasons": features.get("reasons", []),
            "ports": features.get("newExternalPorts", []),
            "desktopNote": desktopNote,
        }
        with pendingPath.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

        if not args.no_notify:
            sourceTag = "[JEV+DESKTOP]" if desktopNote else "[JEV-LOCAL]"
            portsStr = ",".join(features.get("newExternalPorts", []))
            fallbackMsg = f"Reasons: {','.join(features.get('reasons', []))}" + (f" | Ports: {portsStr}" if portsStr else "")
            summary = desktopNote or fallbackMsg
            sendSwayNotification(f"{sourceTag} {decision.get('label')}", summary, critical=(finalCode >= 3))

    hasPending = pendingPath.exists() and pendingPath.stat().st_size > 0
    maxPendingCode = finalCode
    if hasPending:
        for line in pendingPath.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not line.strip():
                continue
            try:
                maxPendingCode = max(maxPendingCode, int(json.loads(line).get("finalCode", 0)))
            except (json.JSONDecodeError, ValueError, TypeError):
                maxPendingCode = max(maxPendingCode, 2)
        status = "CRIT" if maxPendingCode >= 3 else "WARN"
    else:
        status = "OK"

    state = {
        "timestamp": now,
        "status": status,
        "code": maxPendingCode if hasPending else finalCode,
        "hasPending": hasPending,
    }
    (stateDir / "state.json").write_text(json.dumps(state, indent=2), encoding="utf-8")

    auditEntry = {"timestamp": now, "features": features, "decision": decision, "status": status}
    with (logDir / "audit.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(auditEntry) + "\n")

    print(json.dumps(state))
    return 0


if __name__ == "__main__":
    sys.exit(main())
