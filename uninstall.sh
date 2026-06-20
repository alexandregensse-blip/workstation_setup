#!/usr/bin/env bash
# workstation_setup — uninstaller. Container-only model: the host was barely touched, so
# this removes a SMALL, well-defined footprint and asks POINT-BY-POINT before each change.
#
#   <workspace>/.workstation/uninstall.sh          # from the clone
#   curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/uninstall.sh | bash
#
# It can remove, one confirmation at a time: the 'task' block in ~/.bashrc, the 'workstation'
# Docker image, the apt packages WE installed (docker/git/gh — only those, read from
# .apt-installed), your docker-group membership (only if WE added it), and the
# <workspace>/.workstation dir (clone + Claude credentials). Nothing else exists on the host
# (Claude/Serena/rtk live only in the image — ~/.claude was never written).
#
# Flags:
#   --dir  <path>  (WORKSTATION_DIR)   where the workstation lives  [auto-detected from ~/.bashrc, else ~/dev/.workstation]
#   --home <path>  (WORKSTATION_HOME)  workspace root               [default ~/dev]
#   --yes | -y                         assume yes to every prompt (non-interactive)
set -euo pipefail

WS_DIR="${WORKSTATION_DIR:-}"
WS_HOME="${WORKSTATION_HOME:-$HOME/dev}"
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    WS_DIR="${2:?--dir requires a path}";   WS_DIR="${WS_DIR/#\~/$HOME}";   shift 2 ;;
    --home)   WS_HOME="${2:?--home requires a path}"; WS_HOME="${WS_HOME/#\~/$HOME}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --dir / --home / --yes)"; exit 1 ;;
  esac
done

# Auto-detect the workstation dir from the ~/.bashrc block if not given.
if [ -z "$WS_DIR" ] && [ -f "$HOME/.bashrc" ]; then
  WS_DIR="$(sed -n 's/^export WORKSTATION_DIR="\(.*\)"$/\1/p' "$HOME/.bashrc" | tail -1)"
fi
WS_DIR="${WS_DIR:-$WS_HOME/.workstation}"

log(){  printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
dock(){ if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }
# fixed-width box, padded by character count (UTF-8) so the right edge never overflows
banner(){ local msg="  ✓  $1" w=46 line='' pad; while [ "${#line}" -lt "$w" ]; do line+='═'; done
  pad=$(( w - ${#msg} )); [ "$pad" -lt 0 ] && pad=0
  printf '╔%s╗\n║%s%*s║\n╚%s╝\n' "$line" "$msg" "$pad" '' "$line"; }
confirm(){
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -r /dev/tty ] || return 1
  printf '%s [y/N]: ' "$1"; local a; read -r a < /dev/tty || a=n
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

echo
echo "Uninstalling workstation — I'll ask before each removal."
echo "  workstation dir: $WS_DIR"

# 1. ~/.bashrc 'task' block
if [ -f "$HOME/.bashrc" ] && grep -q '# >>> workstation >>>' "$HOME/.bashrc"; then
  log "task command in ~/.bashrc"
  if confirm "Remove the 'task' block from ~/.bashrc?"; then
    sed -i '/# >>> workstation >>>/,/# <<< workstation <<</d' "$HOME/.bashrc"; echo "  removed"
  else echo "  kept"; fi
fi

# 2. Docker image
if dock image inspect workstation >/dev/null 2>&1; then
  log "docker image 'workstation'"
  if confirm "Remove the Docker image 'workstation'?"; then
    dock rmi -f workstation >/dev/null 2>&1 && echo "  removed"
  else echo "  kept"; fi
fi

# 3. apt packages WE installed (point-by-point, read before the dir is deleted)
manifest="$WS_DIR/.apt-installed"
if [ -f "$manifest" ]; then
  log "apt packages installed by workstation"
  for pkg in $(sort -u "$manifest"); do
    dpkg -s "$pkg" >/dev/null 2>&1 || continue
    if confirm "apt remove '$pkg'? (we installed it)"; then sudo apt remove -y "$pkg" || true
    else echo "  kept $pkg"; fi
  done
fi

# 4. docker group membership (only if WE added it)
if [ -f "$WS_DIR/.docker-group-added" ] && getent group docker | grep -qw "$(id -un)"; then
  log "docker group membership"
  if confirm "Remove yourself from the 'docker' group? (we added you; needs re-login)"; then
    sudo gpasswd -d "$USER" docker >/dev/null 2>&1 && echo "  removed (re-login to apply)"
  else echo "  kept"; fi
fi

# 5. the workstation dir itself (clone + Claude credentials + manifest) — LAST
if [ -d "$WS_DIR" ]; then
  log "workstation dir"
  if confirm "Delete $WS_DIR? (clone + Claude credentials stored there)"; then
    rm -rf "$WS_DIR"; echo "  removed"
  else echo "  kept"; fi
fi

echo
banner "Workstation uninstall finished"
cat <<EOF

Never touched (nothing to undo): ~/.claude, your gh login, and any tool you already had.
Your task clones under $WS_HOME were left in place.
Open a new terminal so 'task' disappears from your shell.
EOF
