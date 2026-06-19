# task — open an ISOLATED Claude session in a container (Pattern C, model A).
#
#   task [--here | --at <path>] <repo> <topic>
#
# Clone base (priority): --here ($PWD) > --at <path> > $WORKSTATION_REPOS
#   > ${WORKSTATION_HOME:-$HOME/dev}/repos.
#
# Clones on the HOST (WIP survives the disposable container), creates the branch, then runs
# Claude INSIDE the container. Auth is reused from your host logins:
#   - GitHub : gh token via env (must be logged in: 'gh auth login').
#   - Claude : host credentials mounted read-only IF present, else $CLAUDE_CODE_OAUTH_TOKEN
#              (headless), else a clear error (no silent failure / no bogus mount dir).
# Docker auto-falls back to sudo if the docker group isn't active yet. No hardcoded paths.
task() {
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
    echo "usage: task [--here | --at <path>] <repo> <topic>"; return 1
  fi

  # --- auth, checked up front (clear errors, no silent failure) ---
  local gh_token; gh_token="$(gh auth token 2>/dev/null || true)"
  if [ -z "$gh_token" ]; then
    echo "task: not logged into GitHub — run 'gh auth login' first."; return 1
  fi
  local -a claude_auth
  if [ -f "$HOME/.claude/.credentials.json" ]; then
    claude_auth=(-v "$HOME/.claude/.credentials.json:/home/dev/.claude/.credentials.json:ro")
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    claude_auth=(-e CLAUDE_CODE_OAUTH_TOKEN)
  else
    echo "task: no Claude credentials found."
    echo "  → run 'claude auth login' on the host, or set CLAUDE_CODE_OAUTH_TOKEN (see 'claude setup-token')."
    return 1
  fi

  local slug ts dir dock
  slug=$(printf '%s' "$topic" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  ts=$(date +%Y%m%d-%H%M)
  dir="$base/${repo##*/}/${ts}_$slug"
  mkdir -p "$(dirname "$dir")"

  gh repo clone "$repo" "$dir" || return 1
  ( cd "$dir" && git switch -c "task/$slug" && git push -u origin "task/$slug" )

  # docker that works with or without the docker group (auto-falls back to sudo)
  dock=docker; docker info >/dev/null 2>&1 || dock="sudo docker"
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
