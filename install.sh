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
#   --running <path>  (WORKSTATION_RUNNING)  tasks base                     [default <workspace>/running]
#   --dir   <path>  (WORKSTATION_DIR)    where the workstation lives    [default <workspace>/.workstation]
#   --lang  <code>  (WORKSTATION_LANG)   Claude UI language (image)     [default: unset / Claude default]
#   --import-prefs | --no-import-prefs   import this machine's Claude prefs (statusline/lang/theme)  [default: ask]
#   --plug-ins <list> (WORKSTATION_PLUGINS) opt-in plugins, comma-separated keys (see plugins/available)  [default: prompt]
#   --yes | -y                           non-interactive (skip prompt)
# Re-running installs/configures only what is missing. No machine-specific absolute paths.
set -euo pipefail

WS_HOME="${WORKSTATION_HOME:-}"
WS_RUNNING="${WORKSTATION_RUNNING:-}"
WS_DIR="${WORKSTATION_DIR:-}"
WS_LANG="${WORKSTATION_LANG:-}"
IMPORT_PREFS="${WORKSTATION_IMPORT_PREFS:-}"   # ""=ask, 1=yes, 0=no
WS_PLUGINS="${WORKSTATION_PLUGINS:-}"          # space/comma-separated plugin keys ("" = prompt)
ASSUME_YES=0
WS_URL="https://github.com/alexandregensse-blip/workstation_setup"

while [ $# -gt 0 ]; do
  case "$1" in
    --home)   WS_HOME="${2:?--home requires a path}";   WS_HOME="${WS_HOME/#\~/$HOME}";   shift 2 ;;
    --running)  WS_RUNNING="${2:?--running requires a path}"; WS_RUNNING="${WS_RUNNING/#\~/$HOME}"; shift 2 ;;
    --dir)    WS_DIR="${2:?--dir requires a path}";     WS_DIR="${WS_DIR/#\~/$HOME}";     shift 2 ;;
    --lang)   WS_LANG="${2:?--lang requires a code}";   shift 2 ;;
    --import-prefs)    IMPORT_PREFS=1; shift ;;
    --no-import-prefs) IMPORT_PREFS=0; shift ;;
    --plug-ins) WS_PLUGINS="${2:?--plug-ins requires a comma-separated list}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --home/--running/--dir/--lang/--import-prefs/--no-import-prefs/--plug-ins/--yes)"; exit 1 ;;
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
WS_RUNNING="${WS_RUNNING:-$WS_HOME/running}"

log "sudo"
sudo -v

log "host prerequisites: docker, git, gh (install only what's missing)"
need=""
for pair in docker.io:docker git:git gh:gh; do
  have "${pair#*:}" || need="$need ${pair%:*}"
done
mkdir -p "$WS_HOME" "$WS_RUNNING"
if [ -n "$need" ]; then sudo apt update && sudo apt install -y $need; else echo "  all present ✓"; fi

log "fetch workstation into $WS_DIR (self-contained, inside your workspace)"
if [ -d "$WS_DIR/.git" ]; then git -C "$WS_DIR" pull --ff-only || true
else git clone "$WS_URL" "$WS_DIR"; fi
REPO_DIR="$WS_DIR"
# record what WE apt-installed, INSIDE the workstation dir (uninstall reads it, point-by-point)
[ -n "$need" ] && printf '%s\n' $need >> "$WS_DIR/.apt-installed"

log "docker group (skip if already a member)"
group_added=0
if getent group docker | grep -qw "$(id -un)"; then echo "  already a member ✓"
else sudo usermod -aG docker "$USER"; : > "$WS_DIR/.docker-group-added"; group_added=1; fi

log "plugins (opt-in — baked into the image on demand)"
if [ -z "$WS_PLUGINS" ] && [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ] && [ -f "$REPO_DIR/plugins/available" ]; then
  sel=""
  while IFS=$'\t' read -r pkey pdesc; do
    case "$pkey" in ''|'#'*) continue ;; esac
    printf '  Enable "%s" — %s? [y/N]: ' "$pkey" "$pdesc"
    read -r a < /dev/tty || a=n; case "$a" in y|Y|yes|YES) sel="$sel $pkey" ;; esac
  done < "$REPO_DIR/plugins/available"
  WS_PLUGINS="$sel"
fi
WS_PLUGINS="$(printf '%s' "$WS_PLUGINS" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//')"
[ -n "$WS_PLUGINS" ] && echo "  selected: $WS_PLUGINS" || echo "  none"

log "docker image 'workstation' (build if missing or plugins changed)"
prev_plugins="$(cat "$WS_DIR/.plugins" 2>/dev/null || true)"
if ! dock image inspect workstation >/dev/null 2>&1 || [ "$WS_PLUGINS" != "$prev_plugins" ]; then
  dock build --build-arg "WS_LANG=$WS_LANG" --build-arg "WS_PLUGINS=$WS_PLUGINS" -t workstation "$REPO_DIR"
  printf '%s' "$WS_PLUGINS" > "$WS_DIR/.plugins"
else echo "  up to date ✓"; fi
# host-side marker: if the image asked for audio (e.g. peon-ping), task.sh will pass the sound socket
if dock run --rm workstation test -f /home/dev/.claude/.audio-needed >/dev/null 2>&1; then : > "$WS_DIR/.audio"; else rm -f "$WS_DIR/.audio"; fi

log "Claude preferences (optional import from this machine — host is only read)"
mkdir -p "$WS_DIR/.claude"
if [ -f "$WS_DIR/.claude/settings.json" ]; then echo "  already imported ✓"
elif [ ! -f "$HOME/.claude/settings.json" ]; then echo "  no local Claude settings found — using image defaults"
else
  do_import="$IMPORT_PREFS"
  if [ -z "$do_import" ]; then
    if [ "$ASSUME_YES" = 1 ]; then do_import=0
    elif [ -r /dev/tty ]; then
      printf '  Import your local Claude + gh preferences (statusline, language, theme, gh config)? [Y/n]: '
      read -r a < /dev/tty || a=y; case "$a" in n|N|no|NO) do_import=0 ;; *) do_import=1 ;; esac
    else do_import=0; fi
  fi
  if [ "$do_import" = 1 ]; then
    cp "$HOME/.claude/settings.json" "$WS_DIR/.claude/host-settings.json"
    [ -f "$HOME/.claude/statusline.sh" ] && cp "$HOME/.claude/statusline.sh" "$WS_DIR/.claude/statusline.sh"
    # keep OUR Serena/rtk hooks (from the image's committed settings); drop machine-specific keys
    dock run --rm -v "$WS_DIR:/ws" workstation bash -lc \
      'jq -s ".[0] + {hooks: .[1].hooks} | del(.permissions, .enabledPlugins)" /ws/.claude/host-settings.json /ws/claude/settings.json > /ws/.claude/settings.json.tmp && mv /ws/.claude/settings.json.tmp /ws/.claude/settings.json' \
      && echo "  imported ✓ (workstation hooks kept; host permissions/plugins not imported)" \
      || echo "  import failed — using image defaults"
    rm -f "$WS_DIR/.claude/host-settings.json"
    # gh CLI prefs (aliases/editor/git_protocol) — NOT hosts.yml (that holds the token; we use GH_TOKEN)
    [ -f "$HOME/.config/gh/config.yml" ] && { mkdir -p "$WS_DIR/gh"; cp "$HOME/.config/gh/config.yml" "$WS_DIR/gh/config.yml"; echo "  imported gh config ✓"; }
    # git identity (name/email) is passed per-run by 'task' via env — no secret, always attributed.
    # Commit SIGNING is intentionally left to the broker (keys never enter task containers); see DESIGN.
  else echo "  skipped — using image defaults"; fi
fi

log "task command (auto-sourced in ~/.bashrc, removable block)"
if ! grep -q '# >>> workstation >>>' "$HOME/.bashrc" 2>/dev/null; then
  { echo '# >>> workstation >>>'
    echo "export WORKSTATION_DIR=\"$WS_DIR\""
    echo "export WORKSTATION_RUNNING=\"$WS_RUNNING\""
    echo "source \"$WS_DIR/shell/task.sh\""
    echo '# <<< workstation <<<'; } >> "$HOME/.bashrc"
fi

log "GitHub auth (browser, only if needed)"
if gh auth status >/dev/null 2>&1; then echo "  already authenticated ✓"
elif [ -r /dev/tty ]; then gh auth login --web --git-protocol https < /dev/tty || true
else echo "  no TTY — run 'gh auth login' later."; fi

log "Claude credentials (stored in $WS_DIR/.claude — host ~/.claude only read, never modified)"
mkdir -p "$WS_DIR/.claude"
reused=0
if [ -f "$WS_DIR/.claude/.credentials.json" ]; then echo "  already present ✓"; reused=1
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo "  CLAUDE_CODE_OAUTH_TOKEN set — no stored file needed ✓"; reused=1
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  # a Claude login already exists on this machine — offer to reuse it (read-only copy)
  acct="$(grep -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]+"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  [ -z "$acct" ] && acct="unknown account"
  if [ "$ASSUME_YES" = 1 ]; then ans=y
  elif [ -r /dev/tty ]; then printf '  Found a Claude login on this machine (account: %s).\n  Reuse it? [Y/n]: ' "$acct"; read -r ans < /dev/tty || ans=y
  else ans=y; fi
  case "${ans:-y}" in
    n|N|no|NO) echo "  ok, will log in via browser instead." ;;
    *) cp "$HOME/.claude/.credentials.json" "$WS_DIR/.claude/.credentials.json"
       chmod 600 "$WS_DIR/.claude/.credentials.json"
       echo "  reused host credentials for $acct ✓"; reused=1 ;;
  esac
fi
if [ "$reused" = 0 ]; then
  if [ -r /dev/tty ]; then
    echo "  Logging into Claude inside a container — a URL/code will be printed; open it to authorize"
    echo "  (the browser can't auto-open from inside the container):"
    dock run -it --rm -v "$WS_DIR/.claude:/seed" workstation \
      bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json' < /dev/tty \
      || echo "  login skipped/failed — run 'task auth' later."
  else echo "  no TTY — run 'task auth' later (or set CLAUDE_CODE_OAUTH_TOKEN)."; fi
fi

log "Check"
ok=1
for c in docker git gh; do have "$c" && echo "  ✓ $c" || { echo "  ✗ $c MISSING"; ok=0; }; done
dock image inspect workstation >/dev/null 2>&1 && echo "  ✓ docker image 'workstation'" || { echo "  ✗ image missing"; ok=0; }

echo
if [ "$ok" = 1 ]; then
banner "Workstation installed successfully"
cat <<EOF

Inside the container (the 'workstation' image):
  Claude Code · Serena MCP · rtk (hooks pre-wired) · uv · git · gh · ripgrep · python3 · jq

Locations:  workstation: $WS_DIR    workspace: $WS_HOME    task clones: $WS_RUNNING

task commands (isolated Claude session in a container):
  task [repo] [topic]                  → clones into $WS_RUNNING (repo prompted if omitted; topic → timestamp)
  task --here [repo] [topic]           → base = current directory
  task --at <path> [repo] [topic]      → base = given path
  task auth                            → (re)login to Claude (stored in .workstation/.claude)
  e.g.  task claude-autodev fix-login
EOF
[ "${group_added:-0}" = 1 ] && printf '\nDocker: works now via sudo. Log out/in once to use it without sudo (group '\''docker'\'').\n'
cat <<EOF

Open a new terminal so 'task' is available.
To remove everything later (asks before each step):  $WS_DIR/uninstall.sh
EOF
else echo "⚠ Incomplete install — see the ✗ above."; exit 1; fi
