#!/usr/bin/env bash
# Notification hook — runs INSIDE the task container. Fires when Claude needs you (a permission prompt,
# or it has been idle waiting for input). If you've been AWAY for >= WS_WHATSAPP_IDLE seconds (the shared
# machine-wide presence stamp), it drops a small JSON request into the shared /outbox; the host-side
# `ws-whatsapp-bridge` container picks it up and sends it to your dedicated group. While you're present
# (recent interaction with ANY task), it stays silent — that's the anti-spam rule.
#
# No-op unless WhatsApp notify is enabled for this task. Always exits 0 — never blocks Claude.
[ "${WS_NOTIFY_WHATSAPP:-0}" = 1 ] || exit 0
d=/ws-whatsapp
out="$d/outbox"
[ -d "$d" ] || exit 0

payload="$(cat 2>/dev/null)"          # Claude's Notification JSON on stdin
threshold="${WS_WHATSAPP_IDLE:-300}"

now="$(date +%s 2>/dev/null)" || exit 0
last="$(cat "$d/presence" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
# present within the window (interacted anywhere recently) → stay quiet
[ "$((now - last))" -lt "$threshold" ] && exit 0

# Pull a few fields from the JSON (jq is in the image). Skip notifications that aren't "needs you".
get(){ printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }
ntype="$(get '.notification_type')"; [ -z "$ntype" ] && ntype="$(get '.hook_event_name')"
case "$ntype" in auth_success|elicitation_complete|elicitation_response) exit 0 ;; esac
msg="$(get '.message')"; sid="$(get '.session_id')"; cwd="$(get '.cwd')"
title="${WORKSTATION_TAB_TITLE:-}"; [ -z "$title" ] && title="$(basename "${cwd:-/work}")"

mkdir -p "$out" 2>/dev/null || exit 0
stamp="$(date +%s%N 2>/dev/null)"; [ -z "$stamp" ] && stamp="$now"
tmp="$out/.${stamp}.$$.tmp"
if jq -cn --arg t "$title" --arg m "$msg" --arg s "$sid" --arg c "$cwd" --arg n "$ntype" --argjson ts "$now" \
      '{title:$t,message:$m,session_id:$s,cwd:$c,type:$n,ts:$ts}' > "$tmp" 2>/dev/null; then
  mv "$tmp" "$out/${stamp}.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi
exit 0
