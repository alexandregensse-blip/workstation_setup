#!/usr/bin/env bash
# workstation_setup — bootstrap idempotent pour une machine neuve (Ubuntu).
#
# ORDRE CRITIQUE : on installe les binaires, on déploie les dotfiles fait-main,
# PUIS on lance les `init` qui MUTENT la config Claude (jcodemunch puis rtk) EN DERNIER.
# jcodemunch init écrit ~/.claude/CLAUDE.md + les hooks ; rtk init ajoute @RTK.md par-dessus.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

log "1/9 paquets système (apt)"
sudo apt update
sudo apt install -y curl git ripgrep gh nodejs npm

log "2/9 uv"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

log "3/9 claude code (installeur natif)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

log "4/9 jcodemunch-mcp"
uv tool install jcodemunch-mcp \
  || uv tool install "git+https://github.com/jgravelle/jcodemunch-mcp.git"

log "5/9 rtk (binaire, pas de Rust)"
command -v rtk >/dev/null || curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh

log "6/9 dotfiles fait-main + structure de dossiers"
mkdir -p ~/.claude ~/dev/repos
cp "$REPO_DIR/claude/settings.json" ~/.claude/settings.json   # préférences SANS hooks (les init les posent)
cp "$REPO_DIR/claude/statusline.sh" ~/.claude/statusline.sh
cp "$REPO_DIR/dev/CLAUDE.md"        ~/dev/CLAUDE.md
cp "$REPO_DIR/dev/AGENTS.md"        ~/dev/AGENTS.md
chmod +x ~/.claude/statusline.sh

log "7/9 jcodemunch init (MCP + politique CLAUDE.md + hooks)"
jcodemunch-mcp init --client claude-code --claude-md global --hooks --yes

log "8/9 jcodemunch watch-install (watcher systemd, auto-réindex)"
jcodemunch-mcp watch-install

log "9/9 rtk init (DERNIER — ajoute @RTK.md, patche settings.json)"
rtk init -g --auto-patch

cat <<'EOF'

✅ Installation terminée.

Étapes interactives restantes :
  claude            # se connecter (compte / clé API)
  gh auth status    # vérifier l'auth GitHub

Mise à jour ultérieure (pas d'auto-update natif) :
  jcodemunch-mcp upgrade --yes

Puis : lance `claude` depuis ~/dev et dis « travaille sur <repo>, sujet <B> ».
EOF
