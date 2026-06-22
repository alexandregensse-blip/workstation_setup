# shellcheck shell=bash
# Shared one-line build progress meter, used by the toolchain build (task.sh) and the image rebuild
# (update.sh). Distilled from install.sh's build_phase (no checklist, no calibration). The meter is
# written to STDERR (so a captured stdout — e.g. task.sh capturing the image name — stays clean) and
# only drawn on a real terminal; otherwise it's a no-op and the build output stays in the caller's log.

_ws_human_size(){ local b="${1:-0}"
  if   [ "$b" -ge 1048576 ]; then echo "$((b/1048576)) MB"
  elif [ "$b" -ge 1024 ];    then echo "$((b/1024)) KB"
  else echo "${b} B"; fi; }
_ws_human_rate(){ local b="${1:-0}"
  if   [ "$b" -ge 1048576 ]; then echo "$((b/1048576)) MB/s"
  elif [ "$b" -ge 1024 ];    then echo "$((b/1024)) KB/s"
  else echo "${b} B/s"; fi; }

# Show a live meter for a running build until <pid> exits, then return the build's exit code.
#   _ws_build_meter <logfile> <pid> [prefix]
# Line (redrawn in place):  <prefix>Step N/M · ↓ <downloaded> · <rate> · <Xs>
# 'downloaded' is the host docker0 tx delta (bytes pushed into containers ≈ the build's downloads);
# when that counter isn't readable it falls back to a plain "building · <Xs>" heartbeat.
_ws_build_meter(){
  local log="$1" pid="$2" prefix="${3:-  }"
  if ! [ -t 2 ]; then wait "$pid" 2>/dev/null; return $?; fi      # no terminal → no meter (log kept)
  local ctr tx0 tx1 rate total=0 t0 cur det
  ctr="/sys/class/net/docker0/statistics/tx_bytes"; [ -r "$ctr" ] || ctr=""
  tx0="$( { [ -n "$ctr" ] && cat "$ctr"; } 2>/dev/null || echo 0)"
  t0=$SECONDS
  printf '\033[?25l' >&2                                          # hide cursor
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if [ -n "$ctr" ]; then tx1="$(cat "$ctr" 2>/dev/null || echo 0)"; rate=$(( tx1 - tx0 )); [ "$rate" -lt 0 ] && rate=0; tx0="$tx1"; total=$(( total + rate )); fi
    cur="$(grep -aoE '^Step [0-9]+/[0-9]+' "$log" 2>/dev/null | tail -1)"
    if [ -n "$ctr" ]; then det="${cur:-building} · ↓ $(_ws_human_size "$total") · $(_ws_human_rate "$rate") · $((SECONDS-t0))s"
    else det="${cur:-building} · $((SECONDS-t0))s"; fi
    printf '\r\033[K\033[2m%s%s\033[0m' "$prefix" "$det" >&2
  done
  printf '\r\033[K\033[?25h' >&2                                  # clear line, restore cursor
  wait "$pid" 2>/dev/null
}
