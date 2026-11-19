#!/usr/bin/env bash
set -euo pipefail

# MyOS COA 2 Bootstrap Script (Ubuntu Server 26.04 LTS Minimal)
# Usage: ./bootstrap.sh [--dry-run]

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[INFO] Running in DRY-RUN mode (no system changes)."
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

run_cmd() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

read_list() {
    local file="$1"
    grep -Ev '^\s*(#|$)' "$file" | sed 's/#.*//' | xargs -n1 echo || true
}

echo "=== [1/8] Purging bloat packages (remove.txt) ==="
if [[ -f "$REPO_DIR/remove.txt" ]]; then
    mapfile -t REMOVE_PKGS < <(read_list "$REPO_DIR/remove.txt")
    if (( ${#REMOVE_PKGS[@]} > 0 )); then
        run_cmd sudo apt-get purge -y "${REMOVE_PKGS[@]}" || true
        run_cmd sudo apt-get autoremove -y
    fi
fi

echo "=== [2/8] Installing core packages (packagesV2.txt) ==="
run_cmd sudo apt-get update
mapfile -t INSTALL_PKGS < <(read_list "$REPO_DIR/packagesV2.txt")
if (( ${#INSTALL_PKGS[@]} > 0 )); then
    run_cmd sudo apt-get install -y "${INSTALL_PKGS[@]}"
fi

echo "=== [3/8] Installing external repos & CLI tools (non-fatal if repo missing) ==="
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-resolute}")"

if ! command -v brave-browser >/dev/null 2>&1; then
    run_cmd bash -c "curl -fsS https://dl.brave.com/install.sh | sh" || echo "[WARN] Brave install failed; continue."
fi

if ! command -v tailscale >/dev/null 2>&1; then
    run_cmd bash -c "curl -fsSL https://tailscale.com/install.sh | sh" || echo "[WARN] Tailscale install failed; continue."
fi

if ! command -v docker >/dev/null 2>&1; then
    run_cmd bash -c "
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable\" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    " || echo "[WARN] Docker repo ($CODENAME) install failed; verify manually."
fi

if [[ ! -x "$TARGET_HOME/.cargo/bin/cargo" ]]; then
    run_cmd bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" || echo "[WARN] rustup failed."
fi
if [[ -x "$TARGET_HOME/.cargo/bin/cargo" ]]; then
    if ! command -v bluetui >/dev/null 2>&1; then
        run_cmd "$TARGET_HOME/.cargo/bin/cargo" install bluetui || echo "[WARN] bluetui cargo install failed; waybar falls back to bluetoothctl."
    fi
fi

echo "=== [4/8] Creating base directories & stowing dotfiles ==="
for dir in download photo pdf; do
    if [[ ! -d "$TARGET_HOME/$dir" ]]; then
        run_cmd mkdir -p "$TARGET_HOME/$dir"
        run_cmd chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/$dir"
    fi
done
if [[ -d "$REPO_DIR/dotfiles" ]]; then
    if [[ -f "$TARGET_HOME/.profile" && ! -L "$TARGET_HOME/.profile" ]]; then
        run_cmd mkdir -p "$TARGET_HOME/myos-backup"
        run_cmd mv "$TARGET_HOME/.profile" "$TARGET_HOME/myos-backup/.profile.orig"
    fi
    for pkg_dir in "$REPO_DIR"/dotfiles/*/; do
        pkg="$(basename "$pkg_dir")"
        if [[ "$pkg" == "gnupg" ]]; then
            run_cmd mkdir -p -m 700 "$TARGET_HOME/.gnupg"
            run_cmd chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.gnupg"
            if [[ -f "$TARGET_HOME/.gnupg/sshcontrol" && ! -L "$TARGET_HOME/.gnupg/sshcontrol" ]]; then
                run_cmd mkdir -p "$TARGET_HOME/myos-backup"
                run_cmd mv "$TARGET_HOME/.gnupg/sshcontrol" "$TARGET_HOME/myos-backup/sshcontrol.orig"
            fi
            run_cmd stow --no-folding --restow -d "$REPO_DIR/dotfiles" -t "$TARGET_HOME" "$pkg"
        else
            run_cmd stow --restow -d "$REPO_DIR/dotfiles" -t "$TARGET_HOME" "$pkg"
        fi
    done
fi

echo "=== [5/8] Deploying system /etc configs (excluding netplan) ==="
if [[ -d "$REPO_DIR/etc/greetd" ]]; then
    run_cmd sudo install -Dm644 "$REPO_DIR/etc/greetd/config.toml" /etc/greetd/config.toml
fi
if [[ -f "$REPO_DIR/etc/systemd/zram-generator.conf" ]]; then
    run_cmd sudo install -Dm644 "$REPO_DIR/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
fi
if [[ -f "$REPO_DIR/etc/tlp.d/90-gram.conf" ]]; then
    run_cmd sudo install -Dm644 "$REPO_DIR/etc/tlp.d/90-gram.conf" /etc/tlp.d/90-gram.conf
fi
if [[ -f "$REPO_DIR/etc/sudoers.d/ssh-agent" ]]; then
    run_cmd sudo install -Dm440 "$REPO_DIR/etc/sudoers.d/ssh-agent" /etc/sudoers.d/ssh-agent
    run_cmd sudo visudo -cf /etc/sudoers.d/ssh-agent
fi
if [[ -f "$REPO_DIR/etc/security/authorized_keys" ]]; then
    run_cmd sudo install -Dm644 "$REPO_DIR/etc/security/authorized_keys" /etc/security/authorized_keys
    for pam_file in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
        if [[ -f "$pam_file" ]] && ! grep -q "pam_ssh_agent_auth.so" "$pam_file"; then
            run_cmd sudo sed -i '/^@include common-auth/i auth\tsufficient\tpam_ssh_agent_auth.so file=/etc/security/authorized_keys' "$pam_file"
        fi
    done
fi
if [[ -f "$REPO_DIR/etc/ssh/sshd_config.d/01-hardening.conf" ]] && command -v sshd >/dev/null 2>&1; then
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        echo "[WARN] Running over SSH; skipping SSHD hardening cutover (intended for local laptop console only)."
    else
        run_cmd sudo install -Dm644 "$REPO_DIR/etc/ssh/sshd_config.d/01-hardening.conf" /etc/ssh/sshd_config.d/01-hardening.conf
        run_cmd sudo sshd -t
        if systemctl is-active --quiet ssh.service; then
            run_cmd sudo systemctl reload ssh.service
        fi
    fi
fi
if [[ -f "$REPO_DIR/etc/sysctl.d/99-hardening.conf" ]]; then
    run_cmd sudo install -Dm644 "$REPO_DIR/etc/sysctl.d/99-hardening.conf" /etc/sysctl.d/99-hardening.conf
    run_cmd sudo sysctl -e -p /etc/sysctl.d/99-hardening.conf || true
fi
if command -v ufw >/dev/null 2>&1; then
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        echo "[WARN] Running over SSH; skipping UFW baseline cutover (intended for local laptop console only)."
    else
        run_cmd sudo ufw default deny incoming
        run_cmd sudo ufw default allow outgoing
        run_cmd sudo ufw allow 41641/udp comment "Tailscale"
        run_cmd sudo ufw --force enable
    fi
fi

echo "=== [6/8] Applying services & groups (servicesV2.txt) ==="
if [[ -f "$REPO_DIR/servicesV2.txt" ]]; then
    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/#.*//' | xargs)"
        [[ -z "$line" ]] && continue
        read -r scope action unit <<< "$line"
        case "$scope:$action" in
            system:enable)  run_cmd sudo systemctl enable "$unit" || true ;;
            system:disable) run_cmd sudo systemctl disable "$unit" || true ;;
            user:enable)    run_cmd systemctl --user enable "$unit" || true ;;
            user:disable)   run_cmd systemctl --user disable "$unit" || true ;;
            group:*)        run_cmd sudo usermod -aG "$action" "$TARGET_USER" ;;
            group-remove:*)
                if id -nG "$TARGET_USER" | grep -qw "$action"; then
                    run_cmd sudo gpasswd -d "$TARGET_USER" "$action" || true
                fi
                ;;
        esac
    done < "$REPO_DIR/servicesV2.txt"
fi

echo "=== [7/8] Setting default editor (micro) ==="
if command -v micro >/dev/null 2>&1; then
    run_cmd sudo update-alternatives --set editor /usr/bin/micro || true
fi
run_cmd git config --global core.editor micro

echo "=== [8/8] Final step: NetworkManager cutover ==="
if [[ -f "$REPO_DIR/etc/netplan/01-nm.yaml" ]]; then
    if [[ -f /etc/netplan/50-cloud-init.yaml ]]; then
        run_cmd mkdir -p "$TARGET_HOME/myos-backup"
        run_cmd sudo mv /etc/netplan/50-cloud-init.yaml "$TARGET_HOME/myos-backup/"
    fi
    run_cmd sudo install -Dm600 "$REPO_DIR/etc/netplan/01-nm.yaml" /etc/netplan/01-nm.yaml
    run_cmd sudo netplan apply
    run_cmd sudo systemctl disable systemd-networkd.service systemd-networkd.socket \
        systemd-networkd-wait-online.service networkd-dispatcher.service || true
fi

echo "=== Bootstrap complete. Reboot recommended. ==="
