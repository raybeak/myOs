#!/usr/bin/env bash
set -euo pipefail

# Live Deployment Script for myosSweeper (/opt/myosSweeper)
# Run as: sudo ~/myOs/sweeper/installSweeper.sh

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERR] Run with sudo: sudo $0" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-raybeak}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
OPT_DIR="/opt/myosSweeper"
ETC_DIR="/etc/myosSweeper"
STATE_DIR="/var/lib/myosSweeper"
LOG_DIR="/var/log/myosSweeper"
RUN_DIR="/run/myosSweeper"

echo "=== [1/7] Installing AIDE & dependencies ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y aide curl python3 gnupg

echo "=== [2/7] Creating directories & copying sweeper ==="
install -d -m 755 "$OPT_DIR" "$OPT_DIR/bin" "$OPT_DIR/models" "$OPT_DIR/evals" "$OPT_DIR/waybar" "$ETC_DIR" "$STATE_DIR"
install -d -m 750 "$LOG_DIR" "$RUN_DIR"

cp "$SRC_DIR"/*.py "$SRC_DIR/sweeper.conf" "$OPT_DIR/"
install -m 755 "$SRC_DIR/myosSweeper" "$OPT_DIR/myosSweeper"
cp -r "$SRC_DIR/evals/"* "$OPT_DIR/evals/"
install -m 755 "$SRC_DIR/waybar/secStatus.sh" "$OPT_DIR/waybar/secStatus.sh"

echo "=== [3/7] Installing llama-cli (ggml-org/llama.cpp) ==="
if [[ ! -x "$OPT_DIR/bin/llama-cli" ]]; then
    TMP_LLAMA="$(mktemp -d)"
    LLAMA_URL="$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10" \
        | python3 -c 'import json,sys; rels=json.load(sys.stdin); print(next(a["browser_download_url"] for r in rels for a in r.get("assets", []) if a["name"].endswith("-bin-ubuntu-x64.tar.gz")))')"
    curl -fsSL "$LLAMA_URL" -o "$TMP_LLAMA/llama.tar.gz"
    tar -xzf "$TMP_LLAMA/llama.tar.gz" -C "$TMP_LLAMA"
    find "$TMP_LLAMA" -type f \( -name "llama-cli" -o -name "*.so*" \) -exec cp -P {} "$OPT_DIR/bin/" \;
    chmod 755 "$OPT_DIR/bin/llama-cli"
    rm -rf "$TMP_LLAMA"
fi

echo "=== [4/7] Downloading Qwen2.5-1.5B-Instruct-Q4_K_M.gguf (~986MB) ==="
MODEL_FILE="$OPT_DIR/models/qwen2.5-1.5b-instruct-q4_k_m.gguf"
if [[ ! -f "$MODEL_FILE" ]]; then
    curl -fL "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf" \
        -o "$MODEL_FILE"
fi

echo "=== [5/7] Pinning SHA-256 hashes ==="
LLAMA_HASH="$(sha256sum "$OPT_DIR/bin/llama-cli" | awk '{print $1}')"
MODEL_HASH="$(sha256sum "$MODEL_FILE" | awk '{print $1}')"
sed -i "s|PIN_LLAMA_SHA256_BEFORE_DEPLOY|$LLAMA_HASH|" "$OPT_DIR/sweeper.conf"
sed -i "s|PIN_MODEL_SHA256_BEFORE_DEPLOY|$MODEL_HASH|" "$OPT_DIR/sweeper.conf"
sha256sum "$OPT_DIR/collectDelta.py" "$OPT_DIR/runJev.py" "$OPT_DIR/escalateAndAlert.py" \
    "$OPT_DIR/myosSweeper" "$OPT_DIR/sweeper.conf" "$OPT_DIR/bin/llama-cli" \
    "$OPT_DIR/bin/"*.so* "$MODEL_FILE" > "$OPT_DIR/manifest.sha256"
chmod 644 "$OPT_DIR/manifest.sha256"

echo "=== [6/7] Configuring GPG trusted keyring (hardware/passphrase key required) ==="
KEY_FPR="${SIGNING_KEY_ID:-2020F34F7015C34F052A1A3E4BF8329DC5E9F845}"
if ! sudo -u "$TARGET_USER" gpg --list-keys "$KEY_FPR" >/dev/null 2>&1; then
    KEY_FPR="$(sudo -u "$TARGET_USER" gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
fi
if [[ -z "$KEY_FPR" ]]; then
    echo "[ERR] No GPG signing key found for $TARGET_USER. Provision JavaCard or passphrase-protected key first." >&2
    exit 1
fi
sudo -u "$TARGET_USER" gpg --export "$KEY_FPR" > "$ETC_DIR/trustedkey.gpg"
chmod 644 "$ETC_DIR/trustedkey.gpg"
sed -i "s|^SIGNING_KEY_ID=.*|SIGNING_KEY_ID=\"${KEY_FPR}\"|" "$OPT_DIR/sweeper.conf"

echo "=== [7/7] Installing systemd units, logrotate, & AIDE init ==="
cp "$SRC_DIR/systemd/"*.service "$SRC_DIR/systemd/"*.timer /etc/systemd/system/
cp "$SRC_DIR/logrotate/myosSweeper" /etc/logrotate.d/myosSweeper
systemd-analyze verify /etc/systemd/system/myosSweeper.service /etc/systemd/system/myosSweeper.timer || true

systemctl daemon-reload
systemctl enable --now myosSweeper.timer myosSweeper-aide.timer

if [[ ! -f /var/lib/aide/aide.db ]]; then
    echo "[INFO] Initializing AIDE database (background/may take 1-2 min)..."
    aideinit --yes --force || true
fi

echo "=== Initializing & signing baseline ==="
python3 "$OPT_DIR/collectDelta.py" --root / --state-dir "$STATE_DIR" --run-dir "$RUN_DIR" --allowed-ports "22,5353,41641" --write-baseline
chmod 644 "$STATE_DIR/baseline.json"
sudo -u "$TARGET_USER" gpg --batch --yes --detach-sign --armor -u "$KEY_FPR" < "$STATE_DIR/baseline.json" > "$STATE_DIR/baseline.json.asc"
chmod 644 "$STATE_DIR/baseline.json.asc"
: > "$STATE_DIR/pending.jsonl"
printf '{"timestamp": %d, "status": "OK", "code": 0, "hasPending": false}\n' "$(date +%s)" > "$STATE_DIR/state.json"
chown -R root:root "$OPT_DIR"
chmod -R a+rX "$OPT_DIR"
chmod 644 "$STATE_DIR/state.json"

echo "=== Deployment complete! Run: swaymsg reload ==="
