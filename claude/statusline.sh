#!/usr/bin/env bash
# ~/.claude/statusline.sh — custom Claude Code status line (colored).
#
# Reads the Status JSON on stdin (https://code.claude.com/docs/en/statusline.md).
# Layout:
#   Claude | Ctx: 18.6k (11.6%) - 2hr 15m - 31k tokens - 25.6k cache | 5h: 20.0% (4h30m) - w: 12.0% (36h30m)    repo - branch - sha (+42,-10)
#
# - model name only (no "Model:"); shows "1m" when on a 1M-context model.
# - "tokens" = cumulative session input+output (cache excluded), from transcript.
# - "cache"  = cache-hit tokens of the latest turn (count, not %).
# - Ctx color: 4 bands at 30/50/70.
# - 5h / weekly color: burn-rate projection (green/yellow/red, see crate()).
# - git block flush-right; drops to its own right-aligned line if too narrow.
set -euo pipefail

input="$(cat)"

# --- ANSI ----------------------------------------------------------------
R=$'\033[0m'; B=$'\033[1m'
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; ORG=$'\033[38;5;208m'
MAG=$'\033[35m'; CYN=$'\033[36m'; GRY=$'\033[90m'; LGY=$'\033[38;5;250m'

# 4-band lower-is-better color at t1<t2<t3
cband(){ awk -v v="${1:-0}" -v t1="$2" -v t2="$3" -v t3="$4" -v g="$GRN" -v y="$YEL" -v o="$ORG" -v r="$RED" \
  'BEGIN{ if(v<t1)printf g; else if(v<t2)printf y; else if(v<t3)printf o; else printf r }'; }
# 3-band lower-is-better color at lo<hi
c3(){ awk -v v="${1:-0}" -v lo="$2" -v hi="$3" -v g="$GRN" -v y="$YEL" -v r="$RED" \
  'BEGIN{ if(v<lo)printf g; else if(v<hi)printf y; else printf r }'; }

# rate-limit color by burn-rate projection.
#   args: used_pct  secs_remaining  window_len_secs
#   green : projected end-of-window usage < 100% (limit never reached)
#   yellow: limit reached, but only after 80% of the window has elapsed
#   red   : limit reached before 80% of the window (at current burn rate)
crate(){ awk -v u="${1:-0}" -v rem="${2:-0}" -v wl="${3:-1}" -v g="$GRN" -v y="$YEL" -v r="$RED" 'BEGIN{
  if(u<=0){printf g; exit}
  el=wl-rem; if(el<=0)el=1; ef=el/wl; if(ef<=0)ef=0.0001;
  proj=u/ef;
  if(proj<100){printf g; exit}
  fal=ef*(100/u);            # window-fraction at which 100% is hit
  if(fal>=0.8)printf y; else printf r;
}'; }

# visible length (strip ANSI)
vlen(){ local s; s=$(printf '%s' "$1" | sed -E "s/$(printf '\033')\[[0-9;]*m//g"); printf '%s' "${#s}"; }

# --- formatters ----------------------------------------------------------
hum(){ awk -v n="${1:-0}" 'BEGIN{ if(n>=1000000)printf "%.1fM",n/1000000; else if(n>=1000)printf "%.1fk",n/1000; else printf "%d",n }'; }
dur_ms(){ awk -v ms="${1:-0}" 'BEGIN{ s=int(ms/1000);h=int(s/3600);m=int((s%3600)/60);sec=s%60; if(h>0)printf "%dh%02d",h,m; else if(m>0)printf "%dm",m; else printf "%ds",sec }'; }
until_hm(){ awk -v s="${1:-0}" 'BEGIN{ if(s<0)s=0;h=int(s/3600);m=int((s%3600)/60); if(h>0)printf "%dh%02d",h,m; else printf "%dm",m }'; }

now=$(date +%s)
W5=18000      # 5h window in seconds
W7=604800     # 7d window in seconds

# --- parse ---------------------------------------------------------------
model=$(jq -r '.model.display_name // "Claude"' <<<"$input")
model_id=$(jq -r '.model.id // ""' <<<"$input")
ctx_size=$(jq -r '.context_window.context_window_size // 0' <<<"$input")
ctx_in=$(jq -r '.context_window.total_input_tokens // 0' <<<"$input")
ctx_pct=$(jq -r '.context_window.used_percentage // 0' <<<"$input")
dur=$(jq -r '.cost.total_duration_ms // 0' <<<"$input")
u_cr=$(jq -r '.context_window.current_usage.cache_read_input_tokens // 0' <<<"$input")

# strip any "(... context)" parenthetical from the display name
model_clean=$(printf '%s' "$model" | sed -E 's/ *\([^)]*context[^)]*\)//Ig' | sed -E 's/ +$//')

# 1M-context model -> append " 1M" after the cleaned name
if printf '%s' "$model_id" | grep -qi '\[1m\]' \
   || printf '%s' "$model" | grep -qi '1m context' \
   || { [ "$ctx_size" -ge 1000000 ] 2>/dev/null; }; then
  model_disp="$model_clean 1M"
else
  model_disp="$model_clean"
fi

# cumulative session tokens, input+output only (cache excluded), from transcript
tx=$(jq -r '.transcript_path // empty' <<<"$input")
total_tokens=0
if [ -n "$tx" ] && [ -f "$tx" ]; then
  total_tokens=$(jq -s '[.[] | select(.type=="assistant") | .message.usage]
    | map((.input_tokens // 0)+(.output_tokens // 0)) | add // 0' "$tx" 2>/dev/null || echo 0)
fi

# rate limits (Pro/Max only)
rl5_pct=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<<"$input")
rl5_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty' <<<"$input")
rl7_pct=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$input")
rl7_reset=$(jq -r '.rate_limits.seven_day.resets_at // empty' <<<"$input")

# --- build left block (colored) ------------------------------------------
ctx_c=$(cband "$ctx_pct" 30 50 70)

seg_model="${B}${GRY}${model_disp}${R}"
seg_ctx="Ctx: ${ctx_c}$(hum "$ctx_in") ($(printf '%.1f' "$ctx_pct")%)${R}"
seg_dur="${GRY}$(dur_ms "$dur")${R}"
tok_c=$(c3 "$total_tokens" 4000000 8000000)   # green <4M, yellow <8M, red >=8M
seg_tok="${tok_c}$(hum "$total_tokens")${R} tokens"
seg_cache="${GRN}$(hum "$u_cr")${R} cache"

if [ -n "$rl5_pct" ]; then
  c=$(crate "$rl5_pct" $(( rl5_reset - now )) "$W5")
  seg_rl5="5h: ${c}$(printf '%.1f' "$rl5_pct")% ($(until_hm $(( rl5_reset - now ))))${R}"
else seg_rl5="${GRY}5h: n/a${R}"; fi
if [ -n "$rl7_pct" ]; then
  c=$(crate "$rl7_pct" $(( rl7_reset - now )) "$W7")
  seg_rl7="w: ${c}$(printf '%.1f' "$rl7_pct")% ($(until_hm $(( rl7_reset - now ))))${R}"
else seg_rl7="${GRY}w: n/a${R}"; fi

left="${seg_model} ${GRY}|${R} ${seg_ctx} ${GRY}-${R} ${seg_dur} ${GRY}-${R} ${seg_tok} ${GRY}-${R} ${seg_cache} ${GRY}|${R} ${seg_rl5} ${GRY}-${R} ${seg_rl7}"

# --- build right block (git) ---------------------------------------------
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")
right=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo=$(jq -r '.workspace.repo.name // empty' <<<"$input")
  [ -z "$repo" ] && repo=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  diffstat=$(git -C "$cwd" diff HEAD --numstat 2>/dev/null | awk '{ if($1~/^[0-9]+$/)a+=$1; if($2~/^[0-9]+$/)r+=$2 } END{ printf "%d %d",a+0,r+0 }')
  added=${diffstat% *}; removed=${diffstat#* }
  # everything light-gray; +/- counters green/red only when non-zero
  ac="$LGY"; { [ "${added:-0}" -gt 0 ] 2>/dev/null; } && ac="$GRN"
  rc="$LGY"; { [ "${removed:-0}" -gt 0 ] 2>/dev/null; } && rc="$RED"
  right="${LGY}${repo}:${branch} (${ac}+${added}${LGY},${rc}-${removed}${LGY})${R}"
fi

# --- compose with right-alignment (newline fallback) ---------------------
# Target cols-1, never cols: filling the terminal's last column triggers
# auto-margin wrap / ellipsis truncation, which clips the right (git) block.
cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
avail=$(( cols - 3 )); [ "$avail" -lt 1 ] && avail=1
if [ -z "$right" ]; then
  out="$left"; path="left-only"
else
  lv=$(vlen "$left"); rv=$(vlen "$right")
  if [ $(( lv + 2 + rv )) -le "$avail" ]; then
    pad=$(( avail - lv - rv ))
    out="$(printf '%s%*s%s' "$left" "$pad" "" "$right")"; path="single"
  else
    pad=$(( avail - rv )); [ "$pad" -lt 0 ] && pad=0
    out="$(printf '%s\n%*s%s' "$left" "$pad" "" "$right")"; path="newline"
  fi
fi
# DEBUG TEMP
{ printf 'cols=%s avail=%s lv=%s rv=%s path=%s outlen=%s\n' \
    "$cols" "$avail" "${lv:-0}" "${rv:-0}" "$path" \
    "$(vlen "$(printf '%s' "$out" | head -1)")"; } >>/tmp/sl_debug.log 2>&1
printf '%s' "$out"
