#!/usr/bin/env bash
# workstation_setup — updater. Pulls the latest workstation and rebuilds ONLY what changed
# (skips the build entirely when nothing image-related changed). The host stays untouched.
#
#   <workspace>/.workstation/update.sh
#   curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/update.sh | bash
#
# Flags:
#   --dir  <path>  (WORKSTATION_DIR)   where the workstation lives  [auto-detected from ~/.bashrc, else ~/dev/.workstation]
#   --home <path>  (WORKSTATION_HOME)  workspace root               [default ~/dev]
#   --fresh                            force a from-scratch base rebuild (--pull --no-cache) to pull the
#                                      latest Claude/Serena/rtk, even if the repo didn't change
#   --yes | -y                         non-interactive
# Execute this, don't source it (it uses set -e/exit). If sourced, bail out safely before set -e.
if (return 0 2>/dev/null); then echo "Don't 'source' update.sh — run it as a script." >&2; return 1; fi
set -euo pipefail

WS_DIR="${WORKSTATION_DIR:-}"
WS_HOME="${WORKSTATION_HOME:-$HOME/dev}"
FRESH=0; ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    WS_DIR="${2:?--dir requires a path}";   WS_DIR="${WS_DIR/#\~/$HOME}";   shift 2 ;;
    --home)   WS_HOME="${2:?--home requires a path}"; WS_HOME="${WS_HOME/#\~/$HOME}"; shift 2 ;;
    --fresh)  FRESH=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --dir / --home / --fresh / --yes)"; exit 1 ;;
  esac
done

# Auto-detect the workstation dir from the ~/.bashrc block if not given.
if [ -z "$WS_DIR" ] && [ -f "$HOME/.bashrc" ]; then
  WS_DIR="$(sed -n 's/^export WORKSTATION_DIR="\(.*\)"$/\1/p' "$HOME/.bashrc" | tail -1)"
fi
WS_DIR="${WS_DIR:-$WS_HOME/.workstation}"

log(){  printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
dock(){ if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }
[ -d "$WS_DIR/.git" ] || { echo "update: no workstation clone at $WS_DIR (pass --dir)"; exit 1; }

log "pull latest workstation ($WS_DIR)"
before="$(git -C "$WS_DIR" rev-parse HEAD 2>/dev/null || echo '')"
git -C "$WS_DIR" pull --ff-only
after="$(git -C "$WS_DIR" rev-parse HEAD 2>/dev/null || echo '')"
changed="$(git -C "$WS_DIR" diff --name-only "$before" "$after" 2>/dev/null || true)"

# Decide what to rebuild from what the pull actually changed (so we don't build for nothing).
needs_base=0; needs_thin=0; task_changed=0
while IFS= read -r f; do [ -z "$f" ] && continue
  case "$f" in
    Dockerfile.base)                     needs_base=1 ;;                 # toolchain layer
    Dockerfile|claude/*|dev/*|plugins/*) needs_thin=1 ;;                 # config / plugins layer
    shell/task.sh)                       task_changed=1 ;;               # shell function (no rebuild)
  esac
done <<< "$changed"
dock image inspect workstation-base >/dev/null 2>&1 || needs_base=1      # missing → must build
dock image inspect workstation      >/dev/null 2>&1 || needs_thin=1
[ "$FRESH" = 1 ] && needs_base=1
[ "$needs_base" = 1 ] && needs_thin=1                                    # base change ⇒ thin too

# Keep the baked language + selected plugins across the rebuild.
lang=""; dock image inspect workstation >/dev/null 2>&1 && \
  lang="$(dock run --rm workstation jq -r '.language // empty' /home/dev/.claude/settings.json 2>/dev/null || true)"
plugins="$(cat "$WS_DIR/.plugins" 2>/dev/null || true)"

if [ "$needs_base" = 0 ] && [ "$needs_thin" = 0 ]; then
  log "image — already up to date (nothing relevant changed; build skipped)"
else
  if [ "$needs_base" = 1 ]; then
    if [ "$FRESH" = 1 ]; then
      log "rebuild base — FRESH (--pull --no-cache → latest Claude/Serena/rtk)"
      dock build --pull --no-cache -f "$WS_DIR/Dockerfile.base" -t workstation-base "$WS_DIR"
    else
      log "rebuild base 'workstation-base' (changed; cached layers reused where possible)"
      dock build -f "$WS_DIR/Dockerfile.base" -t workstation-base "$WS_DIR"
    fi
  fi
  log "rebuild 'workstation' (config + plugins, on top of the base)"
  dock build --build-arg "WS_LANG=$lang" --build-arg "WS_PLUGINS=$plugins" -t workstation "$WS_DIR"
  if dock run --rm workstation test -f /home/dev/.claude/.audio-needed >/dev/null 2>&1; then : > "$WS_DIR/.audio"; else rm -f "$WS_DIR/.audio"; fi
fi

log "done"
echo "✓ Updated."
# 'task' is sourced from the clone; a child script can't reload it into your current shell.
if [ "$task_changed" = 1 ]; then
  echo "  'task' changed — load it into THIS shell:  source ~/.bashrc   (or open a new terminal)"
else
  echo "  If you want the latest 'task' in this shell:  source ~/.bashrc   (or open a new terminal)"
fi
