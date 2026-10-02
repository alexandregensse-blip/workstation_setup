#!/usr/bin/env bash
# Collects every piece of Claude Code data on this machine into one plain backup folder, for activity
# monitoring: transcripts, history, config dirs (.claude, CLAUDE_CONFIG_DIR, slots, mounted
# claude-projects) copied whole — credentials included —, .claude.json, MCP logs, /tmp/claude-<uid>
# task outputs, moved transcript copies and transcripts-claude-* archives. Nothing has to be declared:
# the disk is scanned and data is recognised by name or, for stray .jsonl files, by content.
# The copy keeps each file's absolute path under the backup (containers: docker/<name>/<path>).
# It never deletes and never overwrites a newer copy (rsync --update, no --delete), so data that
# Claude Code purges (cleanupPeriodDays) or that 'task cleanup' removes stays in the backup.
# Skipped: Claude Code binaries (~/.local/share/claude), node_modules, git objects, image layers.
#
# Usage: backup-claude-data.sh [-n] [--root PATH]... [destination]   (default: ~/backups/claude-transcripts)
#   -n           dry run: list what would be copied, write nothing
#   --root PATH  scan only PATH (repeatable) and skip containers — 'task cleanup' uses it on a clone
# Run with sudo to cover every user, /root and Docker volumes; without it, what the user can read.
set -uo pipefail
shopt -s nullglob

DRY=0; ROOTS=(); DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) DRY=1 ;;
    --root) shift; ROOTS+=("$(realpath -m "${1:?--root needs a path}")") ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "backup-claude-data: unknown option '$1'" >&2; exit 2 ;;
    *) DEST="$1" ;;
  esac; shift
done
FULL=1; [ "${#ROOTS[@]}" -gt 0 ] && FULL=0

# Under sudo, the backup still belongs to (and lives in the home of) the user who ran it.
OWNER="${SUDO_USER:-$(id -un)}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"; OWNER_HOME="${OWNER_HOME:-$HOME}"
DEST="$(realpath -m "${DEST:-$OWNER_HOME/backups/claude-transcripts}")"
DOCK=""
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then DOCK=docker; elif [ "$(id -u)" != 0 ] && sudo -n docker info >/dev/null 2>&1; then DOCK="sudo docker"; fi
fi

[ "$DRY" = 1 ] || { mkdir -p "$DEST" && chmod 700 "$DEST"; } || exit 1
ERRORS=0
jsonl_count(){ find "$1" -name '*.jsonl' 2>/dev/null | wc -l; }
rsync_ok(){ [ "$1" = 0 ] || [ "$1" = 24 ] || { echo "    ! rsync failed ($1)" >&2; ERRORS=$((ERRORS + 1)); }; }
is_transcript(){ head -n5 "$1" 2>/dev/null \
  | jq -Rne '[inputs | fromjson? | objects | select(has("sessionId") or has("session_id"))] | length > 0' >/dev/null 2>&1; }

# Keep only the outermost paths of a list (a dir already taken makes its contents redundant).
outermost(){ local -A keep=(); local p a out=()
  while IFS= read -r p; do [ -n "$p" ] && keep[$p]=1; done
  for p in "${!keep[@]}"; do
    a="$p"; while a="${a%/*}"; [ -n "$a" ]; do [ -n "${keep[$a]:-}" ] && continue 2; done
    out+=("$p")
  done
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}" | LC_ALL=C sort; }

# Paths that hold Claude Code data, found by name under the given roots (one find per filesystem).
candidates(){ local r
  for r in "$@"; do
    find "$r" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /snap -o -path /usr \
        -o -path /boot -o -path /var/lib/docker -o -path /var/lib/containerd -o -path "$DEST" \
        -o -path "*/.local/share/claude" -o -name node_modules -o -path '*/.git/objects' \) -prune -o \
      \( -type d \( -name .claude -o -name claude-projects -o -name claude-cli-nodejs \
           -o -path '*/.local/state/claude' -o -path '*/.cache/claude' -o -regex '.*/claude-[0-9]+' \) -print -prune \) -o \
      \( -type f \( -name '.claude.json*' -o -name 'transcripts-claude-*' -o -name '*.jsonl' \) -print \) 2>/dev/null
  done | while IFS= read -r p; do
    case "$p" in
      */history.jsonl)
        # A config dir that is not named .claude (CLAUDE_CONFIG_DIR, slots): take it whole.
        d="${p%/*}"; if [ -d "$d/projects" ] || [ -e "$d/.claude.json" ]; then echo "$d"; elif is_transcript "$p"; then echo "$p"; fi ;;
      *.jsonl)
        is_transcript "$p" || continue
        echo "$p"; [ -d "${p%.jsonl}" ] && echo "${p%.jsonl}" ;;   # a moved session keeps its <id>/ dir
      *) echo "$p" ;;
    esac
  done; }

label(){ case "$1" in
  */claude-projects)          echo task ;;
  */.claude|*/.claude-slots/*) echo config ;;
  */claude-[0-9]*)            echo tmp ;;
  */claude-cli-nodejs|*/.local/state/claude|*/.cache/claude) echo logs ;;
  */.claude.json*)            echo state ;;
  *)  case "${1##*/}" in transcripts-claude-*) echo archive ;; *) echo copy ;; esac ;;
esac; }

# One line per data dir; stray copies and archives are grouped by their first 5 path levels.
report(){ local p l k; local -A n=() sz=() lb=(); local keys=()
  for p in "$@"; do
    l="$(label "$p")"; k="$p"
    case "$l" in copy|archive) k="$(cut -d/ -f1-6 <<< "$p")" ;; esac
    [ -n "${n[$k]+x}" ] || { keys+=("$k"); n[$k]=0; sz[$k]=0; lb[$k]="$l"; }
    n[$k]=$(( n[$k] + $(jsonl_count "$p") )); sz[$k]=$(( sz[$k] + $(du -sk "$p" 2>/dev/null | cut -f1) ))
  done
  for k in "${keys[@]}"; do
    printf '  %-8s %5d jsonl  %7s  %s\n' "${lb[$k]}" "${n[$k]}" "$(numfmt --to=iec --from-unit=1024 "${sz[$k]}")" "$k"
  done; }

echo "== Disk"
if [ "$FULL" = 1 ]; then
  ROOTS=(/ /tmp)
  while IFS= read -r m; do ROOTS+=("$m"); done < <(findmnt -rn -t ext2,ext3,ext4,xfs,btrfs,zfs,f2fs -o TARGET | grep -Ev '^/(boot|snap)?$|^/boot/')
  if [ "$(id -u)" = 0 ] && [ -n "$DOCK" ]; then   # named volumes live under the pruned /var/lib/docker
    while IFS= read -r v; do ROOTS+=("$v"); done < <($DOCK volume ls -q | xargs -r $DOCK volume inspect -f '{{.Mountpoint}}')
  fi
  [ "$(id -u)" = 0 ] || echo "  (not root: other users' files and Docker volumes are skipped — run with sudo to include them)"
fi
mapfile -t found < <(candidates "${ROOTS[@]}" | outermost)
report "${found[@]}"
if [ "$DRY" = 0 ] && [ "${#found[@]}" -gt 0 ]; then
  printf '%s\n' "${found[@]}" | rsync -a -r --update --files-from=- / "$DEST/"; rsync_ok $?
fi

if [ "$FULL" = 1 ] && [ -n "$DOCK" ]; then
  echo "== Containers (files written outside any mount)"
  while IFS= read -r c; do
    mapfile -t roots < <($DOCK diff "$c" 2>/dev/null | awk '$1!="D"{print $2}' | sed -nE \
      -e 's#^(.*/\.claude|.*/claude-projects|.*/claude-cli-nodejs|.*/\.local/state/claude|/tmp/claude-[0-9]+)(/.*)?$#\1#p' \
      -e 's#^(.*/\.claude\.json[^/]*)$#\1#p' | outermost)
    [ "${#roots[@]}" -gt 0 ] || continue
    printf '  %-8s %s: %s\n' container "$c" "${roots[*]}"
    [ "$DRY" = 1 ] && continue
    stage="$(mktemp -d)"
    for r in "${roots[@]}"; do
      mkdir -p "$stage${r%/*}" && $DOCK cp "$c:$r" "$stage$r" 2>/dev/null || ERRORS=$((ERRORS + 1))
    done
    mkdir -p "$DEST/docker/$c" && rsync -a --update "$stage/" "$DEST/docker/$c/"; rsync_ok $?
    rm -rf "$stage"
  done < <($DOCK ps -a --format '{{.Names}}')

  # Task clones removed without a backup taken by this script are gone; those backed up are listed here.
  echo "== Only in the backup (source deleted)"
  while IFS= read -r saved; do
    orig="${saved#"$DEST"}"; [ -e "$orig" ] && continue
    printf '  %-8s %5d jsonl  %s\n' gone "$(jsonl_count "$saved")" "$orig"
  done < <(find "$DEST" -path "$DEST/docker" -prune -o -type d -name claude-projects -print -prune 2>/dev/null)
fi

echo "== Total"
if [ "$DRY" = 1 ]; then echo "  dry run: nothing written"
else
  [ "$(id -u)" = 0 ] && [ "$OWNER" != root ] && chown -R "$OWNER:" "$DEST"
  printf '  %s: %d jsonl, %s\n' "$DEST" "$(jsonl_count "$DEST")" "$(du -sh "$DEST" | cut -f1)"
fi
[ "$ERRORS" = 0 ] || { echo "  $ERRORS error(s), see above" >&2; exit 1; }
