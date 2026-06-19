#!/usr/bin/env bash
# workstation_setup — single, idempotent installer (Ubuntu host).
#
# New machine, ONE command:
#   curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh | bash
#
# Headless / scripted (no prompt):
#   curl -fsSL .../install.sh | bash -s -- --home ~/dev --yes
#
# Flags / env (all optional):
#   --home  <path>  (WORKSTATION_HOME)   workspace dir for task clones  [prompt; default ~/dev]
#   --repos <path>  (WORKSTATION_REPOS)  tasks base                     [default <home>/repos]
#   --dir   <path>  (WORKSTATION_DIR)    where the workstation lives    [default ~/.local/share/workstation, hidden]
#   --yes | -y                           non-interactive (skip prompt)
# Re-installs/configures only what is missing. No machine-specific absolute paths ($HOME-relative).
set -euo pipefail

WS_DIR="${WORKSTATION_DIR:-$HOME/.local/share/workstation}"
WS_HOME="${WORKSTATION_HOME:-}"
WS_REPOS="${WORKSTATION_REPOS:-}"
ASSUME_YES=0
WS_URL="https://github.com/alexandregensse-blip/workstation_setup"

while [ $# -gt 0 ]; do
  case "$1" in
    --home)   WS_HOME="${2/#\~/$HOME}"; shift 2 ;;
    --repos)  WS_REPOS="${2/#\~/$HOME}"; shift 2 ;;
    --dir)    WS_DIR="${2/#\~/$HOME}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --home / --repos / --dir / --yes)"; exit 1 ;;
  esac
done

log(){  printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
# docker that works WITH or WITHOUT the docker group (auto-falls back to sudo)
dock(){ if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }
export PATH="$HOME/.local/bin:$PATH"

# Workspace location: flag/env, else prompt, else default
if [ -z "$WS_HOME" ]; then
  if [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ]; then
    printf '\nWhere do you want your workspace (task clones)?\n'
    printf '  1) %s   (default)\n  2) current directory: %s\n  3) another path\n' "$HOME/dev" "$PWD"
    printf 'Choice [1/2/3]: '
    read -r _ch < /dev/tty || _ch=1
    case "$_ch" in
      2) WS_HOME="$PWD" ;;
      3) printf 'Path: '; read -r WS_HOME < /dev/tty; WS_HOME="${WS_HOME/#\~/$HOME}" ;;
      *) WS_HOME="$HOME/dev" ;;
    esac
  else WS_HOME="$HOME/dev"; fi
fi
WS_REPOS="${WS_REPOS:-$WS_HOME/repos}"

log "sudo"
sudo -v

log "system packages (install only what's missing)"
need=""
for pair in curl:curl git:git ripgrep:rg gh:gh nodejs:node npm:npm docker.io:docker; do
  have "${pair#*:}" || need="$need ${pair%:*}"
done
if [ -n "$need" ]; then sudo apt update && sudo apt install -y $need; else echo "  all present ✓"; fi

# Self-bootstrap: if not already inside a clone, fetch the repo into the hidden dir
_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ -d "$(dirname "$_src")/claude" ]; then
  REPO_DIR="$(cd "$(dirname "$_src")" && pwd)"
else
  log "fetching workstation into $WS_DIR"
  if [ -d "$WS_DIR/.git" ]; then git -C "$WS_DIR" pull --ff-only; else git clone "$WS_URL" "$WS_DIR"; fi
  REPO_DIR="$WS_DIR"
fi

log "uv";     have uv     || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
log "claude"; have claude || curl -fsSL https://claude.ai/install.sh | bash
log "serena"; have serena || uv tool install -p 3.13 serena-agent
serena init >/dev/null 2>&1 || true
log "rtk";    have rtk    || curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh

log "dotfiles + workspace + task command (auto-sourced)"
mkdir -p "$HOME/.claude" "$WS_HOME" "$WS_REPOS" "$HOME/.local/share/workstation-shell"
cp "$REPO_DIR/claude/CLAUDE.md"     "$HOME/.claude/CLAUDE.md"
cp "$REPO_DIR/claude/CLAUDE.md"     "$WS_HOME/AGENTS.md"
cp "$REPO_DIR/claude/settings.json" "$HOME/.claude/settings.json"
cp "$REPO_DIR/claude/statusline.sh" "$HOME/.claude/statusline.sh"
cp "$REPO_DIR/dev/CLAUDE.md"        "$WS_HOME/CLAUDE.md"
cp "$REPO_DIR/shell/task.sh"        "$HOME/.local/share/workstation-shell/task.sh"
chmod +x "$HOME/.claude/statusline.sh"
if ! grep -q 'workstation-shell/task.sh' "$HOME/.bashrc" 2>/dev/null; then
  { [ "$WS_REPOS" != "$HOME/dev/repos" ] && echo "export WORKSTATION_REPOS=\"$WS_REPOS\""
    echo 'source "$HOME/.local/share/workstation-shell/task.sh"'; } >> "$HOME/.bashrc"
fi

log "Serena MCP (skip if already registered)"
claude mcp list 2>/dev/null | grep -q '^serena' || serena setup claude-code

log "rtk init — last (skip if already done)"
[ -f "$HOME/.claude/RTK.md" ] || rtk init -g --auto-patch

log "docker group (skip if already a member)"
getent group docker | grep -qw "$(id -un)" || sudo usermod -aG docker "$USER"

log "docker image 'workstation' (build if missing)"
dock image inspect workstation >/dev/null 2>&1 || dock build -t workstation "$REPO_DIR"

log "authentication (env tokens if present, else browser)"
gh auth status     >/dev/null 2>&1 || gh auth login
claude auth status >/dev/null 2>&1 || claude auth login

log "Check"
ok=1
for c in uv claude serena rtk docker gh; do have "$c" && echo "  ✓ $c" || { echo "  ✗ $c MISSING"; ok=0; }; done
dock image inspect workstation >/dev/null 2>&1 && echo "  ✓ docker image 'workstation'" || { echo "  ✗ image missing"; ok=0; }

echo
if [ "$ok" = 1 ]; then
cat <<EOF
╔══════════════════════════════════════════════╗
║  ✅  Workstation installed successfully         ║
╚══════════════════════════════════════════════╝

Locations:  workstation: $WS_DIR   workspace: $WS_HOME   tasks: $WS_REPOS

task commands (isolated Claude session in a container):
  task <repo> <topic>                  → default base ($WS_REPOS)
  task --here <repo> <topic>           → base = current directory
  task --at <path> <repo> <topic>      → base = given path
  e.g.  task claude-autodev fix-login

Docker works right away (via sudo until your next login). Log out/in once to drop the
sudo prompt (group 'docker'). Open a new terminal so 'task' is available.
EOF
else echo "⚠ Incomplete install — see the ✗ above."; exit 1; fi
