# task — open ISOLATED Claude sessions in disposable Docker containers.
#
#   task [--here | --at <path>] <repo> [topic]   start: repo fuzzy-matched to your gh repos
#                                                (asks if ambiguous/none); topic → timestamp if omitted.
#   task resume                                  reopen task clones in new tabs, CONTINUING the Claude session.
#   task cleanup [-y]                            delete clones that are clean AND fully pushed (asks; -y skips).
#   task auth [--slot <name>]                    (re)login to Claude; --slot creates an independent login.
#   task slots                                   list credential slots (independent logins for parallel tasks).
#   task help                                    this help (also shown for: task, task -h/--help/?).
#
# Container-only: the host has NO Claude/Serena/rtk — they live in the 'workstation' image.
# Clones on the HOST (WIP survives the disposable container). Auth: gh token via env + Claude
# credentials from <workstation>/.claude. Docker auto-falls back to sudo if needed. No hardcoded paths.

_task_base(){ printf '%s' "${WORKSTATION_RUNNING:-${WORKSTATION_HOME:-$HOME/dev}/running}"; }
_task_wsdir(){ printf '%s' "${WORKSTATION_DIR:-${WORKSTATION_HOME:-$HOME/dev}/.workstation}"; }
_task_dock(){ if docker info >/dev/null 2>&1; then echo docker; else echo "sudo docker"; fi; }
_task_slots_dir(){ printf '%s' "$(_task_wsdir)/.claude-slots"; }
_task_cfg_file(){ printf '%s' "$(_task_wsdir)/.config"; }

# Read an optional-feature setting WITHOUT polluting the host environment: the persistent store is a
# key=value file in <ws>/.config (parsed in pure bash — the host only has docker/git/gh, no jq). An
# env var WORKSTATION_<KEY> still works as an ad-hoc override but is never written by us.
#   _task_cfg <key>   e.g. _task_cfg notify / claude_mode / lang / theme / dns / statusline
_task_cfg(){
  local key="$1" ev="WORKSTATION_${1^^}"
  if [ -n "${!ev:-}" ]; then printf '%s' "${!ev}"; return 0; fi
  sed -n "s/^${key}=//p" "$(_task_cfg_file)" 2>/dev/null | tail -1
}
# Write/clear a setting in the config file (clears when value is empty). Creates the file as needed.
_task_cfg_set(){
  local key="$1" val="$2" f; f="$(_task_cfg_file)"; mkdir -p "$(dirname "$f")"; touch "$f"
  sed -i "/^${key}=/d" "$f"
  [ -n "$val" ] && printf '%s=%s\n' "$key" "$val" >> "$f"
}

_task_help(){
  cat <<'EOF'
task — isolated Claude sessions in disposable containers.

  task [--here | --at <path>] <repo> [topic]   Start a task. <repo> is fuzzy-matched against your
                                               gh repos (asks if several/none match); [topic] defaults
                                               to a timestamp. Clones under 'running/', branches
                                               task/<slug>, runs Claude in a container.
  task resume                                  List existing task clones, pick some in a checkbox menu, reopen
                                               each in a new tab and CONTINUE its Claude conversation.
  task cleanup [-y]                            Delete task clones that are clean AND fully pushed.
                                               Asks per clone; -y / --yes deletes without asking.
                                               Clones with uncommitted or unpushed work are kept.
  task settings                                Show your install choices; edit the Claude launch defaults.
  task auth [--slot <name>]                    (Re)login to Claude. With --slot <name>, log into an
                                               INDEPENDENT credential slot (its own token) for running
                                               many long tasks in parallel — each self-refreshes and
                                               survives for days. Without slots, tasks share one login.
  task slots                                   List credential slots and whether each is free or busy.
  task help                                    This help.

Launch flags — set these in your shell (or ~/.bashrc) and EVERY task starts that way:
  WORKSTATION_CLAUDE_MODE=auto     permission mode: auto | acceptEdits | bypassPermissions | default
  WORKSTATION_CLAUDE_MODEL=opus    model: an alias (opus/sonnet/…) or a full id
  WORKSTATION_CLAUDE_EFFORT=high   effort: low | medium | high | xhigh | max
  WORKSTATION_DNS="1.1.1.1 8.8.8.8" use reliable DNS in the container (if the network's DNS is flaky)
(The container is the sandbox, so 'auto'/'bypassPermissions' is reasonable there.)

(Note: 'man task' won't work — task is a shell function, not a man page. Use 'task help'.)
EOF
}

# Print each task clone dir under the running base, one per line.
_task_clones(){ local b; b="$(_task_base)"; [ -d "$b" ] || return 0
  find "$b" -mindepth 3 -maxdepth 3 -type d -name .git 2>/dev/null | sed 's#/\.git$##' | sort; }

# Open <cmd> in a new terminal tab/window (best-effort; detects common emulators). The new shell is
# interactive so 'task' (sourced from ~/.bashrc) is available, then runs <cmd>, then stays open.
_task_newtab(){
  local cmd="$1" run pre="" v
  # Persistent settings live in <ws>/.config, which the new tab reads via WORKSTATION_DIR (set by the
  # sourced ~/.bashrc) — so features carry over without any host env. But a new tab is spawned by the
  # terminal/its daemon, NOT a child of this shell, so any ad-hoc env OVERRIDE set only in the current
  # shell wouldn't reach it; re-export those (if present) AFTER bashrc so the running shell's wins.
  for v in WORKSTATION_DIR WORKSTATION_RUNNING WORKSTATION_NOTIFY WORKSTATION_LANG WORKSTATION_THEME \
           WORKSTATION_STATUSLINE WORKSTATION_DNS WORKSTATION_CLAUDE_MODE WORKSTATION_CLAUDE_MODEL WORKSTATION_CLAUDE_EFFORT; do
    [ -n "${!v:-}" ] && pre+="export $v=$(printf %q "${!v}"); "
  done
  run="${pre}${cmd}; exec bash"
  if   [ -n "${TMUX:-}" ];                                          then tmux new-window "bash -ic $(printf %q "$run")"
  elif command -v wezterm >/dev/null 2>&1 && [ -n "${WEZTERM_PANE:-}" ]; then wezterm cli spawn -- bash -ic "$run"
  elif command -v kitty  >/dev/null 2>&1 && [ -n "${KITTY_WINDOW_ID:-}" ]; then kitty @ launch --type=tab bash -ic "$run" >/dev/null 2>&1
  elif command -v ptyxis >/dev/null 2>&1;                           then ptyxis --tab -- bash -ic "$run" >/dev/null 2>&1 &
  elif command -v gnome-terminal >/dev/null 2>&1;                   then gnome-terminal --tab -- bash -ic "$run" >/dev/null 2>&1
  elif command -v konsole >/dev/null 2>&1;                          then konsole --new-tab -e bash -ic "$run" >/dev/null 2>&1 &
  elif command -v xfce4-terminal >/dev/null 2>&1;                   then xfce4-terminal --tab -e "bash -ic '$run'" >/dev/null 2>&1 &
  elif command -v alacritty >/dev/null 2>&1;                        then alacritty -e bash -ic "$run" >/dev/null 2>&1 &
  elif command -v xterm >/dev/null 2>&1;                            then xterm -e bash -ic "$run" >/dev/null 2>&1 &
  else echo "  no known terminal to open a tab — run it yourself:  $cmd"; return 1; fi
}

# Interactive checkbox multi-select (used by 'resume'). Arrow keys / j-k
# move, Space or Enter toggles the highlighted row, choosing "Confirmer" validates, "Annuler"/q/ESC
# aborts. UI is drawn on /dev/tty; the picks land in the global array _TASK_PICKED. Returns 1 if
# nothing was chosen / aborted.
_task_menu(){
  _TASK_PICKED=()
  [ -r /dev/tty ] || { echo "task: no TTY to choose."; return 1; }
  local -a items=("$@"); local n=${#items[@]}
  [ "$n" -gt 0 ] || return 1
  local -a sel; local j box key rest
  for ((j=0; j<n; j++)); do sel[j]=0; done
  local cur=0 total=$((n+2)) confirm=$n cancel=$((n+1)) drawn=0
  printf '\n  \033[1mReprendre quelle(s) task ?\033[0m\n  \033[2m↑/↓ déplacer · Espace/Entrée cocher · « Confirmer » pour valider · q/Échap annuler\033[0m\n' > /dev/tty
  printf '\033[?25l' > /dev/tty                                    # hide cursor
  while :; do
    [ "$drawn" -gt 0 ] && printf '\033[%dA' "$drawn" > /dev/tty   # back to first row, redraw in place
    for ((j=0; j<n; j++)); do
      [ "${sel[j]}" = 1 ] && box=$'[\033[32m✓\033[0m]' || box='[ ]'
      if [ "$j" = "$cur" ]; then printf '\033[K\033[7m %b %s \033[0m\n' "$box" "${items[j]}" > /dev/tty
      else                       printf '\033[K %b %s\n'             "$box" "${items[j]}" > /dev/tty; fi
    done
    if [ "$cur" = "$confirm" ]; then printf '\033[K\033[7m \033[32m✔ Confirmer\033[0m \033[0m\n' > /dev/tty
    else                             printf '\033[K   \033[32m✔ Confirmer\033[0m\n'                > /dev/tty; fi
    if [ "$cur" = "$cancel" ];  then printf '\033[K\033[7m \033[31m✖ Annuler\033[0m \033[0m\n'   > /dev/tty
    else                             printf '\033[K   \033[31m✖ Annuler\033[0m\n'                  > /dev/tty; fi
    drawn=$total
    IFS= read -rsn1 key < /dev/tty || break
    case "$key" in
      $'\033')
        read -rsn2 -t 0.1 rest < /dev/tty || rest=""
        case "$rest" in
          '[A'|'OA') cur=$(( (cur-1+total)%total )) ;;
          '[B'|'OB') cur=$(( (cur+1)%total )) ;;
          *)         printf '\033[?25h\n' > /dev/tty; return 1 ;;   # bare ESC → abort
        esac ;;
      k|K) cur=$(( (cur-1+total)%total )) ;;
      j|J) cur=$(( (cur+1)%total )) ;;
      a|A) for ((j=0; j<n; j++)); do sel[j]=1; done ;;
      q|Q) printf '\033[?25h\n' > /dev/tty; return 1 ;;
      ' '|''|$'\n'|$'\r')
        if   [ "$cur" -lt "$n" ];     then sel[cur]=$(( 1 - sel[cur] ))
        elif [ "$cur" = "$confirm" ]; then break
        else printf '\033[?25h\n' > /dev/tty; return 1; fi ;;
    esac
  done
  printf '\033[?25h\n' > /dev/tty                                  # show cursor again
  for ((j=0; j<n; j++)); do [ "${sel[j]}" = 1 ] && _TASK_PICKED+=("${items[j]}"); done
  [ "${#_TASK_PICKED[@]}" -gt 0 ] || return 1
}

# resume: choose existing clones and reopen each in its own tab.
_task_resume(){
  local b; b="$(_task_base)"
  local -a clones; mapfile -t clones < <(_task_clones)
  [ "${#clones[@]}" -gt 0 ] || { echo "task: no task clones under $b to resume."; return 0; }
  local -a chosen=()
  local -a rels=(); local c; for c in "${clones[@]}"; do rels+=("${c#"$b"/}"); done
  _task_menu "${rels[@]}" || { echo "task: cancelled."; return 0; }
  local r; for r in "${_TASK_PICKED[@]}"; do chosen+=("$b/$r"); done
  [ "${#chosen[@]}" -gt 0 ] || { echo "task: nothing selected."; return 0; }
  local d; for d in "${chosen[@]}"; do echo "→ opening ${d#"$b"/}"; _task_newtab "task open $(printf %q "$d")"; done
}

# cleanup: remove clones that are clean AND fully pushed (git-checked). Asks unless -y/--yes.
_task_cleanup(){
  local yes=0; case "${1:-}" in -y|--yes) yes=1 ;; esac
  local b; b="$(_task_base)"
  local -a clones; mapfile -t clones < <(_task_clones)
  [ "${#clones[@]}" -gt 0 ] || { echo "task: no task clones under $b."; return 0; }
  local d tag removed=0 kept=0 a
  for d in "${clones[@]}"; do
    tag=""
    [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && tag="uncommitted"
    [ -n "$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && tag="${tag:+$tag, }unpushed"
    if [ -n "$tag" ]; then echo "  keep    ${d#"$b"/}  ($tag)"; kept=$((kept+1)); continue; fi
    if [ "$yes" = 1 ]; then rm -rf "$d"; echo "  removed ${d#"$b"/}"; removed=$((removed+1))
    elif [ -r /dev/tty ]; then
      printf '  delete %s? (clean + pushed) [y/N]: ' "${d#"$b"/}"; read -r a < /dev/tty || a=n
      case "$a" in y|Y|yes|YES) rm -rf "$d"; echo "    removed"; removed=$((removed+1)) ;; *) kept=$((kept+1)) ;; esac
    else echo "  (deletable) ${d#"$b"/}"; kept=$((kept+1)); fi
  done
  find "$b" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
  echo "cleanup: removed $removed, kept $kept  (clones with uncommitted/unpushed work are always kept)."
}

# settings: show + edit optional features. Stored in <ws>/.config (NOT host env), applied to the next
# task. Features: notify (terminal bell), lang, theme, dns, and the Claude launch defaults.
_task_settings(){
  local ws_dir base cf; ws_dir="$(_task_wsdir)"; base="$(_task_base)"; cf="$(_task_cfg_file)"
  echo "Workstation settings:"
  echo "  workspace / .workstation:  $ws_dir"
  echo "  task clones:               $base"
  echo "  imported host prefs:       $([ -f "$ws_dir/.claude/statusline.sh" ] && echo 'yes (statusline)' || echo no)"
  echo "  config file:               $cf"
  echo "  Features (apply to the next task):"
  local k v
  for k in memory notify lang theme statusline dns claude_mode claude_model claude_effort; do
    v="$(_task_cfg "$k")"; [ "$k" = memory ] && [ -z "$v" ] && v="repo (default)"
    printf '    %-13s %s\n' "$k" "${v:-—}"
  done
  echo "  (paths/prefs are set by re-running install; these features need no rebuild.)"
  [ -r /dev/tty ] || return 0
  printf '\nEdit features now? [y/N]: '; local a; read -r a < /dev/tty || a=n
  case "$a" in y|Y|yes|YES) ;; *) return 0 ;; esac
  echo "(Enter = keep current · \"-\" = clear · or type a new value)"
  local spec key prompt cur ans
  for spec in \
    'memory|auto-memory persistence: repo (per-repo, default) / global (all repos) / off (per task)' \
    'notify|notifications: terminal_bell (bell+flash when Claude is done / needs you), empty = off' \
    'lang|Claude UI language code, e.g. fr / en (empty = Claude default)' \
    'theme|theme: dark / light / … (empty = default)' \
    'statusline|status line: off = disable it (empty = keep the image default / imported one)' \
    'dns|reliable DNS, space-separated IPs e.g. "1.1.1.1 8.8.8.8" (empty = host resolver)' \
    'claude_mode|permission mode: auto / acceptEdits / bypassPermissions / default' \
    'claude_model|model: an alias (opus/sonnet) or a full id' \
    'claude_effort|effort: low / medium / high / xhigh / max'; do
    key="${spec%%|*}"; prompt="${spec#*|}"; cur="$(_task_cfg "$key")"
    printf '  %s\n    [now: %s] > ' "$prompt" "${cur:-none}"; read -r ans < /dev/tty || ans=""
    case "$ans" in '') ;; '-') _task_cfg_set "$key" "" ;; *) _task_cfg_set "$key" "$ans" ;; esac
  done
  echo "✓ Saved to $cf — applies to the next task (no host environment touched)."
}

# --- Claude credential SLOTS (independent, self-refreshing logins; one per concurrent task) ---
# Each slot is an INDEPENDENT Claude login (its own refresh token) under <ws>/.claude-slots/<name>/,
# used as a task container's CLAUDE_CONFIG_DIR — a writable DIRECTORY, so Claude refreshes its own
# token in place (a single-file mount forbids the atomic rename Claude uses). Nothing is shared
# between slots or with the host, so many concurrent multi-day tasks never clobber each other's token
# (the failure mode of copying ONE login everywhere). A slot is "busy" while a task container labeled
# workstation.slot=<name> runs. No slots configured → tasks fall back to the single host-synced login.

# List authed slot names (one per line); a slot is "authed" once it has credentials.
_task_slot_list(){ local sdir s; sdir="$(_task_slots_dir)"; [ -d "$sdir" ] || return 0
  for s in "$sdir"/*/; do [ -f "${s}.credentials.json" ] && basename "$s"; done; }

# Is slot $1 in use by a running task container right now?
_task_slot_busy(){ local dock; dock="$(_task_dock)"; [ -n "$($dock ps -q --filter "label=workstation.slot=$1" 2>/dev/null)" ]; }

# Choose the slot for a clone → global _TASK_SLOT (empty = no slots = legacy mode). Sticky per clone
# (recorded in .git/claude-slot so 'resume' reuses it), else the first free authed slot. Returns 1 if
# slots exist but all are busy.
_task_slot_acquire(){
  local dir="$1" sdir rec cand="" s; sdir="$(_task_slots_dir)"; _TASK_SLOT=""
  local -a authed; mapfile -t authed < <(_task_slot_list)
  [ "${#authed[@]}" -gt 0 ] || return 0                       # no slots → legacy mode
  rec="$(cat "$dir/.git/claude-slot" 2>/dev/null || true)"
  if [ -n "$rec" ] && [ -f "$sdir/$rec/.credentials.json" ] && ! _task_slot_busy "$rec"; then cand="$rec"
  else for s in "${authed[@]}"; do _task_slot_busy "$s" || { cand="$s"; break; }; done; fi
  [ -n "$cand" ] || { echo "task: all ${#authed[@]} Claude slot(s) busy — exit a task to free one, or add: task auth --slot <name>." >&2; return 1; }
  printf '%s' "$cand" > "$dir/.git/claude-slot"; _TASK_SLOT="$cand"
}

# 'task slots' — list slots with free/busy + token expiry.
_task_slots_cmd(){
  local sdir s exp; sdir="$(_task_slots_dir)"
  local -a authed; mapfile -t authed < <(_task_slot_list)
  if [ "${#authed[@]}" -eq 0 ]; then
    echo "No Claude slots yet. For many parallel long-running tasks, create independent logins:"
    echo "  task auth --slot <name>      (e.g. task auth --slot a, then --slot b, …)"
    echo "Each self-refreshes and survives for days. Without slots, tasks share the host-synced login"
    echo "(fine for one long task at a time)."
    return 0
  fi
  echo "Claude slots — independent logins, each self-refreshing:"
  for s in "${authed[@]}"; do
    exp="$(jq -r '(.claudeAiOauth.expiresAt/1000)|todate' "$sdir/$s/.credentials.json" 2>/dev/null || echo '?')"
    printf '  %-16s %s   token exp: %s\n' "$s" "$(_task_slot_busy "$s" && echo '[busy]' || echo '[free]')" "$exp"
  done
}

# Known MCP/tool artifacts to keep out of `git status`. We add these to the clone-LOCAL
# .git/info/exclude — NOT the repo's committed .gitignore (we don't impose our tooling on the repo) —
# so they're invisible to git on the host AND in the container, and vanish with the clone. There's no
# generic "MCP → artifacts" registry, so this is a curated list: add a line when you add an MCP.
# (Serena writes .serena/ — cache + memories + project config; rtk writes nothing into the repo.)
_task_mcp_artifacts(){ printf '%s\n' '.serena/'; }
_task_ignore_mcp(){
  local dir="$1" marker='# workstation: MCP/tool artifacts (local-only)'
  local exclude="$dir/.git/info/exclude"            # separate line: $dir isn't set yet on the local above
  [ -d "$dir/.git" ] || return 0
  mkdir -p "$dir/.git/info"
  grep -qxF "$marker" "$exclude" 2>/dev/null || printf '\n%s\n' "$marker" >> "$exclude"
  local p; while IFS= read -r p; do
    [ -n "$p" ] && { grep -qxF "$p" "$exclude" 2>/dev/null || printf '%s\n' "$p" >> "$exclude"; }
  done < <(_task_mcp_artifacts)
}

# Run the container for an existing clone dir (auth + mounts + docker run). Used by start and 'open'.
_task_run(){
  local dir="$1" slug="$2" resume="${3:-}"
  [ -d "$dir" ] || { echo "task: no clone at $dir"; return 1; }
  local ws_dir dock; ws_dir="$(_task_wsdir)"; dock="$(_task_dock)"

  local gh_token; gh_token="$(gh auth token 2>/dev/null || true)"
  [ -z "$gh_token" ] && { echo "task: not logged into GitHub — run 'gh auth login' first."; return 1; }

  _task_ignore_mcp "$dir"   # keep Serena/MCP artifacts out of git status (clone-local exclude)

  # Claude launch flags + optional features, read from the config (env override wins; 'task settings'
  # edits them). Launch flags: claude_mode → --permission-mode, claude_model → --model, claude_effort
  # → --effort. Features merged on top of the baked settings.json via `claude --settings <json>`:
  # notify → preferredNotifChannel (terminal bell on done/needs-you), lang → language, theme → theme.
  local -a cflags=()
  local _m _md _ef; _m="$(_task_cfg claude_mode)"; _md="$(_task_cfg claude_model)"; _ef="$(_task_cfg claude_effort)"
  [ -n "$_m" ]  && cflags+=(--permission-mode "$_m")
  [ -n "$_md" ] && cflags+=(--model "$_md")
  [ -n "$_ef" ] && cflags+=(--effort "$_ef")
  local _notify _lang _theme _sl _feat=""
  _notify="$(_task_cfg notify)"; _lang="$(_task_cfg lang)"; _theme="$(_task_cfg theme)"; _sl="$(_task_cfg statusline)"
  [ -n "$_notify" ] && _feat="$_feat\"preferredNotifChannel\":\"$_notify\","
  [ -n "$_lang" ]   && _feat="$_feat\"language\":\"$_lang\","
  [ -n "$_theme" ]  && _feat="$_feat\"theme\":\"$_theme\","
  [ "$_sl" = off ]  && _feat="$_feat\"statusLine\":null,"
  # Persist Claude's auto-memory ACROSS future tasks (it's per-repo by design, but each task is a
  # fresh /work, so by default it'd be lost). 'memory': repo (default — shared by all tasks on this
  # repo), global (shared across all repos), off (ephemeral per task). We point Claude's
  # autoMemoryDirectory at a mounted host dir under <ws>/.memory (self-contained, no host pollution).
  local -a memmount=()
  local _mem _repo _memdir; _mem="$(_task_cfg memory)"; [ -z "$_mem" ] && _mem=repo
  if [ "$_mem" != off ]; then
    _repo="$(basename "$(dirname "$dir")")"
    [ "$_mem" = global ] && _memdir="$ws_dir/.memory/_global" || _memdir="$ws_dir/.memory/$_repo"
    mkdir -p "$_memdir"
    memmount=(-v "$_memdir:/memory")
    _feat="$_feat\"autoMemoryDirectory\":\"/memory\","
  fi
  [ -n "$_feat" ] && cflags+=(--settings "{${_feat%,}}")

  # Conversation history persists per-clone on the HOST (survives the disposable --rm container; resume
  # continues it). Inside .git/ so it's out of the worktree and removed with the clone. mkdir first so
  # the bind source is owned by the host user (uid 1000 = the image's 'dev'), not root-created by docker.
  local proj="$dir/.git/claude-projects"; mkdir -p "$proj"
  local -a resume_env=(); [ -n "$resume" ] && resume_env=(-e WS_RESUME=1)

  # Pick a credential slot (independent + self-refreshing) if any are configured; else legacy mode.
  _task_slot_acquire "$dir" || return 1
  local slot="$_TASK_SLOT"

  local -a claude_auth=() cfg_mounts=() session=() claude_cmd=()
  if [ -n "$slot" ]; then
    # ---- SLOT MODE: CLAUDE_CONFIG_DIR = the slot dir (a writable DIRECTORY) → Claude refreshes its own
    # independent token in place and persists it there for the next task (survives days). The clone's
    # history is overlaid at /cfg/projects (resume stays per-clone); the label marks the slot busy.
    local slot_dir="$ws_dir/.claude-slots/$slot"
    cfg_mounts=(-v "$slot_dir:/cfg" -v "$proj:/cfg/projects" -e CLAUDE_CONFIG_DIR=/cfg --label "workstation.slot=$slot")
    [ -f "$ws_dir/.claude/settings.json" ]    && cfg_mounts+=(-v "$ws_dir/.claude/settings.json:/seed/settings.json:ro")
    [ -f "$ws_dir/.claude/statusline.sh" ]    && cfg_mounts+=(-v "$ws_dir/.claude/statusline.sh:/seed/statusline.sh:ro")
    [ -f "$ws_dir/.claude/claude-keys.json" ] && cfg_mounts+=(-v "$ws_dir/.claude/claude-keys.json:/seed/claude-keys.json:ro")
    [ -f "$ws_dir/gh/config.yml" ]            && cfg_mounts+=(-v "$ws_dir/gh/config.yml:/home/dev/.config/gh/config.yml:ro")
    claude_cmd=(bash -lc '
      CFG=/cfg; mkdir -p "$CFG"
      # seed the baked config into the writable slot dir each start (so image updates propagate); the
      # slot keeps its own .credentials.json (none is baked) and projects/ (mounted) untouched.
      cp -a /home/dev/.claude/. "$CFG/" 2>/dev/null || true
      [ -f /seed/settings.json ] && cp -a /seed/settings.json "$CFG/settings.json"
      [ -f /seed/statusline.sh ] && cp -a /seed/statusline.sh "$CFG/statusline.sh"
      cfg="$CFG/.claude.json"; [ -f "$cfg" ] || printf "{}" > "$cfg"
      [ -f /seed/claude-keys.json ] && { jq -s ".[0] * .[1]" "$cfg" /seed/claude-keys.json > /tmp/c1 2>/dev/null && mv /tmp/c1 "$cfg"; }
      jq ".projects[\"/work\"] += {hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true}" "$cfg" > /tmp/c2 2>/dev/null && mv /tmp/c2 "$cfg"
      [ "${WS_RESUME:-0}" = 1 ] && compgen -G "$CFG/projects/*/*.jsonl" >/dev/null 2>&1 && set -- --continue "$@"
      exec claude "$@"' _ "${cflags[@]}")
    echo "task: Claude slot '$slot' (independent login, self-refreshing)."
  else
    # ---- LEGACY MODE: single host-synced credential mounted read-only. It can't self-refresh (Claude
    # rewrites .credentials.json by atomic rename, which a single-file bind mount forbids), so it's
    # fine for one long task at a time but 401s past the token's ~hours lifetime — use slots for many
    # concurrent long tasks. Re-synced from the host login when newer (host ~/.claude is only READ).
    local creds="$ws_dir/.claude/.credentials.json"
    local host_creds="$HOME/.claude/.credentials.json"
    if [ -z "${WORKSTATION_CLAUDE_NOSYNC:-}" ] && [ -f "$host_creds" ] && [ "$host_creds" -nt "$creds" ]; then
      mkdir -p "$ws_dir/.claude" && cp "$host_creds" "$creds" && chmod 600 "$creds"
    fi
    if [ -f "$creds" ]; then claude_auth=(-v "$creds:/home/dev/.claude/.credentials.json:ro")
    elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then claude_auth=(-e CLAUDE_CODE_OAUTH_TOKEN)
    else echo "task: no Claude credentials — run 'task auth' (or 'task auth --slot <name>', or set CLAUDE_CODE_OAUTH_TOKEN)."; return 1; fi
    [ -f "$ws_dir/.claude/settings.json" ] && cfg_mounts+=(-v "$ws_dir/.claude/settings.json:/home/dev/.claude/settings.json:ro")
    [ -f "$ws_dir/.claude/statusline.sh" ]  && cfg_mounts+=(-v "$ws_dir/.claude/statusline.sh:/home/dev/.claude/statusline.sh:ro")
    [ -f "$ws_dir/gh/config.yml" ]          && cfg_mounts+=(-v "$ws_dir/gh/config.yml:/home/dev/.config/gh/config.yml:ro")
    [ -f "$ws_dir/.claude/claude-keys.json" ] && cfg_mounts+=(-v "$ws_dir/.claude/claude-keys.json:/seed/claude-keys.json:ro")
    session=(-v "$proj:/home/dev/.claude/projects")
    claude_cmd=(bash -lc '
      cfg="$HOME/.claude.json"; [ -f "$cfg" ] || printf "{}" > "$cfg"
      [ -f /seed/claude-keys.json ] && { jq -s ".[0] * .[1]" "$cfg" /seed/claude-keys.json > /tmp/c1 2>/dev/null && mv /tmp/c1 "$cfg"; }
      jq ".projects[\"/work\"] += {hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true}" "$cfg" > /tmp/c2 2>/dev/null && mv /tmp/c2 "$cfg"
      [ "${WS_RESUME:-0}" = 1 ] && compgen -G "$HOME/.claude/projects/*/*.jsonl" >/dev/null 2>&1 && set -- --continue "$@"
      exec claude "$@"' _ "${cflags[@]}")
  fi

  # git identity for in-container commits (attribution only — no secret), from host git
  local gname gemail; gname="$(git config --get user.name 2>/dev/null || true)"; gemail="$(git config --get user.email 2>/dev/null || true)"
  local -a gitenv=()
  [ -n "$gname" ]  && gitenv+=(-e "GIT_AUTHOR_NAME=$gname"   -e "GIT_COMMITTER_NAME=$gname")
  [ -n "$gemail" ] && gitenv+=(-e "GIT_AUTHOR_EMAIL=$gemail" -e "GIT_COMMITTER_EMAIL=$gemail")

  # optional reliable DNS in the container (config 'dns', e.g. "1.1.1.1 8.8.8.8", if the network's
  # own DNS is flaky like a phone hotspot). Default: inherit the host resolver.
  local -a dns=() d; for d in $(_task_cfg dns); do dns+=(--dns "$d"); done

  $dock run -it --rm \
    --name "task-$slug" \
    -v "$dir:/work" -w /work \
    -e GH_TOKEN="$gh_token" \
    "${claude_auth[@]}" \
    "${cfg_mounts[@]}" \
    "${gitenv[@]}" \
    "${dns[@]}" \
    "${session[@]}" \
    "${memmount[@]}" \
    "${resume_env[@]}" \
    --memory=4g --cpus=2 \
    workstation "${claude_cmd[@]}"

  echo "↩  Container disposed. Clone (on host): $dir"
  echo "   When it's clean and pushed, 'task cleanup' will remove it."
}

task() {
  case "${1:-}" in
    ''|-h|--help|help|man|'?') _task_help; return 0 ;;
    resume)   _task_resume; return $? ;;
    cleanup)  shift; _task_cleanup "$@"; return $? ;;
    settings) _task_settings; return $? ;;
    slots)    _task_slots_cmd; return $? ;;
    open)    [ -n "${2:-}" ] || { echo "usage: task open <clone-dir>"; return 1; }; _task_run "$2" "$(basename "$2")" resume; return $? ;;
    auth)
      local ws_dir dock; ws_dir="$(_task_wsdir)"; dock="$(_task_dock)"
      # 'task auth --slot <name>' — log into an INDEPENDENT slot (its own refresh token), written
      # straight into the slot dir via CLAUDE_CONFIG_DIR. Used for many concurrent long-running tasks.
      if [ "${2:-}" = "--slot" ]; then
        local sn="${3:-}"; [ -n "$sn" ] || { echo "usage: task auth --slot <name>"; return 1; }
        local sdir="$ws_dir/.claude-slots/$sn"; mkdir -p "$sdir"
        echo "Logging into Claude for slot '$sn' (its OWN independent token) — open the printed URL:"
        $dock run -it --rm -e CLAUDE_CONFIG_DIR=/cfg -v "$sdir:/cfg" workstation bash -lc 'claude auth login'
        [ -f "$sdir/.credentials.json" ] && echo "slot '$sn' ready ✓ — a task will pick it up automatically." \
                                         || echo "slot '$sn' not logged in (re-run 'task auth --slot $sn')."
        return 0
      fi
      mkdir -p "$ws_dir/.claude"
      # Offer to (re)use the host login when it exists AND our copy is missing or older than it
      # (a stale snapshot — the cause of "Please run /login" in tasks). _task_run also re-syncs
      # automatically on every task start; this is the explicit, interactive path.
      if [ -f "$HOME/.claude/.credentials.json" ] && \
         { [ ! -f "$ws_dir/.claude/.credentials.json" ] || [ "$HOME/.claude/.credentials.json" -nt "$ws_dir/.claude/.credentials.json" ]; }; then
        local acct a
        acct="$(grep -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]+"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
        [ -z "$acct" ] && acct="unknown account"
        printf 'Reuse the Claude login already on this machine (account: %s)? [Y/n]: ' "$acct"
        read -r a || a=y
        case "$a" in n|N|no|NO) ;; *)
          cp "$HOME/.claude/.credentials.json" "$ws_dir/.claude/.credentials.json"; chmod 600 "$ws_dir/.claude/.credentials.json"
          echo "reused host credentials for $acct ✓"; return 0 ;;
        esac
      fi
      $dock run -it --rm -v "$ws_dir/.claude:/seed" workstation \
        bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json'
      return $? ;;
  esac

  # ---- start a new task ----
  local base; base="$(_task_base)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --here) base="$PWD"; shift ;;
      --at)   base="${2:?--at requires a path}"; shift 2 ;;
      --)     shift; break ;;
      -*)     echo "task: unknown option '$1' (try 'task help')"; return 1 ;;
      *)      break ;;
    esac
  done

  local repo="${1:-}" topic="${2:-}" orig="${1:-}"

  # resolve the repo: explicit (owner/name or URL) as-is, else fuzzy-matched to your gh repos
  case "$repo" in
    */*|*://*) : ;;
    *)
      local -a known=()
      mapfile -t known < <(gh repo list --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null)
      if [ -z "$repo" ]; then
        [ -r /dev/tty ] || { echo "usage: task [--here | --at <path>] <repo> [topic]   (try 'task help')"; return 1; }
        echo "Which repo?"; repo="$(_task_pick "${known[@]}")" || { echo "task: no repo chosen."; return 1; }
      elif [ "${#known[@]}" -gt 0 ]; then
        local -a exact=() subs=(); local r name
        for r in "${known[@]}"; do
          name="${r##*/}"
          if   [[ "${name,,}" == "${repo,,}" ]]; then exact+=("$r")
          elif [[ "${name,,}" == *"${repo,,}"* || "${repo,,}" == *"${name,,}"* ]]; then subs+=("$r"); fi
        done
        if   [ "${#exact[@]}" -eq 1 ]; then repo="${exact[0]}"
        elif [ "${#exact[@]}" -gt 1 ]; then echo "task: '$orig' matches several repos — pick one:"; repo="$(_task_pick "${exact[@]}")" || { echo "task: cancelled."; return 1; }
        elif [ "${#subs[@]}"  -eq 1 ]; then echo "task: '$orig' → ${subs[0]}"; repo="${subs[0]}"
        elif [ "${#subs[@]}"  -gt 1 ]; then echo "task: '$orig' matches several repos — pick one:"; repo="$(_task_pick "${subs[@]}")" || { echo "task: cancelled."; return 1; }
        else echo "task: no repo matches '$orig' — pick one (or type owner/name or a URL):"; repo="$(_task_pick "${known[@]}")" || { echo "task: cancelled."; return 1; }
        fi
      fi
      ;;
  esac
  [ -z "$repo" ] && { echo "task: no repo."; return 1; }

  # pre-check GitHub auth (clone needs it) for a clear early error
  gh auth token >/dev/null 2>&1 || { echo "task: not logged into GitHub — run 'gh auth login' first."; return 1; }

  local slug ts dir
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(printf '%s' "$topic" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  if [ -n "$slug" ]; then dir="$base/${repo##*/}/${ts}_$slug"
  else slug="$ts"; dir="$base/${repo##*/}/$ts"; fi
  mkdir -p "$(dirname "$dir")"

  gh repo clone "$repo" "$dir" || return 1
  ( cd "$dir" && git switch -c "task/$slug" && git push -u origin "task/$slug" )

  _task_run "$dir" "$slug"
}

# Keep the standalone _task_pick helper used by repo resolution.
_task_pick(){
  [ -r /dev/tty ] || return 1
  local -a opts=("$@"); local i=1 o pick
  for o in "${opts[@]}"; do printf '  %2d) %s\n' "$i" "$o" >&2; i=$((i+1)); done
  printf 'repo [number, or owner/name, or URL]: ' >&2
  read -r pick < /dev/tty || return 1
  case "$pick" in
    '') return 1 ;;
    *[!0-9]*) printf '%s\n' "$pick" ;;
    *) local sel="${opts[$((pick-1))]:-}"; [ -n "$sel" ] && printf '%s\n' "$sel" || return 1 ;;
  esac
}
