#!/usr/bin/env bash
# ~/.config/waybar/netServices.sh — Text-only Waybar status & wofi GUI toggle for Tailscale/SSH/mDNS
set -euo pipefail

is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

print_status() {
    local active=()
    is_active tailscaled.service && active+=("TS")
    (is_active ssh.socket || is_active ssh.service) && active+=("SSH")
    (is_active avahi-daemon.socket || is_active avahi-daemon.service) && active+=("MDNS")

    if (( ${#active[@]} == 0 )); then
        printf '{"text":"[NET: LOCK]","class":"locked"}\n'
    else
        local joined
        joined="$(IFS=/; echo "${active[*]}")"
        printf '{"text":"[NET: %s]","class":"open"}\n' "$joined"
    fi
}

run_toggle_cmd() {
    local cmd="$1"
    foot -e sh -c "$cmd; echo ''; echo '[Done - press Enter]'; read -r _"
}

show_menu() {
    local ts_state ssh_state mdns_state
    ts_state="$(is_active tailscaled.service && echo ON || echo OFF)"
    ssh_state="$( (is_active ssh.socket || is_active ssh.service) && echo ON || echo OFF )"
    mdns_state="$( (is_active avahi-daemon.socket || is_active avahi-daemon.service) && echo ON || echo OFF )"

    local choice
    choice="$(printf '%s\n' \
        "Tailscale [$ts_state] -> Toggle" \
        "SSH [$ssh_state] -> Toggle" \
        "mDNS/Avahi [$mdns_state] -> Toggle" \
        "Lock All (Stop TS/SSH/mDNS)" \
        "Cancel" \
        | wofi --dmenu --prompt "NET" --insensitive --lines 6 --width 300 || true)"

    case "$choice" in
        Tailscale*)
            if [[ "$ts_state" == "OFF" ]]; then
                run_toggle_cmd "sudo ufw allow 41641/udp comment Tailscale && sudo systemctl start tailscaled.service && tailscale status"
            else
                run_toggle_cmd "sudo systemctl stop tailscaled.service && sudo ufw delete allow 41641/udp || true"
            fi
            ;;
        SSH*)
            if [[ "$ssh_state" == "OFF" ]]; then
                run_toggle_cmd "sudo systemctl start ssh.socket && systemctl status ssh.socket --no-pager"
            else
                run_toggle_cmd "sudo systemctl stop ssh.socket ssh.service"
            fi
            ;;
        mDNS*)
            if [[ "$mdns_state" == "OFF" ]]; then
                run_toggle_cmd "sudo systemctl start avahi-daemon.socket avahi-daemon.service"
            else
                run_toggle_cmd "sudo systemctl stop avahi-daemon.socket avahi-daemon.service"
            fi
            ;;
        Lock*)
            run_toggle_cmd "sudo systemctl stop tailscaled.service ssh.socket ssh.service avahi-daemon.socket avahi-daemon.service; sudo ufw delete allow 41641/udp 2>/dev/null || true"
            ;;
        *)
            exit 0
            ;;
    esac
}

if [[ "${1:-}" == "--menu" ]]; then
    show_menu
else
    print_status
fi
