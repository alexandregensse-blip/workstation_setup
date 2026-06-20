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

have(){ command -v "$1" >/dev/null 2>&1; }
# docker that works WITH or WITHOUT the docker group (auto-falls back to sudo)
dock(){ if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }
# fixed-width box, padded by character count (UTF-8) so the right edge never overflows
banner(){ local msg="  ✓  $1" w=46 line='' pad; while [ "${#line}" -lt "$w" ]; do line+='═'; done
  pad=$(( w - ${#msg} )); [ "$pad" -lt 0 ] && pad=0
  printf '╔%s╗\n║%s%*s║\n╚%s╝\n' "$line" "$msg" "$pad" '' "$line"; }

# ---- live checklist: a todo list that updates in place; degrades to plain logs without a TTY ----
CK_NAMES=("Host prerequisites" "Fetch workstation" "Docker group" "Plugins"
          "Build base image" "Build workstation image" "Import preferences"
          "task command" "GitHub auth" "Claude login")
CK_STATE=(); CK_DETAIL=(); for _ in "${CK_NAMES[@]}"; do CK_STATE+=(todo); CK_DETAIL+=(""); done
CK_DRAWN=0; CK_TTY=0; [ -t 1 ] && CK_TTY=1
ck_icon(){ case "$1" in done) printf '\033[32m✓\033[0m';; doing) printf '\033[1;36m▶\033[0m';; *) printf '\033[2m◦\033[0m';; esac; }
ck_render(){
  [ "$CK_TTY" = 1 ] || return 0
  [ "$CK_DRAWN" -gt 0 ] && printf '\033[%dA' "$CK_DRAWN"
  local i
  for i in "${!CK_NAMES[@]}"; do
    printf '\033[K  %b %s' "$(ck_icon "${CK_STATE[$i]:-todo}")" "${CK_NAMES[$i]}"
    [ -n "${CK_DETAIL[$i]:-}" ] && printf '  \033[2m— %s\033[0m' "${CK_DETAIL[$i]}"
    printf '\n'
  done
  CK_DRAWN=${#CK_NAMES[@]}
}
ck_dirty(){ CK_DRAWN=0; }                    # call before printing other output (prompt/build)
ck_set(){                                    # ck_set <idx> <state> [detail]
  CK_STATE[$1]="$2"; [ $# -ge 3 ] && CK_DETAIL[$1]="$3"
  if [ "$CK_TTY" = 1 ]; then ck_render
  else case "$2" in
    doing) printf '\n\033[1;36m== %s ==\033[0m\n' "${CK_NAMES[$1]}" ;;
    done)  [ -n "${CK_DETAIL[$1]:-}" ] && echo "  ${CK_DETAIL[$1]}" ;;
  esac; fi
}
human_rate(){  # bytes/sec → human-readable
  local b="$1"
  if   [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.1f MB/s", b/1048576}'
  elif [ "$b" -ge 1024    ]; then echo "$((b/1024)) KB/s"
  else echo "${b} B/s"; fi
}
# docker build whose checklist line <idx> shows the current Dockerfile step, the live host
# download rate (most of it is the build's downloads), and elapsed seconds.
build_phase(){
  local idx="$1"; shift
  if [ "$CK_TTY" != 1 ] || ! docker info >/dev/null 2>&1; then ck_dirty; dock build "$@"; return $?; fi
  local logf t0 cur pid rc=0 iface rxf rx0 rx1 rate det
  logf="$(mktemp)"; t0=$SECONDS
  iface="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || true)"
  rxf="/sys/class/net/$iface/statistics/rx_bytes"
  rx0="$(cat "$rxf" 2>/dev/null || echo 0)"
  docker build "$@" >"$logf" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    rx1="$(cat "$rxf" 2>/dev/null || echo 0)"; rate=$(( rx1 - rx0 )); [ "$rate" -lt 0 ] && rate=0; rx0="$rx1"
    cur="$(grep -aoE '^Step [0-9]+/[0-9]+' "$logf" 2>/dev/null | tail -1)"
    if [ -r "$rxf" ]; then det="${cur:-building} · ↓ $(human_rate "$rate") · $((SECONDS-t0))s"
    else det="${cur:-building} · $((SECONDS-t0))s"; fi
    ck_set "$idx" doing "$det"
  done
  wait "$pid" || rc=$?
  [ "$rc" != 0 ] && { ck_dirty; echo "  build FAILED (exit $rc) — last lines:"; tail -25 "$logf"; }
  rm -f "$logf"; return "$rc"
}

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

printf '\n\033[1;36m== sudo (cached for the rest of the install) ==\033[0m\n'
sudo -v

echo; ck_render   # draw the full checklist (all todo) once

# 1. host prerequisites
ck_set 0 doing
need=""
for pair in docker.io:docker git:git gh:gh; do have "${pair#*:}" || need="$need ${pair%:*}"; done
mkdir -p "$WS_HOME" "$WS_RUNNING"
if [ -n "$need" ]; then ck_dirty; sudo apt update && sudo apt install -y $need; ck_set 0 done "installed:$need"
else ck_set 0 done "all present"; fi

# 2. fetch the workstation clone (self-contained, inside the workspace)
ck_set 1 doing
if [ -d "$WS_DIR/.git" ]; then git -C "$WS_DIR" pull --ff-only >/dev/null 2>&1 || true; _f="updated"
else
  if ! git clone "$WS_URL" "$WS_DIR" >/dev/null 2>&1; then ck_dirty; echo "  clone failed:"; git clone "$WS_URL" "$WS_DIR"; fi
  _f="cloned"
fi
REPO_DIR="$WS_DIR"
[ -n "$need" ] && printf '%s\n' $need >> "$WS_DIR/.apt-installed"
ck_set 1 done "$_f → $WS_DIR"

# 3. docker group
ck_set 2 doing
group_added=0
if getent group docker | grep -qw "$(id -un)"; then ck_set 2 done "already a member"
else sudo usermod -aG docker "$USER"; : > "$WS_DIR/.docker-group-added"; group_added=1; ck_set 2 done "added (re-login to drop sudo)"; fi

# 4. plugins (opt-in)
ck_set 3 doing
if [ -z "$WS_PLUGINS" ] && [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ] && [ -f "$REPO_DIR/plugins/available" ]; then
  ck_dirty; sel=""
  while IFS=$'\t' read -r pkey pdesc; do
    case "$pkey" in ''|'#'*) continue ;; esac
    printf '  Enable "%s" — %s? [y/N]: ' "$pkey" "$pdesc"
    read -r a < /dev/tty || a=n; case "$a" in y|Y|yes|YES) sel="$sel $pkey" ;; esac
  done < "$REPO_DIR/plugins/available"
  WS_PLUGINS="$sel"
fi
WS_PLUGINS="$(printf '%s' "$WS_PLUGINS" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//')"
ck_set 3 done "${WS_PLUGINS:-none}"

# 5. base image (toolchain — built once, then reused)
ck_set 4 doing
if dock image inspect workstation-base >/dev/null 2>&1; then ck_set 4 done "present (no re-download)"
else build_phase 4 -f "$REPO_DIR/Dockerfile.base" -t workstation-base "$REPO_DIR" || { echo "⚠ base build failed — see above."; exit 1; }
     ck_set 4 done "built"; fi

# 6. workstation image (config + plugins, on top of the base)
ck_set 5 doing
prev_plugins="$(cat "$WS_DIR/.plugins" 2>/dev/null || true)"
if ! dock image inspect workstation >/dev/null 2>&1 || [ "$WS_PLUGINS" != "$prev_plugins" ]; then
  build_phase 5 --build-arg "WS_LANG=$WS_LANG" --build-arg "WS_PLUGINS=$WS_PLUGINS" -t workstation "$REPO_DIR" || { echo "⚠ image build failed — see above."; exit 1; }
  printf '%s' "$WS_PLUGINS" > "$WS_DIR/.plugins"; ck_set 5 done "built"
else ck_set 5 done "up to date"; fi
if dock run --rm workstation test -f /home/dev/.claude/.audio-needed >/dev/null 2>&1; then : > "$WS_DIR/.audio"; else rm -f "$WS_DIR/.audio"; fi

# 7. import Claude + gh preferences (optional; host is only read)
ck_set 6 doing
mkdir -p "$WS_DIR/.claude"
if [ -f "$WS_DIR/.claude/settings.json" ]; then ck_set 6 done "already imported"
elif [ ! -f "$HOME/.claude/settings.json" ]; then ck_set 6 done "no local Claude — image defaults"
else
  do_import="$IMPORT_PREFS"
  if [ -z "$do_import" ]; then
    if [ "$ASSUME_YES" = 1 ]; then do_import=0
    elif [ -r /dev/tty ]; then
      ck_dirty; printf '  Import your local Claude + gh preferences (statusline, language, theme, gh config)? [Y/n]: '
      read -r a < /dev/tty || a=y; case "$a" in n|N|no|NO) do_import=0 ;; *) do_import=1 ;; esac
    else do_import=0; fi
  fi
  if [ "$do_import" = 1 ]; then
    cp "$HOME/.claude/settings.json" "$WS_DIR/.claude/host-settings.json"
    [ -f "$HOME/.claude/statusline.sh" ] && cp "$HOME/.claude/statusline.sh" "$WS_DIR/.claude/statusline.sh"
    # keep OUR Serena/rtk hooks (from the image's committed settings); drop machine-specific keys
    if dock run --rm -v "$WS_DIR:/ws" workstation bash -lc \
        'jq -s ".[0] + {hooks: .[1].hooks} | del(.permissions, .enabledPlugins)" /ws/.claude/host-settings.json /ws/claude/settings.json > /ws/.claude/settings.json.tmp && mv /ws/.claude/settings.json.tmp /ws/.claude/settings.json' >/dev/null 2>&1
    then _p="imported (Claude hooks kept)"; else _p="import failed — image defaults"; fi
    rm -f "$WS_DIR/.claude/host-settings.json"
    # gh CLI prefs (aliases/editor) — NOT hosts.yml (that holds the token; we use GH_TOKEN)
    [ -f "$HOME/.config/gh/config.yml" ] && { mkdir -p "$WS_DIR/gh"; cp "$HOME/.config/gh/config.yml" "$WS_DIR/gh/config.yml"; _p="$_p + gh config"; }
    # git identity (name/email) is passed per-run by 'task' via env. Commit SIGNING is left to the broker.
    ck_set 6 done "$_p"
  else ck_set 6 done "skipped — image defaults"; fi
fi

# 8. task command (auto-sourced in ~/.bashrc, removable block)
ck_set 7 doing
if ! grep -q '# >>> workstation >>>' "$HOME/.bashrc" 2>/dev/null; then
  { echo '# >>> workstation >>>'
    echo "export WORKSTATION_DIR=\"$WS_DIR\""
    echo "export WORKSTATION_RUNNING=\"$WS_RUNNING\""
    echo "source \"$WS_DIR/shell/task.sh\""
    echo '# <<< workstation <<<'; } >> "$HOME/.bashrc"
  ck_set 7 done "added to ~/.bashrc"
else ck_set 7 done "already in ~/.bashrc"; fi

# 9. GitHub auth (browser, only if needed)
ck_set 8 doing
if gh auth status >/dev/null 2>&1; then ck_set 8 done "already authenticated"
elif [ -r /dev/tty ]; then ck_dirty; gh auth login --web --git-protocol https < /dev/tty || true; ck_set 8 done "done"
else ck_set 8 done "no TTY — run 'gh auth login' later"; fi

# 10. Claude credentials (stored in <workstation>/.claude; host ~/.claude only read)
ck_set 9 doing
mkdir -p "$WS_DIR/.claude"
reused=0; _c=""
if [ -f "$WS_DIR/.claude/.credentials.json" ]; then _c="already present"; reused=1
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then _c="using CLAUDE_CODE_OAUTH_TOKEN"; reused=1
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  acct="$(grep -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]+"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  [ -z "$acct" ] && acct="unknown account"
  if [ "$ASSUME_YES" = 1 ]; then ans=y
  elif [ -r /dev/tty ]; then ck_dirty; printf '  Found a Claude login on this machine (account: %s).\n  Reuse it? [Y/n]: ' "$acct"; read -r ans < /dev/tty || ans=y
  else ans=y; fi
  case "${ans:-y}" in
    n|N|no|NO) _c="will log in via browser" ;;
    *) cp "$HOME/.claude/.credentials.json" "$WS_DIR/.claude/.credentials.json"; chmod 600 "$WS_DIR/.claude/.credentials.json"; _c="reused host login ($acct)"; reused=1 ;;
  esac
fi
if [ "$reused" = 0 ]; then
  if [ -r /dev/tty ]; then
    ck_dirty
    echo "  Logging into Claude inside a container — a URL/code will be printed; open it to authorize"
    echo "  (the browser can't auto-open from inside the container):"
    dock run -it --rm -v "$WS_DIR/.claude:/seed" workstation \
      bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json' < /dev/tty || true
    [ -f "$WS_DIR/.claude/.credentials.json" ] && _c="logged in" || _c="not logged in — run 'task auth'"
  else _c="no TTY — run 'task auth' later"; fi
fi
ck_set 9 done "$_c"

# ---- final check + banner ----
ck_dirty; echo
ok=1
for c in docker git gh; do have "$c" || { echo "  ✗ $c MISSING"; ok=0; }; done
dock image inspect workstation >/dev/null 2>&1 || { echo "  ✗ docker image 'workstation' missing"; ok=0; }

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
