#!/usr/bin/env bash
# workstation_setup — bootstrap idempotent pour une machine neuve (Ubuntu).
#
# ORDRE : binaires -> dotfiles fait-main -> setup Serena (MCP + hooks)
# -> rtk init EN DERNIER (il mute ~/.claude/CLAUDE.md + settings.json par-dessus).
# Installe aussi Docker + la commande `task` (Pattern C, modèle A : Claude isolé en conteneur).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

log "0/10 élévation de droits (sudo)"
sudo -v   # demande le mot de passe une fois, en début de course

log "1/10 paquets système (apt)"
sudo apt update
sudo apt install -y curl git ripgrep gh nodejs npm docker.io

log "2/10 uv"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

log "3/10 claude code (installeur natif)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

log "4/10 serena (MCP de code, MIT, license-safe)"
uv tool install -p 3.13 serena-agent
serena init

log "5/10 rtk (binaire, pas de Rust)"
command -v rtk >/dev/null || curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh

log "6/10 dotfiles fait-main + structure + commande task"
mkdir -p ~/.claude ~/dev/repos ~/.local/share/workstation
cp "$REPO_DIR/claude/CLAUDE.md"     ~/.claude/CLAUDE.md   # politique Serena
cp "$REPO_DIR/claude/CLAUDE.md"     ~/dev/AGENTS.md       # même politique, version cross-tool
cp "$REPO_DIR/claude/settings.json" ~/.claude/settings.json
cp "$REPO_DIR/claude/statusline.sh" ~/.claude/statusline.sh
cp "$REPO_DIR/dev/CLAUDE.md"        ~/dev/CLAUDE.md
cp "$REPO_DIR/shell/task.sh"        ~/.local/share/workstation/task.sh
chmod +x ~/.claude/statusline.sh
grep -q 'workstation/task.sh' ~/.bashrc 2>/dev/null \
  || echo 'source ~/.local/share/workstation/task.sh' >> ~/.bashrc

log "7/10 enregistrement Serena dans Claude Code (MCP + hooks recommandés)"
serena setup claude-code

log "8/10 rtk init (DERNIER — ajoute @RTK.md, patche settings.json)"
rtk init -g --auto-patch

log "9/10 Docker : autoriser ton user à parler au démon (effet après reconnexion)"
sudo usermod -aG docker "$USER"

log "10/10 authentification (zéro-touche si jetons en env, sinon navigateur)"
gh auth status     >/dev/null 2>&1 || gh auth login        # ou: export GH_TOKEN=...
claude auth status >/dev/null 2>&1 || claude auth login    # ou: export CLAUDE_CODE_OAUTH_TOKEN=... (claude setup-token 1x)

cat <<EOF

✅ Installation terminée.
Pour activer le groupe docker : déconnecte/reconnecte (ou: newgrp docker), puis construis l'image :
  docker build -t workstation "$REPO_DIR"

Ensuite, pour une session de travail ISOLÉE :
  task <repo> <sujet>      # clone + branche + Claude dans un conteneur jetable

(Ou en direct sur l'hôte : lance \`claude\` depuis ~/dev.)
EOF
