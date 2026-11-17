#!/bin/sh
# prints "음량: N%" (integer 0-100); muted shows 0
out=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
case "$out" in
    *MUTED*) echo "음량: 0%" ;;
    *) echo "$out" | awk '{printf "음량: %d%%\n", $2 * 100 + 0.5}' ;;
esac
