#!/usr/bin/env bash
# workstation_setup — uninstaller. Container-only model: the host was barely touched, so
# this removes a SMALL, well-defined footprint and asks POINT-BY-POINT before each change.
#
#   <workspace>/.workstation/uninstall.sh          # from the clone
#   curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/uninstall.sh | bash
#
# It can remove, one confirmation at a time: the 'task' block in ~/.bashrc, the 'workstation'
# Docker image, the apt packages WE installed (docker/git/gh — only those, read from
# .apt-installed), your docker-group membership (only if WE added it), your task clones under
# 'running' (git-scanned first — it tells you which clones still have unpushed/uncommitted work),
# and the <workspace>/.workstation dir. Nothing else exists on the host (~/.claude was never written).
# At the end it prints a recap of what was removed vs kept.
#
# Flags:
#   --dir  <path>  (WORKSTATION_DIR)   where the workstation lives  [auto-detected from ~/.bashrc, else ~/dev/.workstation]
#   --home <path>  (WORKSTATION_HOME)  workspace root               [default ~/dev]
#   --yes | -y                         assume yes to every prompt (non-interactive)
# Execute this, don't source it (it uses set -e/exit). If sourced, bail out safely before set -e.
if (return 0 2>/dev/null); then echo "Don't 'source' uninstall.sh — run it as a script." >&2; return 1; fi
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

# Auto-detect the workstation dir and the running (task clones) dir from the ~/.bashrc block.
detect(){ sed -n "s/^export $1=\"\\(.*\\)\"\$/\\1/p" "$HOME/.bashrc" 2>/dev/null | tail -1; }
[ -z "$WS_DIR" ] && WS_DIR="$(detect WORKSTATION_DIR)"
WS_DIR="${WS_DIR:-$WS_HOME/.workstation}"
WS_RUNNING="${WORKSTATION_RUNNING:-$(detect WORKSTATION_RUNNING)}"
WS_RUNNING="${WS_RUNNING:-$WS_HOME/running}"

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
REMOVED=""; KEPT=""
note_removed(){ REMOVED="${REMOVED}  • $1"$'\n'; }
note_kept(){    KEPT="${KEPT}  • $1"$'\n'; }

echo
echo "Uninstalling workstation — I'll ask before each removal."
echo "  workstation dir: $WS_DIR"

# 1. ~/.bashrc 'task' block
if [ -f "$HOME/.bashrc" ] && grep -q '# >>> workstation >>>' "$HOME/.bashrc"; then
  log "task command in ~/.bashrc"
  if confirm "Remove the 'task' block from ~/.bashrc?"; then
    sed -i '/# >>> workstation >>>/,/# <<< workstation <<</d' "$HOME/.bashrc"; echo "  removed"; note_removed "'task' block in ~/.bashrc"
  else echo "  kept"; note_kept "'task' block in ~/.bashrc"; fi
fi

# 2. Docker images (the thin image and the toolchain base)
for img in workstation workstation-base; do
  if dock image inspect "$img" >/dev/null 2>&1; then
    log "docker image '$img'"
    if confirm "Remove the Docker image '$img'?"; then
      if dock rmi -f "$img" >/dev/null 2>&1; then echo "  removed"; note_removed "Docker image '$img'"; else echo "  (in use / already gone)"; fi
    else echo "  kept"; note_kept "Docker image '$img'"; fi
  fi
done

# 3. apt packages WE installed (point-by-point, read before the dir is deleted)
manifest="$WS_DIR/.apt-installed"
if [ -f "$manifest" ]; then
  log "apt packages installed by workstation"
  for pkg in $(sort -u "$manifest"); do
    dpkg -s "$pkg" >/dev/null 2>&1 || continue
    if confirm "apt remove '$pkg'? (we installed it)"; then sudo apt remove -y "$pkg" || true; note_removed "apt: $pkg"
    else echo "  kept $pkg"; note_kept "apt: $pkg"; fi
  done
fi

# 4. docker group membership (only if WE added it)
if [ -f "$WS_DIR/.docker-group-added" ] && getent group docker | grep -qw "$(id -un)"; then
  log "docker group membership"
  if confirm "Remove yourself from the 'docker' group? (we added you; needs re-login)"; then
    sudo gpasswd -d "$USER" docker >/dev/null 2>&1 && echo "  removed (re-login to apply)"; note_removed "docker-group membership"
  else echo "  kept"; note_kept "docker-group membership"; fi
fi

# 4b. docker IPv6 daemon.json — only if WE created it (marker), and only the file we wrote
if [ -f "$WS_DIR/.docker-ipv6" ] && [ -f /etc/docker/daemon.json ]; then
  log "docker IPv6 config (/etc/docker/daemon.json)"
  if confirm "Remove /etc/docker/daemon.json that we created for IPv6? (restarts docker)"; then
    sudo rm -f /etc/docker/daemon.json && { sudo systemctl restart docker 2>/dev/null || true; }
    echo "  removed (docker restarted)"; note_removed "docker IPv6 daemon.json"
  else echo "  kept"; note_kept "docker IPv6 daemon.json"; fi
fi

# 5. the running task clones — scan git first; warn only about REAL unpushed/uncommitted work
if [ -d "$WS_RUNNING" ] && [ -n "$(ls -A "$WS_RUNNING" 2>/dev/null)" ]; then
  log "task clones ($WS_RUNNING)"
  risky=""
  while IFS= read -r gitdir; do
    d="${gitdir%/.git}"; tag=""
    [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && tag="uncommitted"
    [ -n "$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && tag="${tag:+$tag, }unpushed"
    [ -n "$tag" ] && risky="${risky}    - ${d#"$WS_RUNNING"/}  ($tag)"$'\n'
  done < <(find "$WS_RUNNING" -mindepth 1 -maxdepth 3 -type d -name .git 2>/dev/null)
  if [ -n "$risky" ]; then
    printf '  ⚠ these clones have work NOT on the remote (deleting loses it):\n%s' "$risky"
  else
    echo "  ✓ all task clones are clean and fully pushed — safe to delete."
  fi
  if confirm "Delete ALL task clones under $WS_RUNNING?"; then
    rm -rf "$WS_RUNNING"; echo "  removed"; note_removed "task clones ($WS_RUNNING)"
  else echo "  kept (delete manually if you want)"; note_kept "task clones ($WS_RUNNING)"; fi
fi

# 6. the workstation dir itself (clone + Claude credentials + manifest) — LAST
if [ -d "$WS_DIR" ]; then
  log "workstation dir"
  if confirm "Delete $WS_DIR? (clone + Claude credentials stored there)"; then
    rm -rf "$WS_DIR"; echo "  removed"; note_removed "$WS_DIR (clone + credentials)"
  else echo "  kept"; note_kept "$WS_DIR (clone + credentials)"; fi
fi

echo
banner "Workstation uninstall finished"
echo
echo "Removed:";  [ -n "$REMOVED" ] && printf '%s' "$REMOVED" || echo "  • (nothing)"
echo "Kept:";     [ -n "$KEPT" ]    && printf '%s' "$KEPT"    || echo "  • (nothing)"
echo
echo "Untouched (never created/modified): ~/.claude, your gh login, and tools you already had."
echo "Open a new terminal so 'task' disappears from your shell."
