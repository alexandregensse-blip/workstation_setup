#!/usr/bin/env bash
# workstation_setup — single, idempotent installer. CONTAINER-ONLY model:
# the host is left in its initial state as much as possible. The whole AI toolchain
# (Claude Code, Serena, rtk, uv, python, ripgrep) and all config (~/.claude, hooks)
# live ONLY inside the Docker image and the self-contained <workspace>/.workstation dir.
# The host gets just: docker + git + gh (installed only if missing, and recorded so
# uninstall.sh can offer to remove exactly those), plus the `task` command in ~/.bashrc.
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
#   --dir   <path>  (WORKSTATION_DIR)    where the workstation lives    [default <home>/.workstation]
#   --lang  <code>  (WORKSTATION_LANG)   Claude UI language (image)     [default: unset / Claude default]
#   --yes | -y                           non-interactive (skip prompt)
# Re-running installs/configures only what is missing. No machine-specific absolute paths.
set -euo pipefail

WS_HOME="${WORKSTATION_HOME:-}"
WS_REPOS="${WORKSTATION_REPOS:-}"
WS_DIR="${WORKSTATION_DIR:-}"
WS_LANG="${WORKSTATION_LANG:-}"
ASSUME_YES=0
WS_URL="https://github.com/alexandregensse-blip/workstation_setup"

while [ $# -gt 0 ]; do
  case "$1" in
    --home)   WS_HOME="${2:?--home requires a path}";   WS_HOME="${WS_HOME/#\~/$HOME}";   shift 2 ;;
    --repos)  WS_REPOS="${2:?--repos requires a path}"; WS_REPOS="${WS_REPOS/#\~/$HOME}"; shift 2 ;;
    --dir)    WS_DIR="${2:?--dir requires a path}";     WS_DIR="${WS_DIR/#\~/$HOME}";     shift 2 ;;
    --lang)   WS_LANG="${2:?--lang requires a code}";   shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --home / --repos / --dir / --lang / --yes)"; exit 1 ;;
  esac
done

log(){  printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
# docker that works WITH or WITHOUT the docker group (auto-falls back to sudo)
dock(){ if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }
# fixed-width box, padded by character count (UTF-8) so the right edge never overflows
banner(){ local msg="  ✓  $1" w=46 line='' pad; while [ "${#line}" -lt "$w" ]; do line+='═'; done
  pad=$(( w - ${#msg} )); [ "$pad" -lt 0 ] && pad=0
  printf '╔%s╗\n║%s%*s║\n╚%s╝\n' "$line" "$msg" "$pad" '' "$line"; }

# Workspace location: flag/env, else prompt, else default. The .workstation dir lives inside it.
if [ -z "$WS_HOME" ]; then
  if [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ]; then
    printf '\nWhere do you want your workspace (task clones + the .workstation dir)?\n'
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
WS_DIR="${WS_DIR:-$WS_HOME/.workstation}"
WS_REPOS="${WS_REPOS:-$WS_HOME/repos}"

log "sudo"
sudo -v

log "host prerequisites: docker, git, gh (install only what's missing)"
need=""
for pair in docker.io:docker git:git gh:gh; do
  have "${pair#*:}" || need="$need ${pair%:*}"
done
mkdir -p "$WS_HOME" "$WS_REPOS"
if [ -n "$need" ]; then sudo apt update && sudo apt install -y $need; else echo "  all present ✓"; fi

log "fetch workstation into $WS_DIR (self-contained, inside your workspace)"
if [ -d "$WS_DIR/.git" ]; then git -C "$WS_DIR" pull --ff-only || true
else git clone "$WS_URL" "$WS_DIR"; fi
REPO_DIR="$WS_DIR"
# record what WE apt-installed, INSIDE the workstation dir (uninstall reads it, point-by-point)
[ -n "$need" ] && printf '%s\n' $need >> "$WS_DIR/.apt-installed"

log "docker group (skip if already a member)"
if getent group docker | grep -qw "$(id -un)"; then echo "  already a member ✓"
else sudo usermod -aG docker "$USER"; : > "$WS_DIR/.docker-group-added"; fi

log "docker image 'workstation' (build if missing)"
dock image inspect workstation >/dev/null 2>&1 || dock build --build-arg "WS_LANG=$WS_LANG" -t workstation "$REPO_DIR"

log "task command (auto-sourced in ~/.bashrc, removable block)"
if ! grep -q '# >>> workstation >>>' "$HOME/.bashrc" 2>/dev/null; then
  { echo '# >>> workstation >>>'
    echo "export WORKSTATION_DIR=\"$WS_DIR\""
    echo "export WORKSTATION_REPOS=\"$WS_REPOS\""
    echo "source \"$WS_DIR/shell/task.sh\""
    echo '# <<< workstation <<<'; } >> "$HOME/.bashrc"
fi

log "GitHub auth (browser, only if needed)"
if gh auth status >/dev/null 2>&1; then echo "  already authenticated ✓"
elif [ -r /dev/tty ]; then gh auth login --web --git-protocol https < /dev/tty || true
else echo "  no TTY — run 'gh auth login' later."; fi

log "Claude credentials (stored in $WS_DIR/.claude — host ~/.claude untouched)"
mkdir -p "$WS_DIR/.claude"
if [ -f "$WS_DIR/.claude/.credentials.json" ]; then echo "  already present ✓"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo "  CLAUDE_CODE_OAUTH_TOKEN set — no stored file needed ✓"
elif [ -r /dev/tty ]; then
  echo "  one-time login inside a container (a URL/code will be shown — open it to authorize):"
  dock run -it --rm -v "$WS_DIR/.claude:/seed" workstation \
    bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json' < /dev/tty \
    || echo "  login skipped/failed — run 'task auth' later."
else echo "  no TTY — run 'task auth' later (or set CLAUDE_CODE_OAUTH_TOKEN)."; fi

log "Check"
ok=1
for c in docker git gh; do have "$c" && echo "  ✓ $c" || { echo "  ✗ $c MISSING"; ok=0; }; done
dock image inspect workstation >/dev/null 2>&1 && echo "  ✓ docker image 'workstation'" || { echo "  ✗ image missing"; ok=0; }

echo
if [ "$ok" = 1 ]; then
banner "Workstation installed successfully"
cat <<EOF

Host left clean: only docker + git + gh were touched. Everything else (Claude, Serena,
rtk, all config) lives in the image and in:  $WS_DIR

Locations:  workstation: $WS_DIR    workspace: $WS_HOME    tasks: $WS_REPOS

task commands (isolated Claude session in a container):
  task <repo> <topic>                  → default base ($WS_REPOS)
  task --here <repo> <topic>           → base = current directory
  task --at <path> <repo> <topic>      → base = given path
  task auth                            → (re)login to Claude (stored in .workstation/.claude)
  e.g.  task claude-autodev fix-login

Docker works right away (via sudo until your next login). Log out/in once to drop the
sudo prompt (group 'docker'). Open a new terminal so 'task' is available.

To remove everything later (asks before each step):  $WS_DIR/uninstall.sh
EOF
else echo "⚠ Incomplete install — see the ✗ above."; exit 1; fi
