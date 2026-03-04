#!/bin/bash
# ────────────────────────────────────────────────────────
#  Claude Code Statusline
#
#  Data flow: Claude Code stdin JSON → this script → stdout
#  Trigger: after each assistant message (~300ms debounce)
#
#  Line 1: Model·Auth | Context progress bar | Git branch/changes | Vim mode
#  Line 2: 5h billing block (ccusage-widget.sh, 30s cache)
#  Line 3: $cost D:daily_tok i:in/o:out cR:cache_read cW:cache_write | duration | code | CWD
# ────────────────────────────────────────────────────────

input=$(cat)

# ── Colors ─────────────────────────────────────────────
RST='\033[0m' BOLD='\033[1m' DIM='\033[2m'
CYN='\033[36m' GRN='\033[32m' YEL='\033[33m' RED='\033[31m' MAG='\033[35m'

# ── Extract all fields in one jq call ──────────────────
eval "$(echo "$input" | jq -r '
  "MODEL="     + (.model.display_name // "?" | @sh),
  "PCT="       + (.context_window.used_percentage // 0 | floor | tostring),
  "CTX_MAX="   + (.context_window.context_window_size // 200000 | tostring),
  "SESS_COST=" + (.cost.total_cost_usd // 0 | tostring),
  "DUR_MS="    + (.cost.total_duration_ms // 0 | floor | tostring),
  "LINES_ADD=" + (.cost.total_lines_added // 0 | tostring),
  "LINES_DEL=" + (.cost.total_lines_removed // 0 | tostring),
  "CWD="       + (.workspace.current_dir // "?" | @sh),
  "VIM_MODE="  + (.vim.mode // "" | @sh),
  "SESS_ID="   + (.session_id // "" | @sh)
')"

# ── Context progress bar (green <50, yellow >=50, red >=80) ──
pct=${PCT:-0}
if [ "$pct" -ge 80 ] 2>/dev/null; then   bar_c="$RED"
elif [ "$pct" -ge 50 ] 2>/dev/null; then  bar_c="$YEL"
else bar_c="$GRN"; fi

filled=$((pct / 10)); empty=$((10 - filled))
bar=""; [ "$filled" -gt 0 ] && bar=$(printf "%${filled}s" | tr ' ' '▓')
[ "$empty" -gt 0 ] && bar="${bar}$(printf "%${empty}s" | tr ' ' '░')"
[ "${CTX_MAX:-200000}" -ge 1000000 ] && ctx_lbl="1M" || ctx_lbl="200k"

# ── Git info (5s file cache) ───────────────────────────
gc="/tmp/sl-git-cache"
now=$(date +%s)
if [ ! -f "$gc" ] || [ $(( now - $(stat -f %m "$gc" 2>/dev/null || echo 0) )) -gt 5 ]; then
  if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    _b=$(git -C "$CWD" branch --show-current 2>/dev/null)
    _s=$(git -C "$CWD" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    _m=$(git -C "$CWD" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    echo "${_b}|${_s}|${_m}" > "$gc"
  else
    echo "||" > "$gc"
  fi
fi
IFS='|' read -r branch staged modified < "$gc"
git_str=""
if [ -n "$branch" ]; then
  git_str=" ${MAG}${branch}${RST}"
  [ "${staged:-0}" -gt 0 ] && git_str="${git_str} ${GRN}+${staged}${RST}"
  [ "${modified:-0}" -gt 0 ] && git_str="${git_str} ${YEL}~${modified}${RST}"
fi

# ── Auth mode detection ────────────────────────────────
if [ -n "$ANTHROPIC_API_KEY" ] || [ -n "$ANTHROPIC_AUTH_TOKEN" ]; then
  _host=""
  if [ -n "$ANTHROPIC_BASE_URL" ]; then
    _host="${ANTHROPIC_BASE_URL#*://}"; _host="${_host%%/*}"; _host="${_host%.*}"
  fi
  [ -n "$_host" ] \
    && auth_str="${DIM}·${RST}${YEL}API${DIM}@${RST}${YEL}${_host}${RST}" \
    || auth_str="${DIM}·${RST}${YEL}API${RST}"
else
  auth_str="${DIM}·${RST}${GRN}Max${RST}"
fi

# ── Vim mode ───────────────────────────────────────────
vim_str=""; [ -n "$VIM_MODE" ] && vim_str=" ${DIM}[${VIM_MODE}]${RST}"

# ── Session duration ───────────────────────────────────
ds=$(( ${DUR_MS:-0} / 1000 ))
dh=$(( ds / 3600 )); dm=$(( (ds % 3600) / 60 )); dse=$(( ds % 60 ))
if [ "$dh" -gt 0 ]; then dur="${dh}h${dm}m"
elif [ "$dse" -gt 0 ]; then dur="${dm}m${dse}s"
else dur="${dm}m"; fi

# ── Format cost and CWD ───────────────────────────────
cost_f=$(printf "%.2f" "${SESS_COST:-0}")
short_cwd="${CWD/#$HOME/~}"

# ── Token metrics (60s cache, reads local JSONL files) ──
tok_cache="/tmp/sl-tok-cache"
day_tok=0; nc_in=0; nc_out=0; sc_cr=0; sc_cw=0
if [ ! -f "$tok_cache" ] || [ $(( now - $(stat -f %m "$tok_cache" 2>/dev/null || echo 0) )) -gt 60 ]; then
  _ds=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
  _de=$((_ds + 86400))
  find ~/.claude/projects -name "*.jsonl" -newermt "$(date +%Y-%m-%d)" \
    -exec grep -h '"type":"assistant"' {} + 2>/dev/null | \
    jq -s --argjson s "$_ds" --argjson e "$_de" --arg sid "${SESS_ID:-}" '
      [ .[] | select(.message.usage) |
        select((.timestamp | split(".")[0] + "Z" | fromdateiso8601) >= $s and
               (.timestamp | split(".")[0] + "Z" | fromdateiso8601) < $e) ] |
      unique_by(.requestId // (.sessionId + ":" + .timestamp + ":" + (.message.usage.input_tokens|tostring))) |
      # D: daily non-cache total
      (map((.message.usage.input_tokens // 0) + (.message.usage.output_tokens // 0)) | add // 0) as $day |
      # i:/o: current session non-cache
      (if $sid != "" then [.[] | select(.sessionId == $sid)] else [] end) as $sess |
      ($sess | map(.message.usage.input_tokens // 0) | add // 0) as $sin |
      ($sess | map(.message.usage.output_tokens // 0) | add // 0) as $sout |
      ($sess | map(.message.usage.cache_read_input_tokens // 0) | add // 0) as $scr |
      ($sess | map(.message.usage.cache_creation_input_tokens // 0) | add // 0) as $scw |
      $day, $sin, $sout, $scr, $scw
    ' > "$tok_cache" 2>/dev/null
fi
if [ -f "$tok_cache" ]; then
  { read day_tok; read nc_in; read nc_out; read sc_cr; read sc_cw; } < "$tok_cache" 2>/dev/null
fi
day_tok=${day_tok:-0}; nc_in=${nc_in:-0}; nc_out=${nc_out:-0}; sc_cr=${sc_cr:-0}; sc_cw=${sc_cw:-0}

# ── Humanize token numbers (single awk call) ──────────
read tok_day tok_in tok_out tok_cr tok_cw <<< $(echo "$day_tok $nc_in $nc_out $sc_cr $sc_cw" | awk '{
  for(i=1;i<=NF;i++) {
    v=$i+0
    if(v>=1e9) printf "%.1fB ",v/1e9
    else if(v>=1e6) printf "%.1fM ",v/1e6
    else if(v>=1e3) printf "%.0fk ",v/1e3
    else printf "%d ",v
  }
}')
tok_str="${DIM}D:${RST}${tok_day} ${DIM}i:${RST}${tok_in}${DIM}/o:${RST}${tok_out}"
[ "${sc_cr:-0}" -gt 0 ] 2>/dev/null && tok_str="${tok_str} ${DIM}cR:${RST}${tok_cr}"
[ "${sc_cw:-0}" -gt 0 ] 2>/dev/null && tok_str="${tok_str} ${DIM}cW:${RST}${tok_cw}"

# ── 5h billing block (optional, 30s cache) ─────────────
billing=$("$(dirname "$0")/ccusage-widget.sh" 2>/dev/null)

# ── Output ─────────────────────────────────────────────
echo -e "${CYN}${BOLD}${MODEL}${RST}${auth_str} ${bar_c}${bar} ${pct}%${RST}/${ctx_lbl} |${git_str}${vim_str}"
[ -n "$billing" ] && echo -e "$billing"
echo -e "${DIM}\$${cost_f}${RST} ${tok_str} ${DIM}|${RST} ${dur} ${DIM}|${RST} ${GRN}+${LINES_ADD}${RST}/${RED}-${LINES_DEL}${RST} ${DIM}|${RST} ${short_cwd}"
