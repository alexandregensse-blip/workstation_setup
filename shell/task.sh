# task — open ISOLATED Claude sessions in disposable Docker containers.
#
#   task [--here | --at <path>] <repo> [topic]   start: repo fuzzy-matched to your gh repos
#                                                (asks if ambiguous/none); topic → timestamp if omitted.
#   task resume                                  pick existing task clones, reopen each in a new terminal tab.
#   task cleanup [-y]                            delete clones that are clean AND fully pushed (asks; -y skips).
#   task auth                                    (re)login to Claude (stored in <workspace>/.workstation/.claude).
#   task help                                    this help (also shown for: task, task -h/--help/?).
#
# Container-only: the host has NO Claude/Serena/rtk — they live in the 'workstation' image.
# Clones on the HOST (WIP survives the disposable container). Auth: gh token via env + Claude
# credentials from <workstation>/.claude. Docker auto-falls back to sudo if needed. No hardcoded paths.

_task_base(){ printf '%s' "${WORKSTATION_RUNNING:-${WORKSTATION_HOME:-$HOME/dev}/running}"; }
_task_wsdir(){ printf '%s' "${WORKSTATION_DIR:-${WORKSTATION_HOME:-$HOME/dev}/.workstation}"; }
_task_dock(){ if docker info >/dev/null 2>&1; then echo docker; else echo "sudo docker"; fi; }

_task_help(){
  cat <<'EOF'
task — isolated Claude sessions in disposable containers.

  task [--here | --at <path>] <repo> [topic]   Start a task. <repo> is fuzzy-matched against your
                                               gh repos (asks if several/none match); [topic] defaults
                                               to a timestamp. Clones under 'running/', branches
                                               task/<slug>, runs Claude in a container.
  task resume                                  List existing task clones, select some, reopen each in
                                               a new terminal tab (uses fzf if installed, else numbers).
  task cleanup [-y]                            Delete task clones that are clean AND fully pushed.
                                               Asks per clone; -y / --yes deletes without asking.
                                               Clones with uncommitted or unpushed work are kept.
  task settings                                Show your install choices; edit the Claude launch defaults.
  task auth                                    (Re)login to Claude.
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
  local cmd="$1" run
  run="$cmd; exec bash"
  if   [ -n "${TMUX:-}" ];                                          then tmux new-window "bash -ic $(printf %q "$run")"
  elif command -v wezterm >/dev/null 2>&1 && [ -n "${WEZTERM_PANE:-}" ]; then wezterm cli spawn -- bash -ic "$run"
  elif command -v kitty  >/dev/null 2>&1 && [ -n "${KITTY_WINDOW_ID:-}" ]; then kitty @ launch --type=tab bash -ic "$run" >/dev/null 2>&1
  elif command -v gnome-terminal >/dev/null 2>&1;                   then gnome-terminal --tab -- bash -ic "$run" >/dev/null 2>&1
  elif command -v konsole >/dev/null 2>&1;                          then konsole --new-tab -e bash -ic "$run" >/dev/null 2>&1 &
  elif command -v xfce4-terminal >/dev/null 2>&1;                   then xfce4-terminal --tab -e "bash -ic '$run'" >/dev/null 2>&1 &
  elif command -v alacritty >/dev/null 2>&1;                        then alacritty -e bash -ic "$run" >/dev/null 2>&1 &
  elif command -v xterm >/dev/null 2>&1;                            then xterm -e bash -ic "$run" >/dev/null 2>&1 &
  else echo "  no known terminal to open a tab — run it yourself:  $cmd"; return 1; fi
}

# resume: choose existing clones and reopen each in its own tab.
_task_resume(){
  local b; b="$(_task_base)"
  local -a clones; mapfile -t clones < <(_task_clones)
  [ "${#clones[@]}" -gt 0 ] || { echo "task: no task clones under $b to resume."; return 0; }
  local -a chosen=()
  if command -v fzf >/dev/null 2>&1; then
    mapfile -t chosen < <(printf '%s\n' "${clones[@]#"$b"/}" | fzf --multi --prompt='resume (TAB=select, ENTER=open)> ' --height=40%)
    local i; for i in "${!chosen[@]}"; do chosen[$i]="$b/${chosen[$i]}"; done
  else
    [ -r /dev/tty ] || { echo "task: no TTY to choose."; return 1; }
    echo "Resume which task(s)? space-separated numbers, or 'a' for all:"
    local i=1 c; for c in "${clones[@]}"; do printf '  %2d) %s\n' "$i" "${c#"$b"/}"; i=$((i+1)); done
    printf 'select: '; local picks; read -r picks < /dev/tty || return 1
    [ "$picks" = a ] && picks="$(seq 1 "${#clones[@]}")"
    local n d; for n in $picks; do d="${clones[$((n-1))]:-}"; [ -n "$d" ] && chosen+=("$d"); done
  fi
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

# settings: show the choices made at install + edit the Claude launch defaults (in the ~/.bashrc block).
_task_settings(){
  local ws_dir base; ws_dir="$(_task_wsdir)"; base="$(_task_base)"
  echo "Workstation settings:"
  echo "  workspace / .workstation (WORKSTATION_DIR):  $ws_dir"
  echo "  task clones      (WORKSTATION_RUNNING):      $base"
  echo "  plugins:                                     $(cat "$ws_dir/.plugins" 2>/dev/null || echo none)"
  echo "  imported host prefs:                         $([ -f "$ws_dir/.claude/settings.json" ] && echo yes || echo no)"
  echo "  onboarding/account imported:                 $([ -f "$ws_dir/.claude/claude-keys.json" ] && echo yes || echo no)"
  echo "  Claude launch — mode:   ${WORKSTATION_CLAUDE_MODE:-default}"
  echo "                  model:  ${WORKSTATION_CLAUDE_MODEL:-default}"
  echo "                  effort: ${WORKSTATION_CLAUDE_EFFORT:-default}"
  echo "  (plugins / language / paths are changed by re-running install or 'update' — they rebuild.)"
  [ -r /dev/tty ] || return 0
  printf '\nEdit the Claude launch defaults now? [y/N]: '; local a; read -r a < /dev/tty || a=n
  case "$a" in y|Y|yes|YES) ;; *) return 0 ;; esac
  local mode model effort bashrc="$HOME/.bashrc"
  printf '  permission mode [auto/acceptEdits/bypassPermissions/default, empty=clear]: '; read -r mode   < /dev/tty
  printf '  model (alias/id, empty=clear): ';                                            read -r model  < /dev/tty
  printf '  effort [low/medium/high/xhigh/max, empty=clear]: ';                          read -r effort < /dev/tty
  grep -q '# >>> workstation >>>' "$bashrc" 2>/dev/null || { echo "task: no workstation block in ~/.bashrc; set the WORKSTATION_CLAUDE_* vars yourself."; return 1; }
  sed -i '/^export WORKSTATION_CLAUDE_/d' "$bashrc"                       # drop old, then re-insert (after RUNNING)
  [ -n "$effort" ] && sed -i "/^export WORKSTATION_RUNNING=/a export WORKSTATION_CLAUDE_EFFORT=\"$effort\"" "$bashrc"
  [ -n "$model" ]  && sed -i "/^export WORKSTATION_RUNNING=/a export WORKSTATION_CLAUDE_MODEL=\"$model\""  "$bashrc"
  [ -n "$mode" ]   && sed -i "/^export WORKSTATION_RUNNING=/a export WORKSTATION_CLAUDE_MODE=\"$mode\""    "$bashrc"
  echo "✓ updated. Run 'source ~/.bashrc' (or open a new terminal) to apply."
}

# Run the container for an existing clone dir (auth + mounts + docker run). Used by start and 'open'.
_task_run(){
  local dir="$1" slug="$2"
  [ -d "$dir" ] || { echo "task: no clone at $dir"; return 1; }
  local ws_dir dock; ws_dir="$(_task_wsdir)"; dock="$(_task_dock)"

  local gh_token; gh_token="$(gh auth token 2>/dev/null || true)"
  [ -z "$gh_token" ] && { echo "task: not logged into GitHub — run 'gh auth login' first."; return 1; }

  local creds="$ws_dir/.claude/.credentials.json"; local -a claude_auth
  if [ -f "$creds" ]; then claude_auth=(-v "$creds:/home/dev/.claude/.credentials.json:ro")
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then claude_auth=(-e CLAUDE_CODE_OAUTH_TOKEN)
  else echo "task: no Claude credentials — run 'task auth' (or set CLAUDE_CODE_OAUTH_TOKEN)."; return 1; fi

  # per-machine config overrides (imported prefs / statusline / gh config), over the baked ones
  local -a cfg_mounts=()
  [ -f "$ws_dir/.claude/settings.json" ] && cfg_mounts+=(-v "$ws_dir/.claude/settings.json:/home/dev/.claude/settings.json:ro")
  [ -f "$ws_dir/.claude/statusline.sh" ]  && cfg_mounts+=(-v "$ws_dir/.claude/statusline.sh:/home/dev/.claude/statusline.sh:ro")
  [ -f "$ws_dir/gh/config.yml" ]          && cfg_mounts+=(-v "$ws_dir/gh/config.yml:/home/dev/.config/gh/config.yml:ro")

  # Claude launch flags from env — set these (e.g. in ~/.bashrc) to apply to every task:
  #   WORKSTATION_CLAUDE_MODE   → --permission-mode (auto | acceptEdits | bypassPermissions | default)
  #   WORKSTATION_CLAUDE_MODEL  → --model (alias like 'opus'/'sonnet' or a full id)
  #   WORKSTATION_CLAUDE_EFFORT → --effort (low | medium | high | xhigh | max)
  local -a cflags=()
  [ -n "${WORKSTATION_CLAUDE_MODE:-}" ]   && cflags+=(--permission-mode "$WORKSTATION_CLAUDE_MODE")
  [ -n "${WORKSTATION_CLAUDE_MODEL:-}" ]  && cflags+=(--model "$WORKSTATION_CLAUDE_MODEL")
  [ -n "${WORKSTATION_CLAUDE_EFFORT:-}" ] && cflags+=(--effort "$WORKSTATION_CLAUDE_EFFORT")
  # startup wrapper (in-container): merge imported host onboarding/account state if present,
  # auto-trust the mounted /work dir so Claude doesn't ask, then exec claude with the launch flags.
  [ -f "$ws_dir/.claude/claude-keys.json" ] && cfg_mounts+=(-v "$ws_dir/.claude/claude-keys.json:/seed/claude-keys.json:ro")
  local -a claude_cmd=(bash -lc '
    cfg="$HOME/.claude.json"; [ -f "$cfg" ] || printf "{}" > "$cfg"
    [ -f /seed/claude-keys.json ] && { jq -s ".[0] * .[1]" "$cfg" /seed/claude-keys.json > /tmp/c1 2>/dev/null && mv /tmp/c1 "$cfg"; }
    jq ".projects[\"/work\"] += {hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true}" "$cfg" > /tmp/c2 2>/dev/null && mv /tmp/c2 "$cfg"
    exec claude "$@"' _ "${cflags[@]}")

  # git identity for in-container commits (attribution only — no secret), from host git
  local gname gemail; gname="$(git config --get user.name 2>/dev/null || true)"; gemail="$(git config --get user.email 2>/dev/null || true)"
  local -a gitenv=()
  [ -n "$gname" ]  && gitenv+=(-e "GIT_AUTHOR_NAME=$gname"   -e "GIT_COMMITTER_NAME=$gname")
  [ -n "$gemail" ] && gitenv+=(-e "GIT_AUTHOR_EMAIL=$gemail" -e "GIT_COMMITTER_EMAIL=$gemail")

  # audio passthrough for sound plugins (e.g. peon-ping) only if the image asked for it AND a host
  # audio server is present — silent otherwise. uid 1000 matches.
  local xdg="/run/user/$(id -u)"; local -a audio=()
  if [ -f "$ws_dir/.audio" ] && [ -S "$xdg/pulse/native" ]; then
    audio=(-e "XDG_RUNTIME_DIR=$xdg" -e "PULSE_SERVER=unix:$xdg/pulse/native" -v "$xdg/pulse/native:$xdg/pulse/native")
    [ -f "$HOME/.config/pulse/cookie" ] && audio+=(-v "$HOME/.config/pulse/cookie:/home/dev/.config/pulse/cookie:ro")
  fi

  # optional reliable DNS in the container (set WORKSTATION_DNS="1.1.1.1 8.8.8.8" if the network's
  # own DNS is flaky, e.g. a phone hotspot). Default: inherit the host resolver.
  local -a dns=() d; for d in ${WORKSTATION_DNS:-}; do dns+=(--dns "$d"); done

  $dock run -it --rm \
    --name "task-$slug" \
    -v "$dir:/work" -w /work \
    -e GH_TOKEN="$gh_token" \
    "${claude_auth[@]}" \
    "${cfg_mounts[@]}" \
    "${gitenv[@]}" \
    "${audio[@]}" \
    "${dns[@]}" \
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
    open)    [ -n "${2:-}" ] || { echo "usage: task open <clone-dir>"; return 1; }; _task_run "$2" "$(basename "$2")"; return $? ;;
    auth)
      local ws_dir dock; ws_dir="$(_task_wsdir)"; dock="$(_task_dock)"
      mkdir -p "$ws_dir/.claude"
      if [ -f "$HOME/.claude/.credentials.json" ] && [ ! -f "$ws_dir/.claude/.credentials.json" ]; then
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
