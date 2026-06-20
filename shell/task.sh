# task — open an ISOLATED Claude session in a container (Pattern C, model A).
#
#   task [--here | --at <path>] <repo> <topic>
#   task auth                         # (re)login to Claude; stored in <workspace>/.workstation/.claude
#
# Container-only: the host has NO Claude/Serena/rtk — they live in the 'workstation' image.
# Clone base (priority): --here ($PWD) > --at <path> > $WORKSTATION_REPOS
#   > ${WORKSTATION_HOME:-$HOME/dev}/repos.
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

  # one-off: (re)login to Claude inside the image, persisting creds to the workstation dir
  if [ "${1:-}" = "auth" ]; then
    mkdir -p "$ws_dir/.claude"
    $dock run -it --rm -v "$ws_dir/.claude:/seed" workstation \
      bash -lc 'claude auth login && cp -f "$HOME/.claude/.credentials.json" /seed/.credentials.json'
    return $?
  fi

  local base="${WORKSTATION_REPOS:-${WORKSTATION_HOME:-$HOME/dev}/repos}"
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
  if [ -z "$repo" ] || [ -z "$topic" ]; then
    echo "usage: task [--here | --at <path>] <repo> <topic>   |   task auth"; return 1
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
  slug=$(printf '%s' "$topic" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  ts=$(date +%Y%m%d-%H%M)
  dir="$base/${repo##*/}/${ts}_$slug"
  mkdir -p "$(dirname "$dir")"

  gh repo clone "$repo" "$dir" || return 1
  ( cd "$dir" && git switch -c "task/$slug" && git push -u origin "task/$slug" )

  $dock run -it --rm \
    --name "task-$slug" \
    -v "$dir:/work" -w /work \
    -e GH_TOKEN="$gh_token" \
    "${claude_auth[@]}" \
    --memory=4g --cpus=2 \
    workstation claude

  echo "↩  Container disposed. Clone (on host): $dir"
  echo "   If 'git status' is clean AND 'git log @{u}..' is empty → rm -rf '$dir'"
}
