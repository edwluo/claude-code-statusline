#!/bin/bash
# ────────────────────────────────────────────────────────
#  5h billing block widget for Claude Code statusline
#  Displays: ~limit% | remaining time | cost | burn rate
#
#  Requires: ccusage CLI (npm i -g ccusage)
#
#  Block cost limits (from Claude-Code-Usage-Monitor):
#    Pro=$18 | Max5=$35 | Max20=$140
#
#  Change BLOCK_LIMIT below to match your plan.
# ────────────────────────────────────────────────────────

CACHE="/tmp/ccusage-widget.txt"
TTL=30
BLOCK_LIMIT=35    # Max5 5h cost cap — change to 18 (Pro) or 140 (Max20)

# -- cache hit --
if [ -f "$CACHE" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
    if [ "$age" -lt "$TTL" ]; then
        cat "$CACHE"
        exit 0
    fi
fi

# -- parallel fetch --
TMP="/tmp/ccusage-q-$$"
mkdir -p "$TMP"

ccusage blocks --json --jq '.blocks[] | select(.isActive == true)' \
    > "$TMP/b.json" 2>/dev/null &

ccusage daily --since "$(date +%Y%m%d)" --json --jq '.totals.totalCost // 0' \
    > "$TMP/d.txt" 2>/dev/null &

wait

block=$(cat "$TMP/b.json" 2>/dev/null)
daily=$(cat "$TMP/d.txt" 2>/dev/null)
command rm -rf "$TMP"

# -- no active block --
if [ -z "$block" ] || [ "$block" = "null" ]; then
    echo "-- | --/--D | --/h" | tee "$CACHE"
    exit 0
fi

# -- extract --
cost=$(echo "$block" | jq -r '.costUSD // 0')
mins=$(echo "$block" | jq -r '.projection.remainingMinutes // 0')
rate=$(echo "$block" | jq -r '.burnRate.costPerHour // 0')

# -- limit percentage (color-coded) --
pct=$(echo "$cost $BLOCK_LIMIT" | awk '{printf "%d", ($1/$2)*100}')
if [ "$pct" -gt 100 ] 2>/dev/null; then pct=100; fi
if [ "$pct" -ge 80 ] 2>/dev/null; then
    pc="\033[31m~${pct}%\033[0m"       # red
elif [ "$pct" -ge 50 ] 2>/dev/null; then
    pc="\033[33m~${pct}%\033[0m"       # yellow
else
    pc="\033[32m~${pct}%\033[0m"       # green
fi

# -- format --
cf=$(printf "%.1f" "$cost")
df=$(printf "%.1f" "${daily:-0}")
rf=$(printf "%.1f" "$rate")

# -- burn rate indicator --
if (( $(echo "$rate < 1.5" | bc -l 2>/dev/null || echo 1) )); then
    ri="🟢"
elif (( $(echo "$rate < 5.0" | bc -l 2>/dev/null || echo 1) )); then
    ri="🟡"
else
    ri="🔥"
fi

# -- remaining time --
mi=${mins%.*}
if [ "${mi:-0}" -gt 0 ] 2>/dev/null; then
    h=$((mi / 60)); m=$((mi % 60))
    et=$(date -r $(($(date +%s) + mi * 60)) +"%H:%M")
    [ "$h" -gt 0 ] && ts="${h}h${m}m→${et}" || ts="${m}m→${et}"
else
    ts="--"
fi

echo -e "${pc} 5h | ${ts} | \$${cf}/\$${df}D | ${ri} \$${rf}/h" | tee "$CACHE"
