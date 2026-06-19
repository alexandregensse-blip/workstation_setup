#!/usr/bin/env bash
# workstation_setup — installeur unique et idempotent (Ubuntu).
#
# Machine neuve, UNE commande :
#   bash <(curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh)
#
# Variables d'environnement surchargeables (toutes optionnelles) :
#   WORKSTATION_DIR    où vit la workstation       (défaut: $HOME/.local/share/workstation, caché)
#   WORKSTATION_HOME   ton espace de travail        (défaut: $HOME/dev)
#   WORKSTATION_REPOS  base des clones de tâches     (défaut: $WORKSTATION_HOME/repos)
# Aucun chemin absolu machine-spécifique : tout est relatif à $HOME.
set -euo pipefail

WS_DIR="${WORKSTATION_DIR:-$HOME/.local/share/workstation}"
WS_HOME="${WORKSTATION_HOME:-$HOME/dev}"
WS_REPOS="${WORKSTATION_REPOS:-$WS_HOME/repos}"
WS_URL="https://github.com/alexandregensse-blip/workstation_setup"
log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
export PATH="$HOME/.local/bin:$PATH"

log "0 · élévation de droits (sudo)"
sudo -v

log "1 · paquets système (apt)"
sudo apt update
sudo apt install -y curl git ripgrep gh nodejs npm docker.io

# Auto-bootstrap : si on n'est pas déjà dans un clone, récupérer le repo dans le dossier caché.
_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ -d "$(dirname "$_src")/claude" ]; then
  REPO_DIR="$(cd "$(dirname "$_src")" && pwd)"
else
  log "récupération de la workstation dans $WS_DIR"
  if [ -d "$WS_DIR/.git" ]; then git -C "$WS_DIR" pull --ff-only; else git clone "$WS_URL" "$WS_DIR"; fi
  REPO_DIR="$WS_DIR"
fi

log "2 · uv"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

log "3 · claude code (installeur natif)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

log "4 · serena (MCP de code, MIT)"
uv tool install -p 3.13 serena-agent
serena init

log "5 · rtk (binaire, sans Rust)"
command -v rtk >/dev/null || curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh

log "6 · dotfiles + espace de travail + commande task (source auto)"
mkdir -p "$HOME/.claude" "$WS_HOME" "$WS_REPOS" "$HOME/.local/share/workstation-shell"
cp "$REPO_DIR/claude/CLAUDE.md"     "$HOME/.claude/CLAUDE.md"   # politique Serena
cp "$REPO_DIR/claude/CLAUDE.md"     "$WS_HOME/AGENTS.md"        # même politique, cross-tool
cp "$REPO_DIR/claude/settings.json" "$HOME/.claude/settings.json"
cp "$REPO_DIR/claude/statusline.sh" "$HOME/.claude/statusline.sh"
cp "$REPO_DIR/dev/CLAUDE.md"        "$WS_HOME/CLAUDE.md"        # convention multi-repo
cp "$REPO_DIR/shell/task.sh"        "$HOME/.local/share/workstation-shell/task.sh"
chmod +x "$HOME/.claude/statusline.sh"
# source automatique de `task` (idempotent) + base par défaut si non standard
if ! grep -q 'workstation-shell/task.sh' "$HOME/.bashrc" 2>/dev/null; then
  { [ "$WS_REPOS" != "$HOME/dev/repos" ] && echo "export WORKSTATION_REPOS=\"$WS_REPOS\""
    echo 'source "$HOME/.local/share/workstation-shell/task.sh"'; } >> "$HOME/.bashrc"
fi

log "7 · enregistrement Serena dans Claude Code (MCP)"
serena setup claude-code

log "8 · rtk init (DERNIER — ajoute @RTK.md, patche settings.json)"
rtk init -g --auto-patch

log "9 · groupe docker pour ton user (effet après reconnexion)"
sudo usermod -aG docker "$USER"

log "10 · image docker 'workstation' (via sudo, fenêtre sudo encore ouverte)"
sudo docker image inspect workstation >/dev/null 2>&1 || sudo docker build -t workstation "$REPO_DIR"

log "11 · authentification (zéro-touche si jetons en env, sinon navigateur)"
gh auth status     >/dev/null 2>&1 || gh auth login
claude auth status >/dev/null 2>&1 || claude auth login

cat <<EOF

✅ Installation terminée.
Active le groupe docker : déconnecte/reconnecte (ou: reboot), puis :
  source ~/.bashrc        # (ou ouvre un nouveau terminal)
  task <repo> <sujet>     # session Claude isolée dans un conteneur

Workstation : $WS_DIR   |   Espace de travail : $WS_HOME   |   Tâches : $WS_REPOS
EOF
