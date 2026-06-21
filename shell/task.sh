# task — open ISOLATED Claude sessions in disposable Docker containers.
#
#   task [--here | --at <path>] <repo> [topic]   start: repo fuzzy-matched to your gh repos
#                                                (asks if ambiguous/none); topic → timestamp if omitted.
#   task resume                                  reopen task clones in new tabs, CONTINUING the Claude session.
#   task cleanup [-y]                            delete clones that are clean AND fully pushed (asks; -y skips).
#   task settings                                show/edit features (notifications, language, memory, DNS, …).
#   task auth [<name> | rm <name>]               manage Claude logins (independent, self-refreshing accounts).
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
  task settings                                Show/edit features: notifications, language, theme, status
                                               line, memory persistence, DNS, and the Claude launch
                                               defaults. Stored in <ws>/.config (no host env), applied
                                               to the next task.
  task auth                                    List Claude logins (account, free/busy, token expiry).
  task auth <name>                             Browser-login into <name> — an INDEPENDENT, self-refreshing
                                               login (its own token, can be its own Anthropic account).
                                               A task auto-borrows a free login; run several for parallel
                                               long tasks. 'task auth rm <name>' removes one.
  task help                                    This help.

Features are configured with 'task settings' (stored in <ws>/.config, not host env). They apply to
the next task with no rebuild: notifications (terminal bell), language, theme, status line, per-repo
memory persistence, reliable DNS, and Claude launch defaults (permission-mode / model / effort — the
container is the sandbox, so 'auto' is reasonable). Each also takes a one-off env override
(WORKSTATION_NOTIFY, WORKSTATION_CLAUDE_MODE, …) that is never written to your shell.

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
# The editable feature keys, in display order.
_task_setting_keys(){ printf '%s\n' notify memory lang theme statusline dns claude_mode claude_model claude_effort; }

# One-line hint shown for a setting (allowed values / format + what "clear" means).
_task_setting_hint(){ case "$1" in
  notify)        echo 'terminal_bell (bell+flash when Claude is done/needs you) · clear = off' ;;
  memory)        echo 'repo (per-repo, default) · global (all repos) · off (per task)' ;;
  lang)          echo 'Claude UI language code, e.g. fr / en / pt-BR · clear = Claude default' ;;
  theme)         echo 'dark · light · dark-daltonized · light-daltonized · clear = default' ;;
  statusline)    echo 'off = hide the status line · clear = keep the default/imported one' ;;
  dns)           echo 'space-separated IPs, e.g. "1.1.1.1 8.8.8.8" · clear = host resolver' ;;
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
  esac
  return 1
}

# Pretty current value for the list (— when unset; note the effective default).
_task_setting_show(){ local v; v="$(_task_cfg "$1")"
  if [ -n "$v" ]; then printf '%s' "$v"; else case "$1" in
    memory) printf 'repo (default)' ;; notify) printf 'off' ;; *) printf '—' ;; esac; fi; }

# settings: a MENU — pick a feature to change (no need to step through all of them), with validation
# (invalid values are rejected, not silently accepted). Stored in <ws>/.config (no host env).
_task_settings(){
  local cf; cf="$(_task_cfg_file)"
  local -a keys; mapfile -t keys < <(_task_setting_keys)
  if ! { true >/dev/tty; } 2>/dev/null; then          # non-interactive: just print the values
    echo "Workstation features (config: $cf):"
    local k; for k in "${keys[@]}"; do printf '  %-13s %s\n' "$k" "$(_task_setting_show "$k")"; done
    return 0
  fi
  while :; do
    echo
    echo "Workstation features  (saved to $cf · applied to the next task):"
    local i=1 k
    for k in "${keys[@]}"; do printf '  %2d) %-13s %s\n' "$i" "$k" "$(_task_setting_show "$k")"; i=$((i+1)); done
    printf '  Edit which? [number or name · q to finish]: '
    local pick; read -r pick < /dev/tty || break
    case "$pick" in
      ''|q|Q|quit|done) break ;;
      *[!0-9]*) k="$pick" ;;                          # a name
      *) k="${keys[$((pick-1))]:-}" ;;               # a number
    esac
    _task_setting_keys | grep -qxF "${k:-}" || { echo "  ? no such setting: '$pick'"; continue; }
    # edit loop for this key, with validation
    local cur ans
    while :; do
      cur="$(_task_cfg "$k")"
      printf '  %s\n    %s\n    [now: %s · Enter=keep · "-"=clear] > ' "$k" "$(_task_setting_hint "$k")" "${cur:-none}"
      read -r ans < /dev/tty || break
      case "$ans" in
        '') break ;;
        '-') _task_cfg_set "$k" ""; echo "  ✓ $k cleared"; break ;;
        *) if _task_setting_validate "$k" "$ans"; then _task_cfg_set "$k" "$ans"; echo "  ✓ $k = $ans"; break
           else echo "  ✗ $_TASK_SETTING_ERR"; fi ;;
      esac
    done
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

# The Anthropic account (email) behind login $1, read from its .claude.json (no secret).
_task_login_account(){ jq -r '.oauthAccount.emailAddress // empty' "$(_task_slots_dir)/$1/.claude.json" 2>/dev/null; }

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
  local sub="${1:-}" sdir s exp acct busy; sdir="$(_task_slots_dir)"
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
  for s in "${authed[@]}"; do
    exp="$(jq -r '(.claudeAiOauth.expiresAt/1000)|todate' "$sdir/$s/.credentials.json" 2>/dev/null || echo '?')"
    acct="$(_task_login_account "$s")"; busy="$(_task_slot_busy "$s" && echo '[busy]' || echo '[free]')"
    printf '  %-14s %-6s %-32s token exp: %s\n' "$s" "$busy" "${acct:-?}" "$exp"
  done
  echo "  (task auth <name> to add · task auth rm <name> to remove)"
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

  [ -n "$slot" ] && rm -f "$(_task_resv_file "$slot")" 2>/dev/null   # free the login immediately on exit
  echo "↩  Container disposed. Clone (on host): $dir"
  echo "   When it's clean and pushed, 'task cleanup' will remove it."
}

task() {
  case "${1:-}" in
    ''|-h|--help|help|man|'?') _task_help; return 0 ;;
    resume)   _task_resume; return $? ;;
    cleanup)  shift; _task_cleanup "$@"; return $? ;;
    settings) _task_settings; return $? ;;
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
