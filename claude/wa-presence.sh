#!/usr/bin/env bash
# UserPromptSubmit hook — runs INSIDE the task container. Records "the user is present right now" so the
# WhatsApp notifier stays silent while you're actively driving a task. Debounce is MACHINE-WIDE: every
# WhatsApp-enabled task writes the SAME shared presence file (bind-mounted from the host at /ws-whatsapp),
# so interacting with any task counts as "I'm at the keyboard". No-op unless WhatsApp notify is enabled
# for this task (so non-WhatsApp tasks are untouched). Always exits 0 — a hook must never block Claude.
[ "${WS_NOTIFY_WHATSAPP:-0}" = 1 ] || exit 0
d=/ws-whatsapp
[ -d "$d" ] || exit 0
date +%s > "$d/presence" 2>/dev/null || true
exit 0
