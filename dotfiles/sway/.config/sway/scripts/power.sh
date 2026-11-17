#!/usr/bin/env bash
# ~/.config/sway/scripts/power.sh — text-only power menu (wofi dmenu)

choice=$(printf '%s\n' "Lock" "Exit" "Reboot" "Poweroff" "Cancel" \
    | wofi --dmenu --prompt "PWR" --insensitive --lines 6 --width 200)

case "$choice" in
    Lock)     swaylock -f -c 000000 ;;
    Exit)     swaymsg exit ;;
    Reboot)   systemctl reboot ;;
    Poweroff) systemctl poweroff ;;
    *)        exit 0 ;;
esac
