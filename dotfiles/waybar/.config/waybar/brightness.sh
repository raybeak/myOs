#!/bin/sh
# prints "밝기: N%" (integer 0-100)
pct=$(brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d '%')
echo "밝기: ${pct:-0}%"
