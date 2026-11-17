#!/bin/sh
# text-only power menu (wofi dmenu mode)
choice=$(printf '%s\n' '[종료] Poweroff' '[재시작] Reboot' '[로그아웃] Exit' '[취소] Cancel' \
    | wofi --dmenu --prompt '전원' --width 320 --height 200)

case "$choice" in
    *Poweroff*) systemctl poweroff ;;
    *Reboot*)   systemctl reboot ;;
    *Exit*)     swaymsg exit ;;
esac
