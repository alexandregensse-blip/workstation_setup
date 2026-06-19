# task — ouvre une session Claude ISOLÉE dans un conteneur (Pattern C, modèle A).
#
#   task [--here | --at <chemin>] <repo> <sujet>
#
# Base d'accueil des clones (par ordre de priorité) :
#   --here          → le dossier courant ($PWD)
#   --at <chemin>   → un chemin que tu précises
#   (défaut)        → $WORKSTATION_REPOS, sinon ${WORKSTATION_HOME:-$HOME/dev}/repos
#
# Clone sur l'HÔTE (le WIP survit à la fermeture du conteneur jetable), crée la branche,
# puis lance Claude DANS le conteneur. Auth réutilisée depuis tes logins hôte :
# jeton gh injecté en env + identifiants Claude montés en lecture seule.
# Aucun chemin absolu codé en dur : tout est relatif à $HOME / aux options.
task() {
  local base="${WORKSTATION_REPOS:-${WORKSTATION_HOME:-$HOME/dev}/repos}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --here) base="$PWD"; shift ;;
      --at)   base="${2:?--at requiert un chemin}"; shift 2 ;;
      --)     shift; break ;;
      -*)     echo "task: option inconnue '$1'"; return 1 ;;
      *)      break ;;
    esac
  done

  local repo="${1:-}" subject="${2:-}"
  if [ -z "$repo" ] || [ -z "$subject" ]; then
    echo "usage: task [--here | --at <chemin>] <repo> <sujet>"; return 1
  fi

  local slug ts dir
  slug=$(printf '%s' "$subject" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  ts=$(date +%Y%m%d-%H%M)
  dir="$base/${repo##*/}/${ts}_$slug"
  mkdir -p "$(dirname "$dir")"

  gh repo clone "$repo" "$dir" || return 1
  ( cd "$dir" && git switch -c "task/$slug" && git push -u origin "task/$slug" )

  docker run -it --rm \
    --name "task-$slug" \
    -v "$dir:/work" -w /work \
    -e GH_TOKEN="$(gh auth token)" \
    -v "$HOME/.claude/.credentials.json:/home/ubuntu/.claude/.credentials.json:ro" \
    --memory=4g --cpus=2 \
    workstation claude

  echo "↩  Conteneur jeté. Clone (sur l'hôte) : $dir"
  echo "   Si git status propre ET git log @{u}.. vide → rm -rf '$dir'"
}
