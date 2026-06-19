# task — ouvre une session Claude ISOLÉE dans un conteneur (Pattern C, modèle A).
#
#   task <repo> <sujet>
#
# Clone sur l'HÔTE (le WIP survit à la fermeture du conteneur jetable), branche,
# puis lance Claude DANS le conteneur. L'auth est réutilisée depuis tes logins hôte :
# jeton gh injecté en env + identifiants Claude montés en lecture seule (pas de keyring en conteneur).
task() {
  local repo="$1" subject="$2"
  if [ -z "$repo" ] || [ -z "$subject" ]; then
    echo "usage: task <repo> <sujet>"; return 1
  fi

  local slug ts name dir
  slug=$(printf '%s' "$subject" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  ts=$(date +%Y%m%d-%H%M)
  name=${repo##*/}                          # partie après un éventuel "owner/"
  dir="$HOME/dev/repos/$name/${ts}_$slug"

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
  echo "   Si git status est propre ET git log @{u}.. vide → rm -rf '$dir'"
}
