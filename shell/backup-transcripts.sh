#!/usr/bin/env bash
# Copie tous les transcripts Claude Code de la machine dans un dossier de sauvegarde, en gardant le
# chemin d'origine sous ce dossier. Ne supprime rien et n'écrase jamais une copie plus récente
# (rsync --update, sans --delete) : un transcript purgé par Claude Code reste dans la sauvegarde.
# Ne copie que les transcripts (projects/, history.jsonl, jobs/), jamais .credentials.json ni le reste.
# À lancer sur l'hôte. Relançable sans risque.
#
# Usage : backup-transcripts.sh [-n] [destination]     (défaut : ~/backups/claude-transcripts)
#   -n                 simulation : liste ce qui serait copié, n'écrit rien
#   TRANSCRIPT_SCAN    dossiers fouillés pour les copies déplacées, séparés par « : » (défaut : $HOME)
#
# Trois cas :
#   1. général : les configs Claude Code de l'hôte ($CLAUDE_CONFIG_DIR, ~/.claude) et les slots
#      de la workstation (.claude-slots/*) ;
#   2. tasks : en cours ou arrêtées (montages lus avec docker inspect), et fermées dont le clone
#      existe encore (<clone>/.git/claude-projects). « task cleanup » supprime le clone et ses
#      transcripts avec : seules les sauvegardes antérieures les gardent, le script les signale ;
#   3. cachés ou déplacés : fichiers écrits dans la couche d'un conteneur (hors montage), copies
#      ailleurs sur le disque reconnues à leur contenu (clé sessionId), archives transcripts-claude-*.tar.gz.
set -uo pipefail
shopt -s nullglob

DRY=0
[ "${1:-}" = -n ] && { DRY=1; shift; }
DEST="$(realpath -m "${1:-$HOME/backups/claude-transcripts}")"
WS="${WORKSTATION_DIR:-${WORKSTATION_HOME:-$HOME/dev}/.workstation}"
BASE="${WORKSTATION_RUNNING:-${WORKSTATION_HOME:-$HOME/dev}/running}"
IFS=: read -r -a SCAN <<< "${TRANSCRIPT_SCAN:-$HOME}"
DOCK=docker; docker info >/dev/null 2>&1 || DOCK="sudo docker"
command -v "${DOCK##* }" >/dev/null 2>&1 || DOCK=""

[ "$DRY" = 1 ] || { mkdir -p "$DEST" && chmod 700 "$DEST"; } || exit 1
declare -A DONE=()   # chemins déjà copiés (évite les doublons et sert à exclure du balayage)
ERRORS=0

# copy <chemin absolu> <étiquette> : copie sous $DEST en gardant le chemin complet.
copy(){ local src n
  src="$(realpath -m "$1")"; [ -e "$src" ] || return 0; [ -n "${DONE[$src]:-}" ] && return 0
  DONE[$src]=1
  n="$(find "$src" -name '*.jsonl' 2>/dev/null | wc -l)"
  [ "$n" = 0 ] && [ -d "$src" ] && return 0
  printf '  %-10s %5d jsonl  %s\n' "$2" "$n" "$src"
  [ "$DRY" = 1 ] && return 0
  rsync -aR --update "$src" "$DEST/"; local rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 24 ] || { echo "    ! rsync a échoué ($rc)" >&2; ERRORS=$((ERRORS + 1)); }
}

# copy_cfg <dossier de config> <étiquette> : uniquement les transcripts d'une config Claude Code.
copy_cfg(){ local item; for item in projects history.jsonl jobs; do copy "$1/$item" "$2"; done; }

echo "== 1. Configs Claude Code (hôte et slots)"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && copy_cfg "$CLAUDE_CONFIG_DIR" config
copy_cfg "$HOME/.claude" hôte
for s in "$WS"/.claude-slots/*/; do copy_cfg "${s%/}" "slot $(basename "$s")"; done

echo "== 2. Tasks"
declare -A MOUNTED=()
if [ -n "$DOCK" ]; then
  while IFS= read -r c; do
    state="$($DOCK inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    [ "$state" = running ] && label="en cours" || label="arrêtée"
    cfgdir="$($DOCK inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | sed -n 's/^CLAUDE_CONFIG_DIR=//p')"
    cfgdir="${cfgdir:-/home/dev/.claude}"
    while IFS=$'\t' read -r src dst; do
      [ -e "$src" ] || continue
      case "$dst" in
        "$cfgdir")          copy_cfg "$src" "$label" ;;
        "$cfgdir/projects") MOUNTED[$(realpath -m "$src")]=1; copy "$src" "$label" ;;
      esac
    done < <($DOCK inspect -f '{{range .Mounts}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}' "$c")
  done < <($DOCK ps -a --format '{{.Names}}')
fi
# Clones de tasks sans conteneur : base par défaut + bases enregistrées par « task --here/--at ».
{ printf '%s\n' "$BASE"; [ -f "$WS/.bases" ] && cat "$WS/.bases"; } | sort -u | while IFS= read -r b; do
  [ -d "$b" ] && find "$b" -mindepth 3 -maxdepth 3 -type d -name .git 2>/dev/null
done | sort -u > "${TMPDIR:-/tmp}/bt-clones.$$"
while IFS= read -r g; do
  [ -d "$g/claude-projects" ] && [ -z "${MOUNTED[$(realpath -m "$g/claude-projects")]:-}" ] \
    && copy "$g/claude-projects" "fermée"
done < "${TMPDIR:-/tmp}/bt-clones.$$"
rm -f "${TMPDIR:-/tmp}/bt-clones.$$"
# Tasks supprimées : présentes dans la sauvegarde, plus sur le disque.
if [ -d "$DEST" ]; then
  while IFS= read -r saved; do
    orig="${saved#"$DEST"}"; [ -e "$orig" ] && continue
    printf '  %-10s %5d jsonl  %s (seulement dans la sauvegarde)\n' "supprimée" \
      "$(find "$saved" -name '*.jsonl' | wc -l)" "$orig"
  done < <(find "$DEST" -type d -path '*/.git/claude-projects' -prune 2>/dev/null)
fi

echo "== 3. Transcripts cachés ou déplacés"
# 3a. Couche d'écriture des conteneurs : ce qui n'est pas sur un montage disparaît avec le conteneur.
if [ -n "$DOCK" ]; then
  while IFS= read -r c; do
    mapfile -t files < <($DOCK diff "$c" 2>/dev/null | awk '$1!="D"{print $2}' \
      | grep -E '\.jsonl$' | grep -E '/projects/|/claude-projects/|/history\.jsonl$' | grep -v '/mcp-logs')
    [ "${#files[@]}" -gt 0 ] || continue
    printf '  %-10s %5d jsonl  conteneur %s → %s/docker/%s\n' "conteneur" "${#files[@]}" "$c" "$DEST" "$c"
    [ "$DRY" = 1 ] && continue
    stage="$(mktemp -d)"
    for f in "${files[@]}"; do
      mkdir -p "$stage$(dirname "$f")"
      $DOCK cp "$c:$f" "$stage$f" 2>/dev/null || ERRORS=$((ERRORS + 1))
    done
    mkdir -p "$DEST/docker/$c" && rsync -a --update "$stage/" "$DEST/docker/$c/" || ERRORS=$((ERRORS + 1))
    rm -rf "$stage"
  done < <($DOCK ps -a --format '{{.Names}}')
fi
# 3b. Copies déplacées sur le disque et archives. On saute ce qui est déjà copié, la sauvegarde,
# les caches et les .git (les claude-projects des clones sont traités en 2).
prune=("$DEST" "$HOME/.cache" "$HOME/.claude" "$WS/.claude-slots")
pargs=(); for p in "${prune[@]}"; do pargs+=(-path "$p" -o); done
is_transcript(){ head -n5 "$1" 2>/dev/null \
  | jq -Rne '[inputs | fromjson? | objects | select(has("sessionId") or has("session_id"))] | length > 0' >/dev/null 2>&1; }
list="$(mktemp)"
while IFS= read -r -d '' f; do
  case "$f" in
    */transcripts-claude-*) printf '%s\n' "$f" >> "$list" ;;
    *.jsonl)
      is_transcript "$f" || continue
      printf '%s\n' "$f" >> "$list"
      # Une session déplacée part avec son dossier frère <id>/ (tool-results, etc.).
      [ -d "${f%.jsonl}" ] && printf '%s\n' "${f%.jsonl}" >> "$list" ;;
  esac
done < <(find "${SCAN[@]}" -xdev \( "${pargs[@]}" -name .git -o -name node_modules \) -prune -o -type f \
          \( -name '*.jsonl' -o -name 'transcripts-claude-*.tar.gz' -o -name 'transcripts-claude-*-INDEX.md' \) \
          -print0 2>/dev/null)
sort -u -o "$list" "$list"
# Affichage regroupé par dossier de premier niveau sous $HOME (ou /) : un projet = une ligne.
grep -v '/$' "$list" | grep -E '\.jsonl$|\.tar\.gz$' | sed -E "s#^($HOME/[^/]+/[^/]+/[^/]+/[^/]+)/.*#\1#" \
  | sort | uniq -c | while read -r n p; do printf '  %-10s %5d fichiers  %s\n' "copie" "$n" "$p"; done
if [ "$DRY" = 0 ] && [ -s "$list" ]; then
  rsync -a -r --update --files-from="$list" / "$DEST/"; rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 24 ] || { echo "    ! rsync a échoué ($rc)" >&2; ERRORS=$((ERRORS + 1)); }
fi
rm -f "$list"

echo "== Bilan"
if [ "$DRY" = 1 ]; then echo "  simulation : rien n'a été écrit"
else
  printf '  %s : %d jsonl, %s\n' "$DEST" "$(find "$DEST" -name '*.jsonl' | wc -l)" "$(du -sh "$DEST" | cut -f1)"
fi
[ "$ERRORS" = 0 ] || { echo "  $ERRORS erreur(s), voir plus haut" >&2; exit 1; }
