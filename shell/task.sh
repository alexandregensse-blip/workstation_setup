# shellcheck shell=bash
# task — open ISOLATED Claude sessions in disposable Docker containers.
#
#   task [--here | --at <path>] <repo> [topic]   start: repo fuzzy-matched to your gh repos
#                                                (asks if ambiguous/none); topic → timestamp if omitted.
#   task resume                                  reopen task clones in new tabs, CONTINUING the Claude session.
#   task list                                    status of every clone: running/idle, login, git state + logins.
#   task cleanup [-y] | -f | <name>              delete clones: clean+pushed by default; -f (checklist) or
#                                                <name> also discards uncommitted/unpushed work.
#   task settings                                show/edit features (notifications, language, memory, cpus/ram, DNS, …).
#   task toolchain [<repo>]                      scaffold/edit a repo's extra toolchains (its own image, FROM workstation).
#   task auth [<name> | rm <name>]               manage Claude logins (independent, self-refreshing accounts).
#   task help                                    this help (also shown for: task, task -h/--help/?).
#
# Container-only: the host has NO Claude/Serena/rtk — they live in the 'workstation' image.
# Clones on the HOST (WIP survives the disposable container). Auth: gh token via env + Claude
# credentials from <workstation>/.claude-slots/<login>. Docker auto-falls back to sudo if needed. No hardcoded paths.

# Shared build-progress meter (live one-liner for the toolchain build). Sourced from the clone next
# to this file; harmless if absent (the build just stays quiet until done/fail).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/build-progress.sh" 2>/dev/null || true

_task_base(){ printf '%s' "${WORKSTATION_RUNNING:-${WORKSTATION_HOME:-$HOME/dev}/running}"; }
_task_wsdir(){ printf '%s' "${WORKSTATION_DIR:-${WORKSTATION_HOME:-$HOME/dev}/.workstation}"; }
_task_dock(){ if docker info >/dev/null 2>&1; then echo docker; else echo "sudo docker"; fi; }
_task_slots_dir(){ printf '%s' "$(_task_wsdir)/.claude-slots"; }
_task_cfg_file(){ printf '%s' "$(_task_wsdir)/.config"; }
_task_bases_file(){ printf '%s' "$(_task_wsdir)/.bases"; }

# Tiny pure-bash JSON readers (the host has NO jq — only docker/git/gh). They extract ONE value for a
# key that occurs once in Claude's small config files (e.g. emailAddress, expiresAt). Not a general
# parser: same pragmatic trade-off as the .config reader. Empty output when the key is absent/null.
_task_json_str(){ local f="$1" k="$2" v
  v="$(grep -o "\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null | head -1)" || return 0
  v="${v#*:}"; v="${v#*\"}"; v="${v%\"}"; printf '%s' "$v"; }
_task_json_num(){ local f="$1" k="$2" v
  v="$(grep -o "\"$k\"[[:space:]]*:[[:space:]]*[0-9]\+" "$f" 2>/dev/null | head -1)" || return 0
  printf '%s' "${v##*[!0-9]}"; }

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
  task list                                    Read-only status of every task clone (running/idle, which login,
                                               git state) plus a logins summary. (aliases: ls, ps)
  task cleanup [-y]                            Delete task clones that are clean AND fully pushed.
                                               Asks per clone; -y / --yes deletes without asking.
                                               Clones with uncommitted/unpushed work are kept (need -f).
  task cleanup -f | --force                    Checkbox menu to pick clones to DISCARD — including their
                                               uncommitted/unpushed work (asks once before deleting).
  task cleanup <name> [-f]                     Target clone(s) whose path matches <name>; add -f to also
                                               discard their uncommitted/unpushed work.
  task settings                                Show/edit features: notifications, language, theme, status
                                               line, memory persistence, DNS, container cpus/ram, and the
                                               Claude launch defaults. Stored in <ws>/.config (no host env),
                                               applied to the next task.
  task toolchain                               Manage per-repo toolchains (Go/Rust/C++…) in an interactive
                                               menu (like 'settings'): add / edit / remove. Specs live in
                                               <ws>/toolchains/<key>/Dockerfile (host-side, NOT committed to
                                               the repo); that repo's tasks then run on a dedicated
                                               'workstation-<key>' image (FROM workstation), so one repo's
                                               tools never bloat another. Other repos use the shared image.
  task toolchain <repo>                        Jump straight to scaffolding/editing that repo's spec.
  task auth                                    List Claude logins (account, free/busy, token expiry).
  task auth <name>                             Browser-login into <name> — an INDEPENDENT, self-refreshing
                                               login (its own token, can be its own Anthropic account).
                                               A task auto-borrows a free login; run several for parallel
                                               long tasks. 'task auth rm <name>' removes one.
  task help                                    This help.

Features are configured with 'task settings' (stored in <ws>/.config, not host env). They apply to
the next task with no rebuild: notifications (terminal bell), language, theme, status line, per-repo
memory persistence, reliable DNS, container resource limits (cpus / ram), and Claude launch defaults
(permission-mode / model / effort — the container is the sandbox, so 'auto' is reasonable). Each also
takes a one-off env override (WORKSTATION_NOTIFY, WORKSTATION_CLAUDE_MODE, …) never written to your shell.

(Note: 'man task' won't work — task is a shell function, not a man page. Use 'task help'.)
EOF
}

# Print each task clone dir (absolute) under base $1, one per line. A clone is always
# <base>/<repo>/<ts>_<slug> → its .git sits at depth 3 under ANY base (default or --here/--at).
_task_clones(){ local b="$1"; [ -d "$b" ] || return 0
  find "$b" -mindepth 3 -maxdepth 3 -type d -name .git 2>/dev/null | sed 's#/\.git$##'; }

# Record a non-default base ($1) so resume/cleanup/list can find clones made with --here/--at. Stored
# in <ws>/.bases (one path per line). Append-if-absent: a short-line `>>` is atomic under PIPE_BUF, so
# concurrent launches don't corrupt it (no flock); duplicates are de-duped at read time anyway.
_task_base_record(){ local b="$1" f; f="$(_task_bases_file)"
  [ "$b" = "$(_task_base)" ] && return 0                    # default base is always scanned
  mkdir -p "$(dirname "$f")"; touch "$f"
  grep -qxF "$b" "$f" 2>/dev/null || printf '%s\n' "$b" >> "$f"; }

# All task clones across the default base + every recorded base still on disk (de-duped, sorted).
_task_all_clones(){ local def f b; def="$(_task_base)"; f="$(_task_bases_file)"
  { _task_clones "$def"
    [ -f "$f" ] && while IFS= read -r b; do [ -n "$b" ] && [ "$b" != "$def" ] && _task_clones "$b"; done < "$f"
  } | sort -u; }

# Pretty label for a clone path: strip the default base prefix, else show ~ for $HOME, else absolute.
_task_clone_label(){ local c="$1" def; def="$(_task_base)"
  case "$c" in "$def"/*) printf '%s' "${c#"$def"/}" ;; "$HOME"/*) printf '~/%s' "${c#"$HOME"/}" ;; *) printf '%s' "$c" ;; esac; }

# Git state of a clone $1 → "clean" (clean AND fully pushed) or "uncommitted"/"unpushed"/both.
# Shared by 'cleanup' (deletable iff clean) and 'list'. One definition, so they can't drift.
_task_git_state(){ local d="$1" tag=""
  [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && tag="uncommitted"
  [ -n "$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null | head -1)" ] && tag="${tag:+$tag, }unpushed"
  printf '%s' "${tag:-clean}"; }

# Open <cmd> in a new terminal tab/window (best-effort; detects common emulators). The new shell is
# interactive so 'task' (sourced from ~/.bashrc) is available, then runs <cmd>, then stays open.
_task_newtab(){
  local cmd="$1" run pre="" v
  # Persistent settings live in <ws>/.config, which the new tab reads via WORKSTATION_DIR (set by the
  # sourced ~/.bashrc) — so features carry over without any host env. But a new tab is spawned by the
  # terminal/its daemon, NOT a child of this shell, so any ad-hoc env OVERRIDE set only in the current
  # shell wouldn't reach it; re-export those (if present) AFTER bashrc so the running shell's wins.
  for v in WORKSTATION_DIR WORKSTATION_RUNNING WORKSTATION_NOTIFY WORKSTATION_LANG WORKSTATION_THEME \
           WORKSTATION_STATUSLINE WORKSTATION_DNS WORKSTATION_CPUS WORKSTATION_RAM \
           WORKSTATION_CLAUDE_MODE WORKSTATION_CLAUDE_MODEL WORKSTATION_CLAUDE_EFFORT; do
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
  _TASK_PICKED=(); _TASK_PICKED_IDX=()
  { true >/dev/tty; } 2>/dev/null || return 2
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
  for ((j=0; j<n; j++)); do [ "${sel[j]}" = 1 ] && { _TASK_PICKED+=("${items[j]}"); _TASK_PICKED_IDX+=("$j"); }; done
  [ "${#_TASK_PICKED[@]}" -gt 0 ] || return 1
}

# Interactive SINGLE-select arrow menu. Args: <title> <item>...  ↑/↓ or j/k move, Enter picks the
# highlighted row, q/Esc cancels. Sets _TASK_SEL (item) and _TASK_SEL_IDX (0-based). Returns 1 on
# cancel, 2 if there's no usable TTY. Drawn on /dev/tty, redrawn in place.
_task_select(){
  _TASK_SEL=""; _TASK_SEL_IDX=-1
  { true >/dev/tty; } 2>/dev/null || return 2
  local title="$1"; shift
  local -a items=("$@"); local n=${#items[@]}; [ "$n" -gt 0 ] || return 1
  local cur=0 drawn=0 key rest j
  printf '\n  \033[1m%s\033[0m\n  \033[2m↑/↓ move · Enter select · q/Esc cancel\033[0m\n' "$title" > /dev/tty
  printf '\033[?25l' > /dev/tty                                    # hide cursor
  while :; do
    [ "$drawn" -gt 0 ] && printf '\033[%dA' "$drawn" > /dev/tty
    for ((j=0; j<n; j++)); do
      if [ "$j" = "$cur" ]; then printf '\033[K\033[7m ▸ %s \033[0m\n' "${items[j]}" > /dev/tty
      else                       printf '\033[K   %s\n'                 "${items[j]}" > /dev/tty; fi
    done
    drawn=$n
    IFS= read -rsn1 key < /dev/tty || break
    case "$key" in
      $'\033') read -rsn2 -t 0.1 rest < /dev/tty || rest=""
        case "$rest" in '[A'|'OA') cur=$(((cur-1+n)%n)) ;; '[B'|'OB') cur=$(((cur+1)%n)) ;;
          *) printf '\033[?25h\n' > /dev/tty; return 1 ;; esac ;;
      k|K) cur=$(((cur-1+n)%n)) ;;
      j|J) cur=$(((cur+1)%n)) ;;
      q|Q) printf '\033[?25h\n' > /dev/tty; return 1 ;;
      ''|$'\n'|$'\r') printf '\033[?25h\n' > /dev/tty; _TASK_SEL="${items[cur]}"; _TASK_SEL_IDX=$cur; return 0 ;;
    esac
  done
  printf '\033[?25h\n' > /dev/tty; return 1
}

# resume: choose existing clones and reopen each in its own tab.
_task_resume(){
  local -a clones; mapfile -t clones < <(_task_all_clones)
  [ "${#clones[@]}" -gt 0 ] || { echo "task: no task clones to resume."; return 0; }
  local -a labels=(); local c; for c in "${clones[@]}"; do labels+=("$(_task_clone_label "$c")"); done
  _task_menu "${labels[@]}"; local rc=$?
  [ "$rc" = 2 ] && { echo "task: no TTY to choose."; return 1; }
  [ "$rc" = 0 ] || { echo "task: cancelled."; return 0; }
  local i; for i in "${_TASK_PICKED_IDX[@]}"; do
    echo "→ opening $(_task_clone_label "${clones[$i]}")"; _task_newtab "task open $(printf %q "${clones[$i]}")"
  done
}

# Remove now-empty <repo> dirs under each scanned base (default + recorded) after a cleanup.
_task_cleanup_prune(){ local def f base; def="$(_task_base)"; f="$(_task_bases_file)"
  { printf '%s\n' "$def"; [ -f "$f" ] && cat "$f"; } | sort -u | while IFS= read -r base; do
    [ -d "$base" ] && find "$base" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
  done; }

# cleanup: delete task clones.
#   task cleanup [-y]            clones that are clean AND fully pushed (asks per clone; -y skips)
#   task cleanup -f|--force      checkbox menu to pick clones to DISCARD — incl. uncommitted/unpushed work
#   task cleanup <name> [-f]     target clone(s) matching <name> (substring); -f also discards their work
# A running clone (mounted in a live container) is never deleted — exit it first.
# The clone's task branch and its remote as "<remote>\t<branch>" — the local branch whose upstream is
# <remote>/task/* (set when the task was created with 'git push -u'). Empty when there's no such branch.
_task_clone_branch(){ local d="$1" up
  while IFS='|' read -r _ up; do
    case "$up" in */task/*) printf '%s\t%s' "${up%%/*}" "${up#*/}"; return 0 ;; esac
  done < <(git -C "$d" for-each-ref --format='%(refname:short)|%(upstream:short)' refs/heads 2>/dev/null)
  return 0; }

# Remove a clone dir; if it tracks a <remote>/task/* branch, optionally drop that remote branch too.
#   mode: ask = prompt on a TTY · yes = delete without asking · no = leave the branch (default)
# The remote delete runs from INSIDE the clone (reusing its remote + gh auth) BEFORE the dir is gone.
_task_remove_clone(){ local d="$1" mode="${2:-no}" rb remote branch do_remote=0
  rb="$(_task_clone_branch "$d")"; remote="${rb%%$'\t'*}"; branch="${rb#*$'\t'}"
  # Only consider the remote branch when it STILL exists on the remote (a merged PR may have auto-
  # deleted it, leaving just a stale local tracking ref) — verify with ls-remote before offering.
  if [ -n "$rb" ] && [ "$mode" != no ] && git -C "$d" ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
    case "$mode" in
      yes) do_remote=1 ;;
      ask) if [ -r /dev/tty ]; then
             printf '      also delete remote branch %s/%s? [y/N]: ' "$remote" "$branch"
             local a; read -r a < /dev/tty || a=n; case "$a" in y|Y|yes|YES) do_remote=1 ;; esac
           fi ;;
    esac
    if [ "$do_remote" = 1 ]; then
      if git -C "$d" push "$remote" --delete "$branch" >/dev/null 2>&1; then echo "      deleted remote $remote/$branch"
      else echo "      (could not delete remote $remote/$branch)"; fi
    fi
  fi
  rm -rf "$d"; }

_task_cleanup(){
  local yes=0 force=0; local -a names=()
  while [ $# -gt 0 ]; do case "$1" in
    -y|--yes)   yes=1 ;;
    -f|--force) force=1 ;;
    -*)         echo "task cleanup: unknown option '$1' (use -y / -f / <name>)"; return 1 ;;
    *)          names+=("$1") ;;
  esac; shift; done

  local -a clones; mapfile -t clones < <(_task_all_clones)
  [ "${#clones[@]}" -gt 0 ] || { echo "task: no task clones."; return 0; }

  # clones currently mounted in a live container — never delete those
  local -A running=(); local src
  while IFS='|' read -r src _; do [ -n "$src" ] && running["$src"]=1; done < <(_task_running_pairs)

  # narrow to <name> matches (substring on basename / pretty label, case-insensitive)
  if [ "${#names[@]}" -gt 0 ]; then
    local -a sel=(); local d nm
    for d in "${clones[@]}"; do
      for nm in "${names[@]}"; do
        if [[ "${d,,}" == *"${nm,,}"* ]]; then sel+=("$d"); break; fi
      done
    done
    [ "${#sel[@]}" -gt 0 ] || { echo "task cleanup: no clone matches: ${names[*]}"; return 1; }
    clones=("${sel[@]}")
  fi

  # FORCE CHECKLIST: -f with no explicit name → pick which clones to discard (any state) in a menu
  if [ "$force" = 1 ] && [ "${#names[@]}" -eq 0 ]; then
    local -a labels=(); local d
    for d in "${clones[@]}"; do labels+=("$(_task_clone_label "$d")  [$(_task_git_state "$d")]"); done
    _task_menu "${labels[@]}"; local rc=$?
    [ "$rc" = 2 ] && { echo "task: no TTY for the checklist — use 'task cleanup -f <name>'."; return 1; }
    [ "$rc" = 0 ] || { echo "task: cancelled."; return 0; }
    local -a picked=(); local i d2
    for i in "${_TASK_PICKED_IDX[@]}"; do d2="${clones[$i]}"
      if [ -n "${running[$d2]+x}" ]; then echo "  skip $(_task_clone_label "$d2") (running — exit it first)"; continue; fi
      picked+=("$d2")
    done
    [ "${#picked[@]}" -gt 0 ] || { echo "task: nothing to remove."; return 0; }
    if [ "$yes" != 1 ] && [ -r /dev/tty ]; then
      printf '  ⚠ DISCARD %d task(s) and ALL their uncommitted/unpushed work? [y/N]: ' "${#picked[@]}"
      local a; read -r a < /dev/tty || a=n; case "$a" in y|Y|yes|YES) : ;; *) echo "  cancelled."; return 0 ;; esac
    fi
    local rmode=no
    if [ "$yes" != 1 ] && [ -r /dev/tty ]; then
      printf '  also delete their remote task branches on origin (only those still present)? [y/N]: '
      local rb; read -r rb < /dev/tty || rb=n; case "$rb" in y|Y|yes|YES) rmode=yes ;; esac
    fi
    local removed=0
    for d in "${picked[@]}"; do _task_remove_clone "$d" "$rmode"; echo "  removed $(_task_clone_label "$d")"; removed=$((removed+1)); done
    _task_cleanup_prune
    echo "cleanup: removed $removed (forced)."
    return 0
  fi

  # per-clone: default (clean+pushed only) OR named OR -f <name> (force discards work, with a warning).
  # Two passes so the FULL list is on screen before any prompt: pass 1 prints every clone's state and
  # collects the deletable ones, pass 2 asks. (Pass 1 also avoids a prompt appearing mid-listing while
  # the per-clone git-state probe is still running.)
  local d lbl state removed=0 kept=0 a
  local -a todo=(); local -A st=()
  for d in "${clones[@]}"; do
    lbl="$(_task_clone_label "$d")"; state="$(_task_git_state "$d")"; st["$d"]="$state"
    if   [ -n "${running[$d]+x}" ];                  then echo "  keep      $lbl  (running — exit it first)"; kept=$((kept+1))
    elif [ "$state" != clean ] && [ "$force" != 1 ]; then echo "  keep      $lbl  ($state — needs -f to discard)"; kept=$((kept+1))
    else echo "  deletable $lbl  ($state)"; todo+=("$d"); fi
  done
  for d in "${todo[@]}"; do
    lbl="$(_task_clone_label "$d")"; state="${st[$d]}"
    if [ "$yes" = 1 ]; then _task_remove_clone "$d" no; echo "  removed $lbl${state:+  ($state)}"; removed=$((removed+1))
    elif [ -r /dev/tty ]; then
      if [ "$state" = clean ]; then printf '  delete %s? (clean + pushed) [y/N]: ' "$lbl"
      else                          printf '  ⚠ DISCARD %s and its %s work? [y/N]: ' "$lbl" "$state"; fi
      read -r a < /dev/tty || a=n
      case "$a" in y|Y|yes|YES) _task_remove_clone "$d" ask; echo "    removed"; removed=$((removed+1)) ;; *) kept=$((kept+1)) ;; esac
    else kept=$((kept+1)); fi
  done
  _task_cleanup_prune
  echo "cleanup: removed $removed, kept $kept  (clones with uncommitted/unpushed work need -f to discard)."
}

# settings: show + edit optional features. Stored in <ws>/.config (NOT host env), applied to the next
# task. Features: notify (terminal bell), lang, theme, dns, and the Claude launch defaults.
# The editable feature keys, in display order.
_task_setting_keys(){ printf '%s\n' notify memory lang theme statusline dns cpus ram claude_mode claude_model claude_effort; }

# One-line hint shown for a setting (allowed values / format + what "clear" means).
_task_setting_hint(){ case "$1" in
  notify)        echo 'terminal_bell (bell+flash when Claude is done/needs you) · clear = off' ;;
  memory)        echo 'repo (per-repo, default) · global (all repos) · off (per task)' ;;
  lang)          echo 'Claude UI language code, e.g. fr / en / pt-BR · clear = Claude default' ;;
  theme)         echo 'dark · light · dark-daltonized · light-daltonized · clear = default' ;;
  statusline)    echo 'off = hide the status line · clear = keep the default/imported one' ;;
  dns)           echo 'space-separated IPs, e.g. "1.1.1.1 8.8.8.8" · clear = host resolver' ;;
  cpus)          echo 'CPUs per task, e.g. 2 or 1.5 (> 0) · clear = 2 (default)' ;;
  ram)           echo 'RAM per task with a unit m/g, e.g. 512m / 4g · clear = 4g (default)' ;;
  claude_mode)   echo 'auto · acceptEdits · bypassPermissions · default' ;;
  claude_model)  echo 'alias (opus/sonnet/haiku) or a full model id · clear = default' ;;
  claude_effort) echo 'low · medium · high · xhigh · max' ;;
esac; }

# Validate value $2 for setting $1. On failure, return 1 and set _TASK_SETTING_ERR. Enums are strict
# (so typos are caught, not silently ignored); open-ended ones are format-checked.
_task_setting_validate(){
  local k="$1" v="$2" t; _TASK_SETTING_ERR=""
  case "$k" in
    notify)        case "$v" in terminal_bell) return 0 ;; *) _TASK_SETTING_ERR="notify must be 'terminal_bell' (or clear with \"-\" to turn off)";; esac ;;
    memory)        case "$v" in repo|global|off) return 0 ;; *) _TASK_SETTING_ERR="memory must be: repo | global | off";; esac ;;
    statusline)    case "$v" in off) return 0 ;; *) _TASK_SETTING_ERR="statusline only takes 'off' (clear with \"-\" to re-enable)";; esac ;;
    claude_mode)   case "$v" in auto|acceptEdits|bypassPermissions|default) return 0 ;; *) _TASK_SETTING_ERR="mode must be: auto | acceptEdits | bypassPermissions | default";; esac ;;
    claude_effort) case "$v" in low|medium|high|xhigh|max) return 0 ;; *) _TASK_SETTING_ERR="effort must be: low | medium | high | xhigh | max";; esac ;;
    claude_model)  case "$v" in *[!a-zA-Z0-9._-]*) _TASK_SETTING_ERR="model: letters, digits, . _ - only";; *) return 0 ;; esac ;;
    lang)          case "$v" in *[!a-zA-Z_-]*|'') _TASK_SETTING_ERR="lang: a code like fr, en, pt-BR (letters, - or _)";; *) return 0 ;; esac ;;
    theme)         case "$v" in [a-z]*[!a-z-]*) _TASK_SETTING_ERR="theme: lowercase letters/hyphens, e.g. dark / light-daltonized";; [a-z]*) return 0 ;; *) _TASK_SETTING_ERR="theme: lowercase letters/hyphens, e.g. dark / light-daltonized";; esac ;;
    dns)           for t in $v; do case "$t" in *[!0-9a-fA-F.:]*|'') _TASK_SETTING_ERR="dns: space-separated IPs, e.g. 1.1.1.1 8.8.8.8"; return 1 ;; esac; done; return 0 ;;
    cpus)          case "$v" in ''|*[!0-9.]*|*.*.*|.) _TASK_SETTING_ERR="cpus: a positive number like 2 or 1.5";; *[1-9]*) return 0 ;; *) _TASK_SETTING_ERR="cpus must be > 0";; esac ;;
    ram)           case "$v" in *[!0-9mMgG]*) _TASK_SETTING_ERR="ram: digits + unit m/g, e.g. 512m or 4g";;
                     *[mMgG]) case "${v%[mMgG]}" in ''|*[!0-9]*) _TASK_SETTING_ERR="ram: digits + unit m/g, e.g. 512m or 4g";; *[1-9]*) return 0 ;; *) _TASK_SETTING_ERR="ram must be > 0";; esac ;;
                     *) _TASK_SETTING_ERR="ram needs a unit m or g, e.g. 512m / 4g";; esac ;;
  esac
  return 1
}

# Pretty current value for the list (— when unset; note the effective default).
_task_setting_show(){ local v; v="$(_task_cfg "$1")"
  if [ -n "$v" ]; then printf '%s' "$v"; else case "$1" in
    memory) printf 'repo (default)' ;; notify) printf 'off' ;; cpus) printf '2 (default)' ;; ram) printf '4g (default)' ;; *) printf '—' ;; esac; fi; }

# Pickable value choices for a setting, one per line as "<stored-value>|<label>" (empty value =
# clear/default). Returns 1 for free-form settings (lang/model/dns), which are typed instead.
_task_setting_choices(){ case "$1" in
  notify)        printf '%s\n' 'terminal_bell|terminal_bell — bell + flash when Claude is done / needs you' '|off — no notification' ;;
  memory)        printf '%s\n' 'repo|repo — per-repo memory (default)' 'global|global — shared across all repos' 'off|off — ephemeral, per task' ;;
  statusline)    printf '%s\n' '|default — keep the status line' 'off|off — hide it' ;;
  theme)         printf '%s\n' 'dark|dark' 'light|light' 'dark-daltonized|dark-daltonized' 'light-daltonized|light-daltonized' '|— unset (default)' ;;
  claude_mode)   printf '%s\n' 'auto|auto' 'acceptEdits|acceptEdits' 'bypassPermissions|bypassPermissions' 'default|default' '|— unset' ;;
  claude_effort) printf '%s\n' 'low|low' 'medium|medium' 'high|high' 'xhigh|xhigh' 'max|max' '|— unset' ;;
  *) return 1 ;;
esac; }

# Edit ONE setting: a value picker (arrow keys) for settings with a known set — so you can't even
# enter an invalid value — or a validated typed prompt for free-form ones (lang/model/dns).
_task_setting_edit(){
  local k="$1" choices; choices="$(_task_setting_choices "$k")"
  if [ -n "$choices" ]; then
    local -a labels=() vals=(); local val lab
    while IFS='|' read -r val lab; do vals+=("$val"); labels+=("$lab"); done <<< "$choices"
    _task_select "Set '$k'" "${labels[@]}" || return 0          # cancelled → leave unchanged
    _task_cfg_set "$k" "${vals[$_TASK_SEL_IDX]}"
    [ -n "${vals[$_TASK_SEL_IDX]}" ] && echo "  ✓ $k = ${vals[$_TASK_SEL_IDX]}" || echo "  ✓ $k cleared (default)"
    return 0
  fi
  # free-form: typed value with validation (Enter=keep · "-"=clear)
  local cur ans
  while :; do
    cur="$(_task_cfg "$k")"
    printf '\n  %s — %s\n  [now: %s · Enter=keep · "-"=clear] > ' "$k" "$(_task_setting_hint "$k")" "${cur:-none}" > /dev/tty
    read -r ans < /dev/tty || return 0
    case "$ans" in
      '') return 0 ;;
      '-') _task_cfg_set "$k" ""; echo "  ✓ $k cleared" > /dev/tty; return 0 ;;
      *) if _task_setting_validate "$k" "$ans"; then _task_cfg_set "$k" "$ans"; echo "  ✓ $k = $ans" > /dev/tty; return 0
         else echo "  ✗ $_TASK_SETTING_ERR" > /dev/tty; fi ;;
    esac
  done
}

# settings: an interactive MENU (arrow keys) — highlight a feature, Enter to change it (value picker
# for known sets, validated typing otherwise), "Done" to finish. Stored in <ws>/.config (no host env).
_task_settings(){
  local cf k; cf="$(_task_cfg_file)"
  local -a keys; mapfile -t keys < <(_task_setting_keys)
  if ! { true >/dev/tty; } 2>/dev/null; then          # non-interactive: just print the values
    echo "Workstation features (config: $cf):"
    for k in "${keys[@]}"; do printf '  %-13s %s\n' "$k" "$(_task_setting_show "$k")"; done
    return 0
  fi
  while :; do
    local -a rows=(); for k in "${keys[@]}"; do rows+=("$(printf '%-13s %s' "$k" "$(_task_setting_show "$k")")"); done
    rows+=("✔ Done")
    _task_select "Workstation features — pick one to change" "${rows[@]}" || break
    [ "$_TASK_SEL_IDX" -ge "${#keys[@]}" ] && break                # 'Done'
    _task_setting_edit "${keys[$_TASK_SEL_IDX]}"
  done
  echo "✓ Saved to $cf — applies to the next task (no host environment touched)."
}

# --- Claude credential SLOTS (independent, self-refreshing logins; one per concurrent task) ---
# A LOGIN is one INDEPENDENT Claude session under <ws>/.claude-slots/<name>/ — its own refresh token,
# possibly its own Anthropic account. A task uses it as the container's CLAUDE_CONFIG_DIR — a writable
# DIRECTORY, so Claude refreshes its own token in place (a single-file mount forbids the atomic rename
# Claude uses). Nothing is shared between logins or with the host, so concurrent multi-day tasks never
# clobber each other's token, and different logins can be different accounts. A login is "busy" while
# a task container labeled workstation.slot=<name> runs. 'task auth' manages them.

# List authed login names (one per line); a login is "authed" once it has credentials.
_task_slot_list(){ local sdir s; sdir="$(_task_slots_dir)"; [ -d "$sdir" ] || return 0
  for s in "$sdir"/*/; do [ -f "${s}.credentials.json" ] && basename "$s"; done; }

# Is login $1 in use by a running task container right now?
_task_slot_busy(){ local dock; dock="$(_task_dock)"; [ -n "$($dock ps -q --filter "label=workstation.slot=$1" 2>/dev/null)" ]; }

# A reservation bridges the gap between picking a login and its container getting the busy label —
# without it, simultaneous launches (e.g. 'resume' opening N tabs at once) would all grab the same
# "free" login and clobber one token. It's a FILE ($login/.reserved) holding an epoch stamp, claimed
# atomically by hard-linking a fully-written temp file onto it (`ln` fails if the target exists → our
# mutex, no flock). Because the content is written BEFORE the link, the file always has a valid stamp
# the instant it appears. Honored only while fresh (<60s) — by then the container is labeled (busy
# wins) or the launch died and the stale marker is cleared.
# Reservation markers live in a sibling dir (NOT inside the login dir, which is mounted as the
# container's /cfg) so they never leak into the container.
_task_resv_file(){ printf '%s' "$(_task_slots_dir)/.reservations/$1"; }
_task_slot_reserved_fresh(){
  local r at now; r="$(_task_resv_file "$1")"; [ -f "$r" ] || return 1
  at="$(<"$r")"; printf -v now '%(%s)T' -1
  case "$at" in (*[!0-9]*|'') return 0 ;; esac               # exists but unreadable → just-claimed, treat as held
  [ $(( now - at )) -lt 60 ]; }

# A login is AVAILABLE if it has creds, no running task uses it, and it isn't freshly reserved.
_task_slot_avail(){ local sdir; sdir="$(_task_slots_dir)"
  [ -f "$sdir/$1/.credentials.json" ] || return 1
  _task_slot_busy "$1" && return 1
  _task_slot_reserved_fresh "$1" && return 1
  return 0; }

# Atomically claim login $1: write the epoch to a private temp, then `ln` it onto the reservation
# (atomic; fails if held). Returns 0 on win. Lost to a FRESH reservation → 1; a STALE one is cleared.
_task_slot_reserve(){
  local r tmp rc; r="$(_task_resv_file "$1")"; tmp="$r.$BASHPID"
  mkdir -p "$(_task_slots_dir)/.reservations"
  printf '%(%s)T' -1 > "$tmp" 2>/dev/null || return 1
  if ln "$tmp" "$r" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if _task_slot_reserved_fresh "$1"; then rm -f "$tmp"; return 1; fi   # held & fresh → lost
  rm -f "$r" 2>/dev/null                                               # stale → clear and retry
  ln "$tmp" "$r" 2>/dev/null; rc=$?; rm -f "$tmp"; return "$rc"; }

# The Anthropic account (email) behind login $1, read from its .claude.json (no secret, no jq).
_task_login_account(){ _task_json_str "$(_task_slots_dir)/$1/.claude.json" emailAddress; }

# Token expiry of login $1 as an ISO-UTC string (or '?'). expiresAt is epoch MS; host `date` needs
# the leading '@' to read an epoch (verified on uutils coreutils, not just GNU).
_task_login_expiry(){ local ms; ms="$(_task_json_num "$(_task_slots_dir)/$1/.credentials.json" expiresAt)"
  [ "${#ms}" -ge 12 ] && date -u -d "@$((ms/1000))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?'; }

# One formatted login row (name · free/busy · account · expiry) — shared by `task auth` and `task list`.
_task_slot_line(){ local s="$1" acct busy
  acct="$(_task_login_account "$s")"; busy="$(_task_slot_busy "$s" && echo '[busy]' || echo '[free]')"
  printf '  %-14s %-6s %-32s token exp: %s\n' "$s" "$busy" "${acct:-?}" "$(_task_login_expiry "$s")"; }

# Browser login into login $1 (its OWN independent token / account), written into the login dir via
# CLAUDE_CONFIG_DIR. Returns 0 once .credentials.json exists. Used by 'task auth <name>' and the
# all-busy auto-prompt below.
_task_slot_login(){
  local sn="$1" ws_dir dock sdir; ws_dir="$(_task_wsdir)"; dock="$(_task_dock)"; sdir="$ws_dir/.claude-slots/$sn"
  mkdir -p "$sdir"
  echo "Logging into Claude for login '$sn' (its OWN independent token) — open the printed URL:"
  $dock run -it --rm -e CLAUDE_CONFIG_DIR=/cfg -v "$sdir:/cfg" workstation bash -lc 'claude auth login'
  [ -f "$sdir/.credentials.json" ]
}

# Choose a login for a clone → global _TASK_SLOT (empty = no logins exist → caller uses a token or
# errors). Tries the clone's sticky login first (so 'resume' reuses it), then the rest, CLAIMING one
# atomically via _task_slot_reserve. The mkdir-based claim means N simultaneous launches (resume
# opening many tabs) each win a DIFFERENT login — no lock daemon, pure bash. All busy + TTY → offer to
# create one on the spot. Returns 1 if none can be had.
_task_slot_acquire(){
  local dir="$1" sdir rec s; sdir="$(_task_slots_dir)"; _TASK_SLOT=""
  local -a authed; mapfile -t authed < <(_task_slot_list)
  [ "${#authed[@]}" -gt 0 ] || return 0                       # no logins → token-or-error in caller
  rec="$(cat "$dir/.git/claude-slot" 2>/dev/null || true)"
  for s in ${rec:+"$rec"} "${authed[@]}"; do                  # sticky first, then any other
    _task_slot_avail "$s" || continue
    if _task_slot_reserve "$s"; then                          # atomic win
      printf '%s' "$s" > "$dir/.git/claude-slot"; _TASK_SLOT="$s"; return 0
    fi
  done
  # all busy — offer to add one now (needs a real, openable controlling TTY for the browser login)
  if { true >/dev/tty; } 2>/dev/null; then
    local ans; printf 'All %d Claude login(s) are busy. Create a new login now? [name / Enter=skip]: ' "${#authed[@]}" > /dev/tty
    read -r ans < /dev/tty || ans=""
    ans="$(printf '%s' "$ans" | tr -cd 'A-Za-z0-9_-')"       # sanitize to a safe login name
    if [ -n "$ans" ]; then
      if _task_slot_login "$ans"; then
        _task_slot_reserve "$ans"; printf '%s' "$ans" > "$dir/.git/claude-slot"; _TASK_SLOT="$ans"; return 0
      else echo "task: login '$ans' failed." >&2; return 1; fi
    fi
  fi
  echo "task: all ${#authed[@]} Claude login(s) busy — exit a task to free one, or add: task auth <name>." >&2; return 1
}

# 'task auth' — the single hub for Claude credentials (logins). Each login is independent and
# self-refreshing, and can be a different Anthropic account.
#   task auth              list logins (account, free/busy, token expiry); offer to add one if none
#   task auth <name>       browser login into <name> (create it, or re-login an expired one)
#   task auth rm <name>    remove a login
_task_auth(){
  local sub="${1:-}" sdir s; sdir="$(_task_slots_dir)"
  case "$sub" in
    rm|remove|delete)
      local n="${2:-}"; [ -n "$n" ] || { echo "usage: task auth rm <name>"; return 1; }
      [ -d "$sdir/$n" ] || { echo "task: no login '$n'."; return 1; }
      _task_slot_busy "$n" && { echo "task: login '$n' is in use by a running task — exit it first."; return 1; }
      rm -rf "$sdir/$n" "$(_task_resv_file "$n")"; echo "removed login '$n'."; return 0 ;;
    '') : ;;                                              # fall through to list
    -*) echo "usage: task auth [<name> | rm <name>]"; return 1 ;;
    *)  _task_slot_login "$sub" && echo "login '$sub' ready ✓ — a task will pick it up automatically." \
                                || echo "login '$sub' not logged in (re-run 'task auth $sub')."; return 0 ;;
  esac
  # list
  local -a authed; mapfile -t authed < <(_task_slot_list)
  if [ "${#authed[@]}" -eq 0 ]; then
    echo "No Claude logins yet. Create one (a browser login; each is independent and self-refreshing):"
    echo "  task auth <name>        e.g. task auth default   (then 'task auth work', … for more accounts/parallel tasks)"
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "  (CLAUDE_CODE_OAUTH_TOKEN is set — headless tasks can run without a login.)"
    { true >/dev/tty; } 2>/dev/null || return 0
    printf 'Create one now? [name / Enter=skip]: '; local a; read -r a < /dev/tty || a=""
    a="$(printf '%s' "$a" | tr -cd 'A-Za-z0-9_-')"; [ -n "$a" ] && _task_slot_login "$a" >/dev/null && echo "login '$a' ready ✓"
    return 0
  fi
  echo "Claude logins (independent, self-refreshing):"
  for s in "${authed[@]}"; do _task_slot_line "$s"; done
  echo "  (task auth <name> to add · task auth rm <name> to remove)"
}

# Print "source|slot" for each running workstation container: source = the clone's /work mount
# (so we can map a container to its clone), slot = the login label. Go templates → no jq on the host.
# Shared by 'list' (running + login) and 'cleanup' (never delete a running clone).
_task_running_pairs(){
  local dock cid line; dock="$(_task_dock)"
  while IFS= read -r cid; do [ -n "$cid" ] || continue
    line="$($dock inspect -f '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}|{{index .Config.Labels "workstation.slot"}}' "$cid" 2>/dev/null)" || continue
    [ -n "${line%%|*}" ] && printf '%s\n' "$line"
  done < <($dock ps -q --filter ancestor=workstation 2>/dev/null)
}

# list: read-only status of every task clone — running/idle, which login, git state — plus a logins
# summary. Aggregates what 'auth' and 'cleanup' show via the shared helpers (so nothing drifts).
_task_list(){
  local -A run_slot=(); local src slot
  while IFS='|' read -r src slot; do run_slot["$src"]="$slot"; done < <(_task_running_pairs)

  local -a clones; mapfile -t clones < <(_task_all_clones)
  local c found st
  if [ "${#clones[@]}" -eq 0 ] && [ "${#run_slot[@]}" -eq 0 ]; then echo "task: no task clones."
  else
    echo "Tasks:"
    for c in "${clones[@]}"; do
      if [ -n "${run_slot[$c]+x}" ]; then slot="${run_slot[$c]}"
        [ -n "$slot" ] && st="● running · login=$slot" || st="● running · headless"
      else st="  idle"; fi
      printf '  %-44s %-26s %s\n' "$(_task_clone_label "$c")" "$st" "$(_task_git_state "$c")"
    done
    for src in "${!run_slot[@]}"; do                          # running but clone dir is gone
      found=0; for c in "${clones[@]}"; do [ "$c" = "$src" ] && { found=1; break; }; done
      [ "$found" = 0 ] && printf '  %-44s %-26s %s\n' "$(_task_clone_label "$src")" "● running (clone gone)" "${run_slot[$src]:+login=${run_slot[$src]}}"
    done
  fi
  local -a authed; mapfile -t authed < <(_task_slot_list); local s
  if [ "${#authed[@]}" -gt 0 ]; then echo; echo "Logins:"; for s in "${authed[@]}"; do _task_slot_line "$s"; done; fi
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

# Normalize "owner/name" → a stable key "owner-name" (lowercase, sanitized) — also a valid Docker
# image-name fragment. Used for the memory dir AND the per-repo toolchain image, so they agree.
_task_key_from_repo(){ local r="${1,,}"; r="${r//\//-}"; printf '%s' "${r//[^a-z0-9._-]/-}"; }

# Memory/toolchain key for a clone: "<owner>-<repo>" from its GitHub origin, so two same-named repos
# from different owners stay separate. Falls back to the clone's parent dir name (the short repo name)
# when there's no parseable github origin.
_task_repo_key(){
  local dir="$1" url r
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || url=""
  r="${url%.git}"; r="${r#*github.com[:/]}"                 # owner/name for github http or ssh remotes
  if [ -n "$r" ] && [ "$r" != "${url%.git}" ] && [[ "$r" == */* ]]; then _task_key_from_repo "$r"
  else printf '%s' "$(basename "$(dirname "$dir")")"; fi
}

# Per-repo TOOLCHAIN image. A repo that needs extra tools (Go/Rust/C++…) gets a Dockerfile at
# <ws>/toolchains/<key>/Dockerfile (host-side, NOT committed to the repo). `task` builds an image
# 'workstation-<key>' (FROM workstation — the shared image is the base) and runs that repo's tasks
# with it; repos without a spec use the plain 'workstation' image. So one repo's toolchains never
# bloat another. The 'FROM workstation' line is prepended automatically (don't write your own FROM).
_task_toolchain_dir(){ printf '%s' "$(_task_wsdir)/toolchains/$1"; }

# Is 'workstation-<key>' built AND current — i.e. the image exists, the Dockerfile hasn't changed
# since (mtime vs the .image-base stamp), and it was built against today's 'workstation' base id?
_task_image_fresh(){
  local key="$1" tdir df stamp img dock baseid curid
  tdir="$(_task_toolchain_dir "$key")"; df="$tdir/Dockerfile"; stamp="$tdir/.image-base"; img="workstation-$key"; dock="$(_task_dock)"
  $dock image inspect "$img" >/dev/null 2>&1 || return 1
  [ "$df" -nt "$stamp" ] && return 1
  baseid="$($dock image inspect -f '{{.Id}}' workstation 2>/dev/null || true)"
  curid="$(cat "$stamp" 2>/dev/null || true)"
  [ -n "$baseid" ] && [ "$curid" = "$baseid" ]
}

# Build lock for a toolchain key, so concurrent launches (e.g. resuming two tasks of the same repo at
# once) build the image ONCE — the rest wait, then reuse. Same lock-free pure-bash mutex as the login
# reservation: hard-link a fully-written temp onto the lock (`ln` fails if it exists). Markers live in a
# sibling .locks dir (NOT a key dir, so they're never a Dockerfile/build context). A stale lock (>1h:
# a build that long is broken anyway, or the holder died) is stolen so we never wedge forever.
_task_build_lock_file(){ printf '%s' "$(_task_wsdir)/toolchains/.locks/$1"; }
_task_build_lock_acquire(){
  local l tmp at now; l="$(_task_build_lock_file "$1")"; tmp="$l.$BASHPID"
  mkdir -p "$(dirname "$l")"
  printf '%(%s)T' -1 > "$tmp" 2>/dev/null || return 1
  if ln "$tmp" "$l" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  at="$(<"$l" 2>/dev/null)"; printf -v now '%(%s)T' -1
  case "$at" in (*[!0-9]*|'') rm -f "$tmp"; return 1 ;; esac                 # unreadable → just-claimed
  if [ $(( now - at )) -ge 3600 ]; then rm -f "$l" 2>/dev/null               # stale → steal
    if ln "$tmp" "$l" 2>/dev/null; then rm -f "$tmp"; return 0; fi; fi
  rm -f "$tmp"; return 1
}
_task_build_lock_release(){ rm -f "$(_task_build_lock_file "$1")" 2>/dev/null; }

# Ensure 'workstation-<key>' is built and current; echo the image name to use. Rebuilds lazily when
# the image is missing, the Dockerfile changed, or the base 'workstation' image moved (so an
# `update.sh` self-heals on the next task), serialized by a build lock so simultaneous launches build
# once. Build output is hidden unless it fails. Returns 1 on build failure. Caller falls back to
# plain 'workstation' when there's no spec.
_task_ensure_repo_image(){
  local key="$1" tdir img df stamp dock; tdir="$(_task_toolchain_dir "$key")"
  df="$tdir/Dockerfile"; stamp="$tdir/.image-base"; img="workstation-$key"; dock="$(_task_dock)"
  [ -f "$df" ] || { printf 'workstation'; return 0; }        # no spec → shared image
  _task_image_fresh "$key" && { printf '%s' "$img"; return 0; }

  # Need a (re)build. Serialize: first to grab the lock builds; the others WAIT then reuse. While
  # waiting, animate a single in-place line (cycling dots + elapsed) so it's clearly alive, not stuck,
  # without spamming. Re-check freshness ~every 3s (cheap acquire attempt every 0.5s for responsiveness).
  local t0=$SECONDS dots=0 n=0 anim=0 f
  { true >/dev/tty; } 2>/dev/null && [ -t 2 ] && anim=1
  [ "$anim" = 1 ] && printf '\033[?25l' >&2
  while ! _task_build_lock_acquire "$key"; do
    if [ $(( n % 6 )) -eq 0 ] && _task_image_fresh "$key"; then                # someone else finished it
      [ "$anim" = 1 ] && printf '\r\033[K\033[?25h' >&2; printf '%s' "$img"; return 0
    fi
    if [ "$anim" = 1 ]; then
      case $(( dots % 4 )) in 0) f="   " ;; 1) f=".  " ;; 2) f=".. " ;; 3) f="..." ;; esac
      printf '\r\033[K\033[2mtask: another build of %s in progress%s  (%ss)\033[0m' "$img" "$f" "$(( SECONDS - t0 ))" >&2
      dots=$(( dots + 1 )); n=$(( n + 1 )); sleep 0.5
    else
      [ "$n" = 0 ] && echo "task: another build of '$img' is running — waiting…" >&2
      n=$(( n + 1 )); sleep 3
    fi
  done
  [ "$anim" = 1 ] && printf '\r\033[K\033[?25h' >&2
  if _task_image_fresh "$key"; then _task_build_lock_release "$key"; printf '%s' "$img"; return 0; fi

  echo "task: building repo toolchain image '$img' (first run / spec or base changed)…" >&2
  local log rc=0 baseid fromline=""; log="$(mktemp)"
  baseid="$($dock image inspect -f '{{.Id}}' workstation 2>/dev/null || true)"
  grep -qiE '^[[:space:]]*FROM[[:space:]]' "$df" || fromline="FROM workstation"
  { [ -n "$fromline" ] && echo "$fromline"; cat "$df"; } | $dock build -t "$img" -f - "$tdir" >"$log" 2>&1 &
  if declare -F _ws_build_meter >/dev/null 2>&1; then _ws_build_meter "$log" "$!" "  building $img · " || rc=$?
  else wait "$!" || rc=$?; fi
  if [ "$rc" = 0 ]; then printf '%s' "$baseid" > "$stamp"
  else echo "task: toolchain image build FAILED for '$img' — last lines:" >&2; tail -25 "$log" >&2; fi
  rm -f "$log"; _task_build_lock_release "$key"
  [ "$rc" = 0 ] && printf '%s' "$img"; return "$rc"
}

# Run the container for an existing clone dir (auth + mounts + docker run). Used by start and 'open'.
_task_run(){
  local dir="$1" resume="${3:-}"
  [ -d "$dir" ] || { echo "task: no clone at $dir"; return 1; }
  local ws_dir dock; ws_dir="$(_task_wsdir)"; dock="$(_task_dock)"

  local gh_token; gh_token="$(gh auth token 2>/dev/null || true)"
  [ -z "$gh_token" ] && { echo "task: not logged into GitHub — run 'gh auth login' first."; return 1; }

  _task_ignore_mcp "$dir"   # keep Serena/MCP artifacts out of git status (clone-local exclude)

  # A short tab title ("<repo> - <topic>"), emitted from INSIDE the container at startup so it
  # replaces the long 'docker run …' command that VTE-based terminals (Ptyxis/GNOME) put in the title.
  # We do NOT disable Claude's own title management — once it sets a title, it takes over from here.
  local _tb _repo _topic _title
  _tb="$(basename "$dir")"; _repo="$(basename "$(dirname "$dir")")"; _topic="${_tb#*_}"
  [ "$_topic" = "$_tb" ] && _topic=""                      # name was just a timestamp → no topic
  _title="$_repo${_topic:+ - $_topic}"

  # Stable, unique container name derived from the clone (<repo>-<clone>) — identical for start and
  # resume, and a natural guard against launching the same clone twice. The repo is included so two
  # same-named clones under different bases (--here/--at) don't collide.
  local _cname; _cname="task-${_repo}-${_tb}"; _cname="${_cname//[^a-zA-Z0-9_.-]/-}"
  if [ -n "$($dock ps -aq --filter "name=^/${_cname}$" 2>/dev/null)" ]; then
    echo "task: a container named '$_cname' already exists — this task may be running, or it's an orphan." >&2
    echo "      free it with:  $dock rm -f $_cname" >&2
    return 1
  fi

  # Repo key (shared by memory + toolchain image). If this repo declares a toolchain Dockerfile, run
  # with its 'workstation-<key>' image (built/refreshed lazily); else the shared 'workstation'. Resolve
  # BEFORE acquiring a login so a build failure can't leave a reservation behind.
  local _repokey image; _repokey="$(_task_repo_key "$dir")"
  image="$(_task_ensure_repo_image "$_repokey")" || return 1

  # Claude launch flags from the config (env override wins; 'task settings' edits them):
  # claude_mode → --permission-mode, claude_model → --model, claude_effort → --effort.
  local -a cflags=()
  local _m _md _ef; _m="$(_task_cfg claude_mode)"; _md="$(_task_cfg claude_model)"; _ef="$(_task_cfg claude_effort)"
  [ -n "$_m" ]  && cflags+=(--permission-mode "$_m")
  [ -n "$_md" ] && cflags+=(--model "$_md")
  [ -n "$_ef" ] && cflags+=(--effort "$_ef")

  # Optional features are passed as env vars and assembled into the `claude --settings` JSON INSIDE the
  # container (with the image's jq) — so the JSON is always well-formed even for ad-hoc env overrides,
  # and the host needs no jq. notify → preferredNotifChannel, lang → language, theme → theme,
  # statusline=off → statusLine:null, memory → autoMemoryDirectory (below).
  local _notify _lang _theme _sl
  _notify="$(_task_cfg notify)"; _lang="$(_task_cfg lang)"; _theme="$(_task_cfg theme)"; _sl="$(_task_cfg statusline)"

  # Persist Claude's auto-memory ACROSS future tasks (per-repo by design, but each task is a fresh
  # /work so it'd be lost). 'memory': repo (default — keyed by <owner>-<repo> from the clone's origin,
  # so same-named repos from different owners stay separate), global (all repos), off (per task). We
  # point autoMemoryDirectory at a mounted host dir under <ws>/.memory (self-contained, host-clean).
  local -a memmount=()
  local _mem _memdir _wsmem=""; _mem="$(_task_cfg memory)"; [ -z "$_mem" ] && _mem=repo
  if [ "$_mem" != off ]; then
    if [ "$_mem" = global ]; then _memdir="$ws_dir/.memory/_global"
    else _memdir="$ws_dir/.memory/$_repokey"; fi
    mkdir -p "$_memdir"
    memmount=(-v "$_memdir:/memory"); _wsmem=/memory
  fi
  local -a featenv=(-e "WS_NOTIFY=$_notify" -e "WS_LANG=$_lang" -e "WS_THEME=$_theme" -e "WS_SL=$_sl" -e "WS_MEMDIR=$_wsmem")

  # Docker resource limits (NOT the Claude auto-memory above): config 'cpus'/'ram', defaults 2 / 4g.
  local _cpus _ram; _cpus="$(_task_cfg cpus)"; _ram="$(_task_cfg ram)"

  # Conversation history persists per-clone on the HOST (survives the disposable --rm container; resume
  # continues it). Inside .git/ so it's out of the worktree and removed with the clone. mkdir first so
  # the bind source is owned by the host user (uid 1000 = the image's 'dev'), not root-created by docker.
  local proj="$dir/.git/claude-projects"; mkdir -p "$proj"
  local -a resume_env=(); [ -n "$resume" ] && resume_env=(-e WS_RESUME=1)

  # Pick a login (independent, self-refreshing). None exist → fall back to a headless token, else error.
  _task_slot_acquire "$dir" || return 1
  local slot="$_TASK_SLOT"

  local -a claude_auth=() cfg_mounts=() session=() claude_cmd=()
  if [ -n "$slot" ]; then
    # ---- LOGIN MODE: CLAUDE_CONFIG_DIR = the login dir (a writable DIRECTORY) → Claude refreshes its
    # own independent token in place and persists it for the next task (survives days). The clone's
    # history is overlaid at /cfg/projects (resume stays per-clone); the label marks the login busy.
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
      S="$(jq -cn --arg n "$WS_NOTIFY" --arg l "$WS_LANG" --arg t "$WS_THEME" --arg s "$WS_SL" --arg m "$WS_MEMDIR" "{}
        | (if \$n != \"\" then .preferredNotifChannel = \$n else . end)
        | (if \$l != \"\" then .language = \$l else . end)
        | (if \$t != \"\" then .theme = \$t else . end)
        | (if \$s == \"off\" then .statusLine = null else . end)
        | (if \$m != \"\" then .autoMemoryDirectory = \$m else . end)" 2>/dev/null)"
      [ -n "$S" ] && [ "$S" != "{}" ] && set -- --settings "$S" "$@"
      [ -n "${WORKSTATION_TAB_TITLE:-}" ] && printf "\033]0;%s\a" "$WORKSTATION_TAB_TITLE"   # short tab title (Claude may update it later)
      exec claude "$@"' _ "${cflags[@]}")
    echo "task: Claude login '$slot'${slot:+ ($(_task_login_account "$slot" 2>/dev/null))}."
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    # ---- HEADLESS TOKEN MODE: no stored login, authenticate with CLAUDE_CODE_OAUTH_TOKEN (ephemeral,
    # no refresh persistence). Config = baked image + read-only seeds; history mounted per-clone.
    claude_auth=(-e CLAUDE_CODE_OAUTH_TOKEN)
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
      S="$(jq -cn --arg n "$WS_NOTIFY" --arg l "$WS_LANG" --arg t "$WS_THEME" --arg s "$WS_SL" --arg m "$WS_MEMDIR" "{}
        | (if \$n != \"\" then .preferredNotifChannel = \$n else . end)
        | (if \$l != \"\" then .language = \$l else . end)
        | (if \$t != \"\" then .theme = \$t else . end)
        | (if \$s == \"off\" then .statusLine = null else . end)
        | (if \$m != \"\" then .autoMemoryDirectory = \$m else . end)" 2>/dev/null)"
      [ -n "$S" ] && [ "$S" != "{}" ] && set -- --settings "$S" "$@"
      [ -n "${WORKSTATION_TAB_TITLE:-}" ] && printf "\033]0;%s\a" "$WORKSTATION_TAB_TITLE"   # short tab title (Claude may update it later)
      exec claude "$@"' _ "${cflags[@]}")
  else
    echo "task: no Claude login — create one with 'task auth <name>' (or set CLAUDE_CODE_OAUTH_TOKEN for headless)." >&2
    return 1
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
    --name "$_cname" \
    -v "$dir:/work" -w /work \
    -e GH_TOKEN="$gh_token" \
    -e WORKSTATION_TAB_TITLE="$_title" \
    "${claude_auth[@]}" \
    "${cfg_mounts[@]}" \
    "${featenv[@]}" \
    "${gitenv[@]}" \
    "${dns[@]}" \
    "${session[@]}" \
    "${memmount[@]}" \
    "${resume_env[@]}" \
    --memory="${_ram:-4g}" --cpus="${_cpus:-2}" \
    "$image" "${claude_cmd[@]}"

  [ -n "$slot" ] && rm -f "$(_task_resv_file "$slot")" 2>/dev/null   # free the login immediately on exit
  echo "↩  Container disposed. Clone (on host): $dir"
  echo "   When it's clean and pushed, 'task cleanup' will remove it."
}

# Resolve a repo argument to "owner/name": an explicit owner/name or URL is taken as-is; otherwise
# fuzzy-matched against your gh repos (exact short-name, then substring), prompting the arrow picker
# when ambiguous/unmatched/empty. Echoes the result on stdout (info lines go to stderr); 1 on cancel.
_task_resolve_repo(){
  local repo="$1" orig="$1"
  case "$repo" in */*|*://*) printf '%s\n' "$repo"; return 0 ;; esac
  local -a known=(); mapfile -t known < <(gh repo list --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null)
  [ -z "$repo" ] && { _task_pick "${known[@]}"; return $?; }
  [ "${#known[@]}" -gt 0 ] || { printf '%s\n' "$repo"; return 0; }       # offline / no gh → take as-is
  local -a exact=() subs=(); local r name
  for r in "${known[@]}"; do name="${r##*/}"
    if   [[ "${name,,}" == "${repo,,}" ]]; then exact+=("$r")
    elif [[ "${name,,}" == *"${repo,,}"* || "${repo,,}" == *"${name,,}"* ]]; then subs+=("$r"); fi
  done
  if   [ "${#exact[@]}" -eq 1 ]; then printf '%s\n' "${exact[0]}"
  elif [ "${#exact[@]}" -gt 1 ]; then echo "task: '$orig' matches several repos — pick one:" >&2; _task_pick "${exact[@]}"
  elif [ "${#subs[@]}"  -eq 1 ]; then echo "task: '$orig' → ${subs[0]}" >&2; printf '%s\n' "${subs[0]}"
  elif [ "${#subs[@]}"  -gt 1 ]; then echo "task: '$orig' matches several repos — pick one:" >&2; _task_pick "${subs[@]}"
  else echo "task: no repo matches '$orig' — pick one (or type owner/name or a URL):" >&2; _task_pick "${known[@]}"; fi
}

# Existing toolchain spec keys (dirs under <ws>/toolchains that carry a Dockerfile), one per line.
_task_toolchain_list(){ local d root; root="$(_task_wsdir)/toolchains"; [ -d "$root" ] || return 0
  for d in "$root"/*/; do [ -f "${d}Dockerfile" ] && basename "$d"; done; }

# Open the Dockerfile for key $1 in an editor ($EDITOR/$VISUAL, else nano/vim/vi); print the path if none.
_task_toolchain_open(){
  local key="$1" df ed c; df="$(_task_toolchain_dir "$key")/Dockerfile"; [ -f "$df" ] || return 1
  ed="${EDITOR:-${VISUAL:-}}"; [ -z "$ed" ] && for c in nano vim vi; do command -v "$c" >/dev/null 2>&1 && { ed="$c"; break; }; done
  if [ -n "$ed" ] && { true >/dev/tty; } 2>/dev/null; then "$ed" "$df" >/dev/tty 2>&1 </dev/tty || true
  else echo "  edit: $df"; fi
}

# Create the toolchain dir + template Dockerfile for key $1 if missing.
_task_toolchain_scaffold(){
  local key="$1" tdir df; tdir="$(_task_toolchain_dir "$key")"; df="$tdir/Dockerfile"; mkdir -p "$tdir"
  [ -f "$df" ] && { echo "  spec: $df"; return 0; }
  cat > "$df" <<'TPL'
# Per-repo toolchains for this repo's task containers. Built as 'workstation-<key>' FROM the shared
# 'workstation' image — do NOT add your own FROM. apk = Wolfi packages. Runs as root; end as 'dev'.
USER root
# RUN apk add --no-cache go-1.25 golangci-lint rustup \
#     clang-17 clang-17-extras compiler-rt-17 binutils lld-17 make cmake ninja-build \
#     glibc-dev build-base
# RUN rustup toolchain install stable nightly && rustup component add clippy miri
USER dev
TPL
  echo "  created: $df"
}

# Remove a toolchain spec (and its built image), after confirmation.
_task_toolchain_remove(){
  local key="$1" tdir img dock a; tdir="$(_task_toolchain_dir "$key")"; img="workstation-$key"; dock="$(_task_dock)"
  printf '  remove toolchain "%s" (spec dir + image %s)? [y/N]: ' "$key" "$img" > /dev/tty
  read -r a < /dev/tty || a=n; case "$a" in y|Y|yes|YES) : ;; *) echo "  kept" > /dev/tty; return 0 ;; esac
  $dock rmi -f "$img" >/dev/null 2>&1
  rm -rf "$tdir"
  echo "  removed toolchain '$key'." > /dev/tty
}

# Resolve a repo arg → its toolchain key (owner-repo), scaffold + open its Dockerfile.
_task_toolchain_add(){
  local repo r key
  repo="$(_task_resolve_repo "${1:-}")" || { echo "task: no repo chosen." >&2; return 1; }
  [ -n "$repo" ] || { echo "task: no repo." >&2; return 1; }
  r="${repo%.git}"; r="${r#*github.com[:/]}"; key="$(_task_key_from_repo "$r")"
  _task_toolchain_scaffold "$key"
  echo "  the next 'task ${repo##*/} …' rebuilds 'workstation-$key' (FROM workstation)."
  _task_toolchain_open "$key"
}

# toolchain: manage per-repo toolchains (host-side, NOT committed to the repo) — like 'settings'.
#   task toolchain            interactive menu: add / edit / remove specs (arrow keys)
#   task toolchain <repo>     jump straight to scaffolding/editing that repo's spec
_task_toolchain(){
  [ -n "${1:-}" ] && { _task_toolchain_add "$1"; return $?; }
  if ! { true >/dev/tty; } 2>/dev/null; then          # non-interactive: just list
    echo "Per-repo toolchains ($(_task_wsdir)/toolchains):"
    local k; for k in $(_task_toolchain_list); do printf '  %s\n' "$k"; done
    return 0
  fi
  local dock; dock="$(_task_dock)"
  while :; do
    local -a keys; mapfile -t keys < <(_task_toolchain_list)
    local -a rows=(); local k built
    for k in "${keys[@]}"; do
      $dock image inspect "workstation-$k" >/dev/null 2>&1 && built="image built" || built="not built yet"
      rows+=("$(printf '%-42s %s' "$k" "$built")")
    done
    rows+=("➕ Add toolchains for a repo…" "✔ Done")
    _task_select "Per-repo toolchains — pick one" "${rows[@]}" || break
    if   [ "$_TASK_SEL_IDX" -ge "$(( ${#keys[@]} + 1 ))" ]; then break                       # Done
    elif [ "$_TASK_SEL_IDX" -eq "${#keys[@]}" ]; then _task_toolchain_add ""                 # Add
    else
      local key="${keys[$_TASK_SEL_IDX]}"
      _task_select "Toolchain '$key'" "Edit Dockerfile" "Remove" "Cancel" || continue
      case "$_TASK_SEL_IDX" in 0) _task_toolchain_open "$key" ;; 1) _task_toolchain_remove "$key" ;; esac
    fi
  done
  echo "✓ Toolchains live in $(_task_wsdir)/toolchains — applied (rebuilt) on each repo's next task."
}

task() {
  case "${1:-}" in
    ''|-h|--help|help|man|'?') _task_help; return 0 ;;
    resume)   _task_resume; return $? ;;
    cleanup)  shift; _task_cleanup "$@"; return $? ;;
    list|ls|ps) _task_list; return $? ;;
    settings) _task_settings; return $? ;;
    toolchain|toolchains) shift; _task_toolchain "$@"; return $? ;;
    open)    [ -n "${2:-}" ] || { echo "usage: task open <clone-dir>"; return 1; }; _task_run "$2" "$(basename "$2")" resume; return $? ;;
    auth)    shift; _task_auth "$@"; return $? ;;
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
  # Canonicalize the base so the clone path, the recorded base, and Docker's mount source all agree
  # (so `task list` matches running containers to their clone, and `.bases` doesn't get dup entries).
  base="$(realpath -m "$base" 2>/dev/null || printf '%s' "$base")"

  local repo="${1:-}" topic="${2:-}"
  if [ -z "$repo" ] && ! [ -r /dev/tty ]; then echo "usage: task [--here | --at <path>] <repo> [topic]   (try 'task help')"; return 1; fi
  repo="$(_task_resolve_repo "$repo")" || { echo "task: no repo chosen."; return 1; }
  [ -z "$repo" ] && { echo "task: no repo."; return 1; }

  # pre-check GitHub auth (clone needs it) for a clear early error
  gh auth token >/dev/null 2>&1 || { echo "task: not logged into GitHub — run 'gh auth login' first."; return 1; }

  local slug ts dir
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(printf '%s' "$topic" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  if [ -n "$slug" ]; then dir="$base/${repo##*/}/${ts}_$slug"
  else slug="$ts"; dir="$base/${repo##*/}/$ts"; fi
  mkdir -p "$(dirname "$dir")"
  _task_base_record "$base"           # so resume/cleanup/list find clones made with --here/--at

  gh repo clone "$repo" "$dir" || return 1
  ( cd "$dir" && git switch -c "task/$slug" && git push -u origin "task/$slug" )

  _task_run "$dir" "$slug"
}

# Repo chooser used by repo resolution: the same arrow-key picker as 'resume'/'settings', plus a
# "type manually" entry so owner/name or a URL is still accepted. Echoes the choice; 1 on cancel/no-TTY.
# (The fast path — `task owner/name [topic]` — never reaches here; the picker only shows when the repo
# is omitted, ambiguous, or unmatched.)
_task_pick(){
  local -a opts=("$@"); local manual='✎ type owner/name or a URL'
  _task_select "Which repo?" "${opts[@]}" "$manual" || return 1
  if [ "$_TASK_SEL" = "$manual" ]; then
    printf 'repo (owner/name or URL) > ' > /dev/tty; local p; read -r p < /dev/tty || return 1
    [ -n "$p" ] && printf '%s\n' "$p" || return 1
  else printf '%s\n' "$_TASK_SEL"; fi
}

# Bash completion for `task`. Registering an explicit spec is also what STOPS bash-completion's shipped
# generic loader (/usr/share/bash-completion/completions/_task) from kicking in: that loader runs
# `task --completion bash` and eval's the output (it targets the go-task binary). Since `task` is our
# function, that errored noisily — with our own spec, bash never falls back to it.
_task_complete(){
  COMPREPLY=()
  local cur prev cword sub
  cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"; cword=$COMP_CWORD
  sub="${COMP_WORDS[1]:-}"

  if [ "$prev" = "--at" ]; then compopt -o dirnames 2>/dev/null; return 0; fi   # --at <path>
  if [ "$cword" -le 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "list cleanup resume open settings toolchain auth help --here --at" -- "$cur")
    return 0
  fi
  case "$sub" in
    cleanup)              # -f/-y, or an existing clone label to discard
      local clones; clones="$(_task_all_clones 2>/dev/null | while IFS= read -r c; do _task_clone_label "$c"; done | tr '\n' ' ')"
      mapfile -t COMPREPLY < <(compgen -W "-f -y $clones" -- "$cur") ;;
    open)     compopt -o dirnames 2>/dev/null ;;                                # open <clone-dir>
    toolchain|toolchains)
      mapfile -t COMPREPLY < <(compgen -W "$(_task_toolchain_list 2>/dev/null | tr '\n' ' ')" -- "$cur") ;;
    auth)
      if [ "$cword" -eq 2 ]; then
        mapfile -t COMPREPLY < <(compgen -W "rm $(_task_slot_list 2>/dev/null | tr '\n' ' ')" -- "$cur")
      elif [ "${COMP_WORDS[2]:-}" = "rm" ]; then
        mapfile -t COMPREPLY < <(compgen -W "$(_task_slot_list 2>/dev/null | tr '\n' ' ')" -- "$cur")
      fi ;;
  esac
  return 0
}
complete -F _task_complete task
