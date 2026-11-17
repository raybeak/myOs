#!/bin/sh
# prints "배터리: N%" (integer 0-100) from /sys/class/power_supply
for f in /sys/class/power_supply/BAT*/capacity; do
    [ -r "$f" ] || continue
    echo "배터리: $(cat "$f")%"
    exit 0
done
echo "배터리: N/A"
