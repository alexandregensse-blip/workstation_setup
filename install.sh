#!/usr/bin/env bash
# workstation_setup — single, idempotent installer. CONTAINER-ONLY model:
# the host is left in its initial state as much as possible. The whole AI toolchain
# (Claude Code, Serena, rtk, uv, python, ripgrep) and all config (~/.claude, hooks)
# live ONLY inside the Docker image and the self-contained <workspace>/.workstation dir.
# The host gets just: docker + git + gh (installed only if missing, and recorded so
# uninstall.sh can offer to remove exactly those), plus the `task` command in ~/.bashrc.
#
# Flow: it asks ALL its questions up front (workspace, plugins, prefs, auth), then the
# heavy work (image build + finalize) runs straight through with a live checklist.
#
# New machine, ONE command:
#   curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh | bash
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
#   --no-ipv6 | --ipv6 (WORKSTATION_IPV6) enable Docker IPv6 (NAT66) for task containers  [default: auto — on if the host has routable IPv6]
#   --yes | -y                           non-interactive (skip prompts)

# This must be EXECUTED (curl … | bash), not sourced: it uses `set -e`/`exit`, which would turn on
# errexit in your interactive shell or close it. If sourced, bail out SAFELY (return, before set -e)
# with instructions — a child process can't load the `task` function into your shell anyway.
if (return 0 2>/dev/null); then
  echo "Don't 'source' install.sh — run it:  curl -fsSL .../install.sh | bash" >&2
  echo "When it finishes, load 'task' with:  source ~/.bashrc   (or open a new terminal)" >&2
  return 1
fi
set -euo pipefail

WS_HOME="${WORKSTATION_HOME:-}"
WS_RUNNING="${WORKSTATION_RUNNING:-}"
WS_DIR="${WORKSTATION_DIR:-}"
WS_LANG="${WORKSTATION_LANG:-}"
IMPORT_PREFS="${WORKSTATION_IMPORT_PREFS:-}"   # ""=ask, 1=yes, 0=no
WS_PLUGINS="${WORKSTATION_PLUGINS:-}"          # space/comma-separated plugin keys ("" = prompt)
WS_IPV6="${WORKSTATION_IPV6:-}"                # ""=auto (enable if host has routable IPv6), 1=force, 0=never
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
    --no-ipv6) WS_IPV6=0; shift ;;
    --ipv6)    WS_IPV6=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "unknown flag: $1  (use --home/--running/--dir/--lang/--import-prefs/--no-import-prefs/--plug-ins/--no-ipv6/--yes)"; exit 1 ;;
  esac
done

log(){  printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
dock(){ if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }
banner(){ local msg="  ✓  $1" w=46 line='' pad; while [ "${#line}" -lt "$w" ]; do line+='═'; done
  pad=$(( w - ${#msg} )); [ "$pad" -lt 0 ] && pad=0
  printf '╔%s╗\n║%s%*s║\n╚%s╝\n' "$line" "$msg" "$pad" '' "$line"; }

# ---- live checklist for the build phase: a todo list that updates in place (plain logs if no TTY) ----
CK_NAMES=("Build base image" "Build workstation image" "Import preferences" "task command" "Claude login")
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
ck_dirty(){ CK_DRAWN=0; }
ck_set(){ CK_STATE[$1]="$2"; [ $# -ge 3 ] && CK_DETAIL[$1]="$3"
  if [ "$CK_TTY" = 1 ]; then ck_render
  else case "$2" in doing) printf '  ▶ %s\n' "${CK_NAMES[$1]}";; done) echo "    ✓ ${CK_DETAIL[$1]:-}";; esac; fi; }

human_rate(){ local b="$1"
  if   [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.1f MB/s", b/1048576}'
  elif [ "$b" -ge 1024    ]; then echo "$((b/1024)) KB/s"; else echo "${b} B/s"; fi; }
human_size(){ local b="$1"
  if   [ "$b" -ge 1048576 ]; then awk -v b="$b" 'BEGIN{printf "%.0f MB", b/1048576}'
  elif [ "$b" -ge 1024    ]; then echo "$((b/1024)) KB"; else echo "${b} B"; fi; }
# docker build whose checklist line <idx> shows: current Dockerfile step, downloaded-so-far vs an
# estimated total (<est> MB, ~), live rate, elapsed seconds. 'downloaded' = host rx delta (approx).
build_phase(){
  local idx="$1" calib="$2"; shift 2
  if [ "$CK_TTY" != 1 ] || ! docker info >/dev/null 2>&1; then ck_dirty; dock build "$@"; return $?; fi
  local logf t0 cur pid rc=0 ctr tx0 tx1 rate total=0 est=0 pct det
  logf="$(mktemp)"; t0=$SECONDS
  # docker0 tx = bytes the host pushes INTO containers ≈ the build's downloads (excludes browser/host).
  ctr="/sys/class/net/docker0/statistics/tx_bytes"; [ -r "$ctr" ] || ctr=""
  tx0="$( { [ -n "$ctr" ] && cat "$ctr"; } 2>/dev/null || echo 0)"
  # estimated total = the real volume measured on a previous successful build (self-calibrating)
  [ -n "$calib" ] && [ -r "$calib" ] && est="$(cat "$calib" 2>/dev/null || echo 0)"
  docker build "$@" >"$logf" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if [ -n "$ctr" ]; then tx1="$(cat "$ctr" 2>/dev/null || echo 0)"; rate=$(( tx1 - tx0 )); [ "$rate" -lt 0 ] && rate=0; tx0="$tx1"; total=$(( total + rate )); fi
    cur="$(grep -aoE '^Step [0-9]+/[0-9]+' "$logf" 2>/dev/null | tail -1)"
    if [ -z "$ctr" ]; then det="${cur:-building} · $((SECONDS-t0))s"
    elif [ "$est" -gt 0 ]; then
      pct=$(( total * 100 / est )); [ "$pct" -gt 99 ] && pct=99
      det="${cur:-building} · ↓ $(human_size "$total")/$(human_size "$est") ${pct}% · $(human_rate "$rate") · $((SECONDS-t0))s"
    else det="${cur:-building} · ↓ $(human_size "$total") · $(human_rate "$rate") · $((SECONDS-t0))s"; fi
    ck_set "$idx" doing "$det"
  done
  wait "$pid" || rc=$?
  [ "$rc" = 0 ] && [ -n "$calib" ] && [ "$total" -gt 0 ] && echo "$total" > "$calib"   # calibrate next time
  [ "$rc" != 0 ] && { ck_dirty; echo "  build FAILED (exit $rc) — last lines:"; tail -25 "$logf"; }
  rm -f "$logf"; return "$rc"
}

# ===== Workspace =====
if [ -z "$WS_HOME" ]; then
  if [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ]; then
    printf '\nWhere do you want your workspace (task clones + the .workstation dir)?\n'
    printf '  1) %s   (default)\n  2) current directory: %s\n  3) another path\n' "$HOME/dev" "$PWD"
    printf 'Choice [1/2/3]: '; read -r _ch < /dev/tty || _ch=1
    case "$_ch" in
      2) WS_HOME="$PWD" ;;
      3) printf 'Path: '; read -r WS_HOME < /dev/tty; WS_HOME="${WS_HOME/#\~/$HOME}" ;;
      *) WS_HOME="$HOME/dev" ;;
    esac
  else WS_HOME="$HOME/dev"; fi
fi
WS_DIR="${WS_DIR:-$WS_HOME/.workstation}"
WS_RUNNING="${WS_RUNNING:-$WS_HOME/running}"

log "sudo (cached for the rest of the install)"
sudo -v

# ===== Quick host work needed before the questions (prereqs give us gh; clone gives plugins list) =====
log "host prerequisites: docker, git, gh (install only what's missing)"
need=""
for pair in docker.io:docker git:git gh:gh; do have "${pair#*:}" || need="$need ${pair%:*}"; done
mkdir -p "$WS_HOME" "$WS_RUNNING"
if [ -n "$need" ]; then sudo apt update && sudo apt install -y $need; else echo "  all present ✓"; fi

log "fetch workstation into $WS_DIR"
if [ -d "$WS_DIR/.git" ]; then git -C "$WS_DIR" pull --ff-only || true; echo "  updated ✓"
else git clone "$WS_URL" "$WS_DIR" && echo "  cloned ✓"; fi
REPO_DIR="$WS_DIR"
[ -n "$need" ] && printf '%s\n' $need >> "$WS_DIR/.apt-installed"

log "docker group"
group_added=0
if getent group docker | grep -qw "$(id -un)"; then echo "  already a member ✓"
else sudo usermod -aG docker "$USER"; : > "$WS_DIR/.docker-group-added"; group_added=1; echo "  added (re-login to drop the sudo prompt) ✓"; fi

# Docker IPv6 (NAT66) so task containers match the HOST's dual-stack reach. On networks like SFR
# fibre (native IPv6 + DS-Lite IPv4), the host silently falls back to IPv6 when the IPv4 path
# degrades, but default-bridge containers are IPv4-ONLY → Claude drops inside tasks
# (FailedToOpenSocket/ConnectionRefused) while the host stays fine. Auto-enabled when the host has
# routable IPv6; opt out with --no-ipv6. We only CREATE /etc/docker/daemon.json (never edit an
# existing one), record it for uninstall, and roll back if docker won't come back up.
log "docker IPv6 (task containers dual-stack)"
if [ "$WS_IPV6" = 0 ]; then
  echo "  skipped (--no-ipv6)"
elif [ -z "$WS_IPV6" ] && ! ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
  echo "  host has no routable IPv6 — skipped (default bridge stays IPv4; force with --ipv6)"
elif [ -f /etc/docker/daemon.json ] && grep -Eq '"ipv6"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json; then
  echo "  already enabled in /etc/docker/daemon.json ✓"
elif [ -f /etc/docker/daemon.json ]; then
  echo "  /etc/docker/daemon.json exists — not auto-editing it. To enable IPv6, add to it:"
  echo '    "ipv6": true, "fixed-cidr-v6": "fd00:dead:beef::/64", "ip6tables": true   then: sudo systemctl restart docker'
else
  printf '{\n  "ipv6": true,\n  "fixed-cidr-v6": "fd00:dead:beef::/64",\n  "ip6tables": true\n}\n' | sudo tee /etc/docker/daemon.json >/dev/null
  : > "$WS_DIR/.docker-ipv6"   # marker: WE created daemon.json → uninstall can remove it
  sudo systemctl restart docker 2>/dev/null || true
  if timeout 40 bash -c 'until sudo docker info >/dev/null 2>&1; do sleep 1; done' 2>/dev/null; then
    echo "  enabled ✓ — task containers now get IPv6 (NAT66), matching the host"
  else
    sudo rm -f /etc/docker/daemon.json; rm -f "$WS_DIR/.docker-ipv6"; sudo systemctl restart docker 2>/dev/null || true
    echo "  ⚠ docker didn't restart cleanly with IPv6 — rolled back, continuing without it"
  fi
fi

# ===== ALL THE QUESTIONS, up front =====
log "setup — a few questions, then it builds on its own"

# plugins
if [ -z "$WS_PLUGINS" ] && [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ] && [ -f "$REPO_DIR/plugins/available" ]; then
  sel=""
  while IFS=$'\t' read -r pkey pdesc; do
    case "$pkey" in ''|'#'*) continue ;; esac
    printf '  Enable plugin "%s" — %s? [y/N]: ' "$pkey" "$pdesc"
    read -r a < /dev/tty || a=n; case "$a" in y|Y|yes|YES) sel="$sel $pkey" ;; esac
  done < "$REPO_DIR/plugins/available"
  WS_PLUGINS="$sel"
fi
WS_PLUGINS="$(printf '%s' "$WS_PLUGINS" | tr ',' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//')"
echo "  → plugins: ${WS_PLUGINS:-none}"

# import prefs decision (the actual import happens after the build, which has jq)
if [ -z "$IMPORT_PREFS" ]; then
  if [ "$ASSUME_YES" = 1 ] || [ ! -f "$HOME/.claude/settings.json" ]; then IMPORT_PREFS=0
  elif [ -r /dev/tty ]; then printf '  Import your local Claude + gh preferences (statusline, language, theme, gh config)? [Y/n]: '
    read -r a < /dev/tty || a=y; case "$a" in n|N|no|NO) IMPORT_PREFS=0 ;; *) IMPORT_PREFS=1 ;; esac
  else IMPORT_PREFS=0; fi
fi
echo "  → import prefs: $([ "$IMPORT_PREFS" = 1 ] && echo yes || echo no)"

# GitHub auth (gh is installed now)
if gh auth status >/dev/null 2>&1; then echo "  → GitHub: already authenticated"
elif [ -r /dev/tty ]; then echo "  GitHub login (a browser/code flow follows):"; gh auth login --web --git-protocol https < /dev/tty || true
else echo "  → GitHub: no TTY — run 'gh auth login' later"; fi

# Claude credentials: reuse decision now (cp needs no image); browser login (no-reuse) is deferred to after the build
mkdir -p "$WS_DIR/.claude"
NEED_LOGIN=0; CLAUDE_NOTE=""
if [ -f "$WS_DIR/.claude/.credentials.json" ]; then CLAUDE_NOTE="already present"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then CLAUDE_NOTE="using CLAUDE_CODE_OAUTH_TOKEN"
elif [ -f "$HOME/.claude/.credentials.json" ]; then
  acct="$(grep -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]+"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  [ -z "$acct" ] && acct="unknown account"
  if [ "$ASSUME_YES" = 1 ]; then ans=y
  elif [ -r /dev/tty ]; then printf '  Reuse the Claude login on this machine (account: %s)? [Y/n]: ' "$acct"; read -r ans < /dev/tty || ans=y
  else ans=y; fi
  case "${ans:-y}" in
    n|N|no|NO) NEED_LOGIN=1; CLAUDE_NOTE="will log in after the build" ;;
    *) cp "$HOME/.claude/.credentials.json" "$WS_DIR/.claude/.credentials.json"; chmod 600 "$WS_DIR/.claude/.credentials.json"; CLAUDE_NOTE="reused host login ($acct)" ;;
  esac
else NEED_LOGIN=1; CLAUDE_NOTE="will log in after the build"; fi
echo "  → Claude: $CLAUDE_NOTE"

# Claude launch defaults (written into the ~/.bashrc block so every task starts that way)
CL_MODE="${WORKSTATION_CLAUDE_MODE:-}"; CL_MODEL="${WORKSTATION_CLAUDE_MODEL:-}"; CL_EFFORT="${WORKSTATION_CLAUDE_EFFORT:-}"
if [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ] && [ -z "$CL_MODE$CL_MODEL$CL_EFFORT" ]; then
  printf '  Set Claude launch defaults for every task (auto mode / model / effort)? [y/N]: '
  read -r a < /dev/tty || a=n
  case "$a" in y|Y|yes|YES)
    printf '    permission mode [auto/acceptEdits/bypassPermissions/default, empty=auto]: '; read -r CL_MODE < /dev/tty; [ -z "$CL_MODE" ] && CL_MODE=auto
    printf '    model (alias like opus/sonnet, or full id; empty=skip): '; read -r CL_MODEL < /dev/tty
    printf '    effort [low/medium/high/xhigh/max, empty=skip]: '; read -r CL_EFFORT < /dev/tty ;;
  esac
fi
echo "  → launch: mode=${CL_MODE:-default} model=${CL_MODEL:-default} effort=${CL_EFFORT:-default}"

# ===== Execution — runs straight through (live checklist) =====
printf '\n\033[1;36m== building (no more questions) ==\033[0m\n\n'; ck_render

# 0. base image (toolchain — built once, then reused)
ck_set 0 doing
if dock image inspect workstation-base >/dev/null 2>&1; then ck_set 0 done "present (no re-download)"
else build_phase 0 "$WS_DIR/.dl-base" -f "$REPO_DIR/Dockerfile.base" -t workstation-base "$REPO_DIR" || { echo "⚠ base build failed — see above."; exit 1; }
     ck_set 0 done "built"; fi

# 1. workstation image (config + plugins, on top of the base)
ck_set 1 doing
prev_plugins="$(cat "$WS_DIR/.plugins" 2>/dev/null || true)"
if ! dock image inspect workstation >/dev/null 2>&1 || [ "$WS_PLUGINS" != "$prev_plugins" ]; then
  build_phase 1 "$WS_DIR/.dl-image" --build-arg "WS_LANG=$WS_LANG" --build-arg "WS_PLUGINS=$WS_PLUGINS" -t workstation "$REPO_DIR" || { echo "⚠ image build failed — see above."; exit 1; }
  printf '%s' "$WS_PLUGINS" > "$WS_DIR/.plugins"; ck_set 1 done "built"
else ck_set 1 done "up to date"; fi
if dock run --rm workstation test -f /home/dev/.claude/.audio-needed >/dev/null 2>&1; then : > "$WS_DIR/.audio"; else rm -f "$WS_DIR/.audio"; fi

# 2. import preferences (apply the earlier decision; needs the image's jq)
ck_set 2 doing
if [ "$IMPORT_PREFS" = 1 ] && [ -f "$HOME/.claude/settings.json" ]; then
  cp "$HOME/.claude/settings.json" "$WS_DIR/.claude/host-settings.json"
  [ -f "$HOME/.claude/statusline.sh" ] && cp "$HOME/.claude/statusline.sh" "$WS_DIR/.claude/statusline.sh"
  if dock run --rm -v "$WS_DIR:/ws" workstation bash -lc \
      'jq -s ".[0] + {hooks: .[1].hooks} | del(.permissions, .enabledPlugins)" /ws/.claude/host-settings.json /ws/claude/settings.json > /ws/.claude/settings.json.tmp && mv /ws/.claude/settings.json.tmp /ws/.claude/settings.json' >/dev/null 2>&1
  then _p="imported (Claude hooks kept)"; else _p="import failed — image defaults"; fi
  rm -f "$WS_DIR/.claude/host-settings.json"
  [ -f "$HOME/.config/gh/config.yml" ] && { mkdir -p "$WS_DIR/gh"; cp "$HOME/.config/gh/config.yml" "$WS_DIR/gh/config.yml"; _p="$_p + gh config"; }
  # carry the host's onboarding + account state (from ~/.claude.json) so the container's Claude
  # doesn't re-run its first-run wizard (theme/login). Curated keys only — no tokens.
  if [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$WS_DIR/.claude/host-dot.json"
    dock run --rm -v "$WS_DIR:/ws" workstation bash -lc \
      'jq "{hasCompletedOnboarding,lastOnboardingVersion,oauthAccount,migrationVersion,tipsHistory,theme}|with_entries(select(.value!=null))" /ws/.claude/host-dot.json > /ws/.claude/claude-keys.json' >/dev/null 2>&1 && _p="$_p + onboarding"
    rm -f "$WS_DIR/.claude/host-dot.json"
  fi
  ck_set 2 done "$_p"
else ck_set 2 done "skipped — image defaults"; fi

# 3. task command (auto-sourced in ~/.bashrc, removable block)
ck_set 3 doing
if ! grep -q '# >>> workstation >>>' "$HOME/.bashrc" 2>/dev/null; then
  { echo '# >>> workstation >>>'
    echo "export WORKSTATION_DIR=\"$WS_DIR\""
    echo "export WORKSTATION_RUNNING=\"$WS_RUNNING\""
    [ -n "$CL_MODE" ]   && echo "export WORKSTATION_CLAUDE_MODE=\"$CL_MODE\""
    [ -n "$CL_MODEL" ]  && echo "export WORKSTATION_CLAUDE_MODEL=\"$CL_MODEL\""
    [ -n "$CL_EFFORT" ] && echo "export WORKSTATION_CLAUDE_EFFORT=\"$CL_EFFORT\""
    echo "source \"$WS_DIR/shell/task.sh\""
    echo '# <<< workstation <<<'; } >> "$HOME/.bashrc"
  ck_set 3 done "added to ~/.bashrc"
else ck_set 3 done "already in ~/.bashrc"; fi

# 4. Claude login (reused already, or the deferred browser login — the only post-build prompt)
ck_set 4 doing
if [ "$NEED_LOGIN" = 1 ] && [ -r /dev/tty ]; then
  ck_dirty
  echo "  Logging into Claude inside a container — open the printed URL to authorize:"
  dock run -it --rm -v "$WS_DIR/.claude:/seed" workstation \
    bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json' < /dev/tty || true
  [ -f "$WS_DIR/.claude/.credentials.json" ] && ck_set 4 done "logged in" || ck_set 4 done "not logged in — run 'task auth'"
elif [ "$NEED_LOGIN" = 1 ]; then ck_set 4 done "no TTY — run 'task auth' later"
else ck_set 4 done "$CLAUDE_NOTE"; fi

# ===== final check + banner =====
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

'task' is in your ~/.bashrc. If 'task' isn't found in this shell yet:  source ~/.bashrc

To remove everything later (asks before each step):  $WS_DIR/uninstall.sh
EOF
else echo "⚠ Incomplete install — see the ✗ above."; exit 1; fi
