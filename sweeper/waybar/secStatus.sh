#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${MYOS_SWEEPER_STATE:-/var/lib/myosSweeper/state.json}"
STALE_THRESHOLD=18000 # 5 hours

if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"text":"[SEC: INIT]","class":"stale"}\n'
    exit 0
fi

read -r ts status < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(int(d.get("timestamp", 0)), d.get("status", "UNKNOWN"))
' "$STATE_FILE" 2>/dev/null || echo "0 ERR")

now="$(date +%s)"
age=$(( now - ts ))

if (( age > STALE_THRESHOLD )) || [[ "$ts" -eq 0 ]]; then
    printf '{"text":"[SEC: STALE]","class":"stale"}\n'
elif [[ "$status" == "CRIT" ]]; then
    printf '{"text":"[SEC: CRIT]","class":"critical"}\n'
elif [[ "$status" == "WARN" ]]; then
    printf '{"text":"[SEC: WARN]","class":"warning"}\n'
else
    printf '{"text":"[SEC: OK]","class":"ok"}\n'
fi
