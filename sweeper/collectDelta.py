#!/usr/bin/env python3
"""Stage 1 deterministic collector and rule-floor evaluator for myosSweeper."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

CRITICAL_PRIV_FILES = [
    "/etc/ld.so.preload",
    "/etc/sudoers",
    "/etc/shadow",
    "/etc/passwd",
    "/etc/group",
]
CRITICAL_PRIV_DIRS = ["/etc/sudoers.d", "/etc/pam.d", "/boot"]
NET_CONFIG_FILES = ["/etc/ssh/sshd_config", "/etc/hosts", "/etc/resolv.conf"]
USER_PERSIST_PATHS = [
    "/home/raybeak/.ssh/authorized_keys",
    "/home/raybeak/.config/systemd/user",
    "/home/raybeak/.config/autostart",
]
WATCH_DIRS = ["/etc", "/usr/local/bin", "/home/raybeak/.local/bin"]
PERSIST_DIRS = ["/etc/cron.d", "/etc/cron.daily", "/etc/udev/rules.d"]
MAX_DELTA_ITEMS = 20
AUTH_FAIL_THRESHOLD = 5


def sha256File(path: Path) -> str:
    """Compute SHA-256 hex digest for a regular file."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def runCmd(cmd: list[str], timeout: int = 15) -> tuple[int, str]:
    """Run a subprocess safely and return (returncode, stdout)."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return res.returncode, res.stdout
    except (subprocess.SubprocessError, OSError):
        return 1, ""


def verifySelfAndBaseline(stateDir: Path, manifestPath: Path, keyring: str) -> tuple[bool, str]:
    """Verify baseline GPG signature and sweeper manifest hashes."""
    baseline = stateDir / "baseline.json"
    sig = stateDir / "baseline.json.asc"
    if not baseline.exists():
        return True, "NO_BASELINE_INIT"
    if not sig.exists():
        return False, "MISSING_BASELINE_SIG"

    gpgCmd = ["gpg", "--batch", "--no-default-keyring"]
    if keyring and Path(keyring).exists():
        gpgCmd += ["--keyring", keyring]
    gpgCmd += ["--verify", str(sig), str(baseline)]
    rc, _ = runCmd(gpgCmd, timeout=10)
    if rc != 0:
        return False, "INVALID_BASELINE_GPG_SIG"

    if manifestPath.exists():
        rc, _ = runCmd(["sha256sum", "-c", "--quiet", str(manifestPath)], timeout=10)
        if rc != 0:
            return False, "TAMPER_MANIFEST_MISMATCH"
    return True, "OK"


def collectFileHashes(rootPrefix: Path, relPaths: list[str]) -> dict[str, str]:
    """Collect SHA-256 hashes for target files and directories."""
    hashes: dict[str, str] = {}
    for rel in relPaths:
        target = rootPrefix / rel.lstrip("/")
        if target.is_file():
            try:
                hashes[rel] = sha256File(target)
            except OSError:
                hashes[rel] = "UNREADABLE"
        elif target.is_dir():
            try:
                for p in sorted(target.rglob("*")):
                    if p.is_file() and not p.is_symlink():
                        key = "/" + str(p.relative_to(rootPrefix))
                        try:
                            hashes[key] = sha256File(p)
                        except OSError:
                            hashes[key] = "UNREADABLE"
            except OSError:
                pass
    return hashes


def collectSuidFiles(rootPrefix: Path) -> list[str]:
    """Find SUID/SGID binaries on the root filesystem."""
    rc, out = runCmd(["find", str(rootPrefix), "-xdev", "-perm", "/6000", "-type", "f"], timeout=20)
    if rc != 0 and not out:
        return []
    result = []
    for line in out.splitlines():
        p = Path(line.strip())
        try:
            result.append("/" + str(p.relative_to(rootPrefix)))
        except ValueError:
            result.append(line.strip())
    return sorted(result)


def collectTmpExecutables(rootPrefix: Path) -> list[str]:
    """Find executable regular files under /tmp and /dev/shm."""
    found: list[str] = []
    for sub in ["tmp", "dev/shm"]:
        d = rootPrefix / sub
        if not d.exists():
            continue
        rc, out = runCmd(["find", str(d), "-maxdepth", "3", "-type", "f", "-executable"], timeout=10)
        for line in out.splitlines():
            if line.strip():
                found.append(line.strip())
    return sorted(found)


def collectExternalPorts(allowedPorts: set[str]) -> list[str]:
    """Inspect ss -tulpn for non-loopback listening sockets outside allowlist."""
    rc, out = runCmd(["ss", "-tulpnH"], timeout=10)
    unexpected: list[str] = []
    if rc != 0:
        return unexpected
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        localAddr = parts[4]
        if localAddr.startswith("127.") or localAddr.startswith("[::1]") or localAddr.startswith("::1:"):
            continue
        port = localAddr.rsplit(":", 1)[-1]
        if port not in allowedPorts:
            unexpected.append(f"{parts[0]}:{port}")
    return sorted(set(unexpected))


def checkDpkgIntegrity(changedPaths: list[str]) -> tuple[int, int]:
    """Return (unowned_count, verify_mismatch_count) via dpkg -S and dpkg --verify."""
    unowned = 0
    for path in changedPaths[:50]:
        if path.startswith("/home/") or path.startswith("/tmp/"):
            continue
        rc, _ = runCmd(["dpkg", "-S", path], timeout=5)
        if rc != 0:
            unowned += 1

    _, verifyOut = runCmd(["dpkg", "--verify"], timeout=20)
    mismatches = 0
    for line in verifyOut.splitlines():
        # Flag binary/checksum mismatches ('5' in status field) outside config files ('c')
        if len(line) > 10 and line[2] == "5" and " c " not in line[:16]:
            mismatches += 1
    return unowned, mismatches


def checkJournalLogs(stateDir: Path) -> tuple[int, int, bool]:
    """Read journald warnings/auth fails since last cursor; detect truncation."""
    cursorFile = stateDir / "journal.cursor"
    cmd = ["journalctl", "-p", "warning..emerg", "--no-pager", "--show-cursor", "-n", "200"]
    if cursorFile.exists():
        cursor = cursorFile.read_text(encoding="utf-8").strip()
        if cursor:
            cmd += ["--after-cursor", cursor]
    else:
        cmd += ["--since", "4 hours ago"]

    rc, out = runCmd(cmd, timeout=10)
    cursorReset = False
    if rc != 0 and cursorFile.exists():
        cursorReset = True
        rc, out = runCmd(["journalctl", "-p", "warning..emerg", "--no-pager", "--show-cursor", "-n", "100"], timeout=10)

    authFails = 0
    kernelErrs = 0
    newCursor = ""
    for line in out.splitlines():
        if line.startswith("-- cursor: "):
            newCursor = line.replace("-- cursor: ", "", 1).strip()
            continue
        low = line.lower()
        if any(k in low for k in ["authentication failure", "failed password", "invalid user", "pam_unix"]):
            authFails += 1
        if "kernel:" in low:
            kernelErrs += 1

    if newCursor:
        cursorFile.write_text(newCursor, encoding="utf-8")
    return authFails, kernelErrs, cursorReset


def checkAptRecent(rootPrefix: Path) -> bool:
    """Check if /var/log/dpkg.log was modified within the last 4 hours."""
    dpkgLog = rootPrefix / "var/log/dpkg.log"
    if not dpkgLog.exists():
        return False
    return (time.time() - dpkgLog.stat().st_mtime) <= 14400


def classifyPath(path: str) -> str:
    """Map raw path to sanitized structural class (no raw strings leave Stage 1)."""
    if path == "/etc/ld.so.preload":
        return "ld_preload"
    if path.startswith("/etc/sudoers") or path.startswith("/etc/pam.d") or path == "/etc/shadow":
        return "priv_auth_etc"
    if path.startswith("/etc/ssh") or path in ("/etc/hosts", "/etc/resolv.conf"):
        return "net_etc"
    if path.startswith("/boot"):
        return "boot_image"
    if "/.ssh/authorized_keys" in path:
        return "ssh_auth_keys"
    if "/systemd/user" in path or "/autostart" in path or "/etc/cron" in path or "/udev/rules.d" in path:
        return "persistence_unit"
    if path.startswith("/usr/local/bin") or "/.local/bin" in path:
        return "local_bin"
    if path.startswith("/etc"):
        return "etc_conf"
    return "other"


def evaluateRuleFloor(snap: dict[str, Any], baseline: dict[str, Any], liveMode: bool) -> dict[str, Any]:
    """Compute deterministic ruleFloor (0..4) and sanitized feature vector."""
    oldHashes: dict[str, str] = baseline.get("hashes", {})
    newHashes: dict[str, str] = snap.get("hashes", {})
    changed = sorted(
        k for k in set(oldHashes) | set(newHashes)
        if oldHashes.get(k) != newHashes.get(k)
    )

    oldSuid = set(baseline.get("suid", []))
    newSuid = set(snap.get("suid", []))
    addedSuid = sorted(newSuid - oldSuid)

    tmpExecs = snap.get("tmpExecs", [])
    extPorts = snap.get("externalPorts", [])
    authFails = int(snap.get("authFailCount", 0))
    kernelErrs = int(snap.get("kernelErrCount", 0))
    cursorReset = bool(snap.get("journalCursorReset", False))
    aptRecent = bool(snap.get("aptRecent", False))
    integrityOk = bool(snap.get("integrityOk", True))

    unownedCount, dpkgMismatch = (0, 0)
    if liveMode and changed:
        unownedCount, dpkgMismatch = checkDpkgIntegrity(changed)

    modifiedClasses = sorted({classifyPath(p) for p in changed[:MAX_DELTA_ITEMS]})
    ruleFloor = 0
    reasons: list[str] = []

    if not integrityOk:
        ruleFloor = max(ruleFloor, 3)
        reasons.append(snap.get("integrityReason", "TAMPER"))

    if extPorts or "net_etc" in modifiedClasses or "ssh_auth_keys" in modifiedClasses:
        ruleFloor = max(ruleFloor, 4)
        reasons.append("NET_OR_SSH_TAMPER")

    if "ld_preload" in modifiedClasses or "priv_auth_etc" in modifiedClasses or addedSuid or "boot_image" in modifiedClasses:
        if not (aptRecent and unownedCount == 0 and dpkgMismatch == 0 and "ld_preload" not in modifiedClasses and not addedSuid):
            ruleFloor = max(ruleFloor, 3)
            reasons.append("PRIV_ESC_OR_BOOT")

    if tmpExecs or dpkgMismatch > 0 or unownedCount > 0 or "persistence_unit" in modifiedClasses or authFails >= AUTH_FAIL_THRESHOLD or cursorReset or len(changed) > MAX_DELTA_ITEMS:
        ruleFloor = max(ruleFloor, 2)
        reasons.append("SUSPICIOUS_ANOMALY")

    if ruleFloor == 0 and (changed or authFails > 0 or kernelErrs > 0):
        ruleFloor = 1
        reasons.append("AMBIGUOUS_DELTA")

    features = {
        "ruleFloor": ruleFloor,
        "reasons": reasons,
        "aptRecent": aptRecent,
        "deltaCount": len(changed),
        "modifiedClasses": modifiedClasses,
        "addedSuidCount": len(addedSuid),
        "tmpExecCount": len(tmpExecs),
        "newExternalPortsCount": len(extPorts),
        "newExternalPorts": extPorts,
        "dpkgVerifyMismatchCount": dpkgMismatch,
        "unownedSystemFilesCount": unownedCount,
        "authFailCount": authFails,
        "kernelErrCount": kernelErrs,
    }
    return features


def buildSnapshot(rootPrefix: Path, stateDir: Path, allowedPorts: set[str], integrityOk: bool, integrityReason: str) -> dict[str, Any]:
    """Collect current host snapshot under rootPrefix."""
    targets = CRITICAL_PRIV_FILES + CRITICAL_PRIV_DIRS + NET_CONFIG_FILES + USER_PERSIST_PATHS + WATCH_DIRS + PERSIST_DIRS
    hashes = collectFileHashes(rootPrefix, targets)
    suid = collectSuidFiles(rootPrefix)
    tmpExecs = collectTmpExecutables(rootPrefix)
    extPorts = collectExternalPorts(allowedPorts)
    authFails, kernelErrs, cursorReset = checkJournalLogs(stateDir)
    aptRecent = checkAptRecent(rootPrefix)

    return {
        "timestamp": int(time.time()),
        "integrityOk": integrityOk,
        "integrityReason": integrityReason,
        "hashes": hashes,
        "suid": suid,
        "tmpExecs": tmpExecs,
        "externalPorts": extPorts,
        "authFailCount": authFails,
        "kernelErrCount": kernelErrs,
        "journalCursorReset": cursorReset,
        "aptRecent": aptRecent,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage 1 deterministic collector")
    parser.add_argument("--root", default="/", help="Root prefix for scanning")
    parser.add_argument("--state-dir", default="/var/lib/myosSweeper")
    parser.add_argument("--run-dir", default="/run/myosSweeper")
    parser.add_argument("--manifest", default="/opt/myosSweeper/manifest.sha256")
    parser.add_argument("--keyring", default="/etc/myosSweeper/trustedkey.gpg")
    parser.add_argument("--allowed-ports", default="41641")
    parser.add_argument("--write-baseline", action="store_true", help="Write current snapshot as baseline.json")
    args = parser.parse_args()

    rootPrefix = Path(args.root)
    stateDir = Path(args.state_dir)
    runDir = Path(args.run_dir)
    stateDir.mkdir(parents=True, exist_ok=True)
    runDir.mkdir(parents=True, exist_ok=True)

    allowedPorts = {p.strip() for p in args.allowed_ports.split(",") if p.strip()}
    integrityOk, integrityReason = verifySelfAndBaseline(stateDir, Path(args.manifest), args.keyring)
    snap = buildSnapshot(rootPrefix, stateDir, allowedPorts, integrityOk, integrityReason)

    (runDir / "snapshot.json").write_text(json.dumps(snap, indent=2), encoding="utf-8")

    if args.write_baseline:
        (stateDir / "baseline.json").write_text(json.dumps(snap, indent=2), encoding="utf-8")
        print(json.dumps({"status": "BASELINE_WRITTEN", "files": len(snap["hashes"])}))
        return 0

    baselinePath = stateDir / "baseline.json"
    if not baselinePath.exists():
        print(json.dumps({"ruleFloor": 2, "reasons": ["MISSING_BASELINE"]}))
        (runDir / "features.json").write_text(json.dumps({"ruleFloor": 2, "reasons": ["MISSING_BASELINE"]}), encoding="utf-8")
        return 0

    baseline = json.loads(baselinePath.read_text(encoding="utf-8"))
    features = evaluateRuleFloor(snap, baseline, liveMode=(args.root == "/"))
    (runDir / "features.json").write_text(json.dumps(features, indent=2), encoding="utf-8")
    print(json.dumps(features))
    return 0


if __name__ == "__main__":
    sys.exit(main())
