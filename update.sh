#!/usr/bin/env bash
# workstation_setup — updater. Pulls the latest workstation and rebuilds the image, so you get
# the newest workstation changes AND the latest Claude/Serena/rtk. The host stays untouched.
#
#   <workspace>/.workstation/update.sh
#   curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/update.sh | bash
#
# Flags:
#   --dir  <path>  (WORKSTATION_DIR)   where the workstation lives  [auto-detected from ~/.bashrc, else ~/dev/.workstation]
#   --home <path>  (WORKSTATION_HOME)  workspace root               [default ~/dev]
#   --fast                             reuse the Docker layer cache (apply repo changes only; don't re-fetch tools)
#   --yes | -y                         non-interactive
set -euo pipefail

WS_DIR="${WORKSTATION_DIR:-}"
WS_HOME="${WORKSTATION_HOME:-$HOME/dev}"
FAST=0; ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    WS_DIR="${2:?--dir requires a path}";   WS_DIR="${WS_DIR/#\~/$HOME}";   shift 2 ;;
    --home)   WS_HOME="${2:?--home requires a path}"; WS_HOME="${WS_HOME/#\~/$HOME}"; shift 2 ;;
    --fast)   FAST=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --dir / --home / --fast / --yes)"; exit 1 ;;
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
git -C "$WS_DIR" pull --ff-only

# rebuild with the SAME language + plugins that are baked in the current image
lang="$(dock run --rm workstation jq -r '.language // empty' /home/dev/.claude/settings.json 2>/dev/null || true)"
plugins="$(cat "$WS_DIR/.plugins" 2>/dev/null || true)"
[ -n "$plugins" ] && echo "  keeping plugins: $plugins"
[ -n "$lang" ]    && echo "  keeping language: $lang"

if [ "$FAST" = 1 ]; then
  log "rebuild 'workstation' (fast: reuse base + cache — repo changes only)"
  dock build --build-arg "WS_LANG=$lang" --build-arg "WS_PLUGINS=$plugins" -t workstation "$WS_DIR"
else
  log "rebuild base 'workstation-base' (fresh: --pull --no-cache → latest Claude/Serena/rtk)"
  dock build --pull --no-cache -f "$WS_DIR/Dockerfile.base" -t workstation-base "$WS_DIR"
  log "rebuild 'workstation' (config + plugins, on top of the base)"
  dock build --build-arg "WS_LANG=$lang" --build-arg "WS_PLUGINS=$plugins" -t workstation "$WS_DIR"
fi

# refresh the host-side audio marker (plugins/image may have changed)
if dock run --rm workstation test -f /home/dev/.claude/.audio-needed >/dev/null 2>&1; then : > "$WS_DIR/.audio"; else rm -f "$WS_DIR/.audio"; fi

log "done"
echo "✓ Updated. 'task' is sourced from the clone, so a new terminal picks up any shell changes."
