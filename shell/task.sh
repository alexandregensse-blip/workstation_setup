# task — open an ISOLATED Claude session in a container.
#
#   task [--here | --at <path>] [repo] [topic]   # repo: prompted if omitted; topic: defaults to a timestamp
#   task auth                                     # (re)login to Claude; stored in <workspace>/.workstation/.claude
#
# Container-only: the host has NO Claude/Serena/rtk — they live in the 'workstation' image.
# Clone base (priority): --here ($PWD) > --at <path> > $WORKSTATION_RUNNING
#   > ${WORKSTATION_HOME:-$HOME/dev}/running.
#
# Clones on the HOST (WIP survives the disposable container), creates the branch, then runs
# Claude INSIDE the container. Auth:
#   - GitHub : gh token via env (host must be logged in: 'gh auth login').
#   - Claude : credentials stored in the self-contained <workstation>/.claude, mounted
#              read-only, else $CLAUDE_CODE_OAUTH_TOKEN, else a clear error ('task auth').
# Docker auto-falls back to sudo if the docker group isn't active yet. No hardcoded paths.
task() {
  local ws_dir="${WORKSTATION_DIR:-${WORKSTATION_HOME:-$HOME/dev}/.workstation}"
  local dock; dock=docker; docker info >/dev/null 2>&1 || dock="sudo docker"

  # one-off: get Claude creds into the workstation dir — reuse an existing host login if present,
  # else log in inside the image. Host ~/.claude is only read, never modified.
  if [ "${1:-}" = "auth" ]; then
    mkdir -p "$ws_dir/.claude"
    if [ -f "$HOME/.claude/.credentials.json" ] && [ ! -f "$ws_dir/.claude/.credentials.json" ]; then
      local acct a
      acct="$(grep -oE '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]+"' "$HOME/.claude.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
      [ -z "$acct" ] && acct="unknown account"
      printf 'Reuse the Claude login already on this machine (account: %s)? [Y/n]: ' "$acct"
      read -r a || a=y
      case "$a" in n|N|no|NO) ;; *)
        cp "$HOME/.claude/.credentials.json" "$ws_dir/.claude/.credentials.json"
        chmod 600 "$ws_dir/.claude/.credentials.json"
        echo "reused host credentials for $acct ✓"; return 0 ;;
      esac
    fi
    $dock run -it --rm -v "$ws_dir/.claude:/seed" workstation \
      bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json'
    return $?
  fi

  local base="${WORKSTATION_RUNNING:-${WORKSTATION_HOME:-$HOME/dev}/running}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --here) base="$PWD"; shift ;;
      --at)   base="${2:?--at requires a path}"; shift 2 ;;
      --)     shift; break ;;
      -*)     echo "task: unknown option '$1'"; return 1 ;;
      *)      break ;;
    esac
  done

  local repo="${1:-}" topic="${2:-}"

  # repo: if not given, offer known repos (from gh) to pick from, or type owner/name or a URL
  if [ -z "$repo" ]; then
    if [ -r /dev/tty ]; then
      local -a known; mapfile -t known < <(gh repo list --limit 30 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null)
      if [ "${#known[@]}" -gt 0 ]; then
        echo "Which repo? (known repos below — pick a number, or type owner/name or a URL)"
        local i=1 r; for r in "${known[@]}"; do printf '  %2d) %s\n' "$i" "$r"; i=$((i+1)); done
      else
        echo "Which repo? (type owner/name or a URL — 'gh auth login' to list yours)"
      fi
      local pick; printf 'repo: '; read -r pick < /dev/tty
      case "$pick" in
        '')        echo "task: no repo given."; return 1 ;;
        *[!0-9]*)  repo="$pick" ;;                    # contains a non-digit → explicit name/URL
        *)         repo="${known[$((pick-1))]:-}" ;;  # all digits → index into the list
      esac
      [ -z "$repo" ] && { echo "task: invalid selection."; return 1; }
    else
      echo "usage: task [--here | --at <path>] [repo] [topic]   |   task auth"; return 1
    fi
  fi

  # --- auth, checked up front (clear errors, no silent failure) ---
  local gh_token; gh_token="$(gh auth token 2>/dev/null || true)"
  if [ -z "$gh_token" ]; then
    echo "task: not logged into GitHub — run 'gh auth login' first."; return 1
  fi
  local creds="$ws_dir/.claude/.credentials.json"
  local -a claude_auth
  if [ -f "$creds" ]; then
    claude_auth=(-v "$creds:/home/dev/.claude/.credentials.json:ro")
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    claude_auth=(-e CLAUDE_CODE_OAUTH_TOKEN)
  else
    echo "task: no Claude credentials found."
    echo "  → run 'task auth' (browser login, stored in $ws_dir/.claude), or set CLAUDE_CODE_OAUTH_TOKEN."
    return 1
  fi

  local slug ts dir
  ts=$(date +%Y%m%d-%H%M%S)
  slug=$(printf '%s' "$topic" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  if [ -n "$slug" ]; then
    dir="$base/${repo##*/}/${ts}_$slug"
  else
    slug="$ts"                                  # no topic given → the timestamp is the task name
    dir="$base/${repo##*/}/$ts"
  fi
  mkdir -p "$(dirname "$dir")"

  gh repo clone "$repo" "$dir" || return 1
  ( cd "$dir" && git switch -c "task/$slug" && git push -u origin "task/$slug" )

  # optional per-machine config overrides (imported prefs / statusline / gh config), over the baked
  local -a cfg_mounts=()
  [ -f "$ws_dir/.claude/settings.json" ] && cfg_mounts+=(-v "$ws_dir/.claude/settings.json:/home/dev/.claude/settings.json:ro")
  [ -f "$ws_dir/.claude/statusline.sh" ]  && cfg_mounts+=(-v "$ws_dir/.claude/statusline.sh:/home/dev/.claude/statusline.sh:ro")
  [ -f "$ws_dir/gh/config.yml" ]          && cfg_mounts+=(-v "$ws_dir/gh/config.yml:/home/dev/.config/gh/config.yml:ro")

  # git identity for in-container commits (attribution only — name/email, no secret), from host git
  local gname gemail
  gname="$(git config --get user.name 2>/dev/null || true)"
  gemail="$(git config --get user.email 2>/dev/null || true)"
  local -a gitenv=()
  [ -n "$gname" ]  && gitenv+=(-e "GIT_AUTHOR_NAME=$gname"   -e "GIT_COMMITTER_NAME=$gname")
  [ -n "$gemail" ] && gitenv+=(-e "GIT_AUTHOR_EMAIL=$gemail" -e "GIT_COMMITTER_EMAIL=$gemail")

  # audio passthrough for sound plugins (e.g. peon-ping): only if the image asked for it AND a
  # host audio server is present — degrades to silent otherwise (e.g. headless). uid 1000 matches.
  local xdg="/run/user/$(id -u)"
  local -a audio=()
  if [ -f "$ws_dir/.audio" ] && [ -S "$xdg/pulse/native" ]; then
    audio=(-e "XDG_RUNTIME_DIR=$xdg" -e "PULSE_SERVER=unix:$xdg/pulse/native" \
           -v "$xdg/pulse/native:$xdg/pulse/native")
    [ -f "$HOME/.config/pulse/cookie" ] && audio+=(-v "$HOME/.config/pulse/cookie:/home/dev/.config/pulse/cookie:ro")
  fi

  $dock run -it --rm \
    --name "task-$slug" \
    -v "$dir:/work" -w /work \
    -e GH_TOKEN="$gh_token" \
    "${claude_auth[@]}" \
    "${cfg_mounts[@]}" \
    "${gitenv[@]}" \
    "${audio[@]}" \
    --memory=4g --cpus=2 \
    workstation claude

  echo "↩  Container disposed. Clone (on host): $dir"
  echo "   If 'git status' is clean AND 'git log @{u}..' is empty → rm -rf '$dir'"
}
