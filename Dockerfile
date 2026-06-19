# Image « workstation » — Pattern C, modèle A : Claude tourne DANS le conteneur.
# C'est install.sh « cuit » : mêmes outils, mais en root au build et SANS auth
# (les jetons/identifiants arrivent au `run`). Toolchain AGENT uniquement (claude + serena + rtk) ;
# les toolchains par langage viendront avec les devcontainers par projet (Pattern B, plus tard).
#
# IMPORTANT : on réutilise l'utilisateur `ubuntu` (uid 1000) déjà présent dans l'image de base.
# Son uid 1000 correspond à ton utilisateur hôte → les fichiers montés (clone, identifiants 0600)
# sont accessibles sans souci de permissions. (Créer un nouvel utilisateur lui donnerait uid 1001.)
FROM ubuntu:24.04

# 1. Outils système (root au build → pas de sudo)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ripgrep ca-certificates python3 gh \
 && rm -rf /var/lib/apt/lists/*

# 2. Utilisateur non-root = `ubuntu` (uid 1000, fourni par l'image) → matche l'hôte
USER ubuntu
ENV HOME=/home/ubuntu
ENV PATH="/home/ubuntu/.local/bin:${PATH}"
WORKDIR /home/ubuntu

# 3. uv, Claude Code, Serena, rtk — mêmes installeurs que install.sh
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN uv tool install -p 3.13 serena-agent && serena init
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh

# 4. Dotfiles fait-main (politique Serena, prefs, statusline, convention)
RUN mkdir -p /home/ubuntu/.claude /home/ubuntu/dev
COPY --chown=ubuntu:ubuntu claude/CLAUDE.md     /home/ubuntu/.claude/CLAUDE.md
COPY --chown=ubuntu:ubuntu claude/CLAUDE.md     /home/ubuntu/dev/AGENTS.md
COPY --chown=ubuntu:ubuntu claude/settings.json /home/ubuntu/.claude/settings.json
COPY --chown=ubuntu:ubuntu claude/statusline.sh /home/ubuntu/.claude/statusline.sh
COPY --chown=ubuntu:ubuntu dev/CLAUDE.md        /home/ubuntu/dev/CLAUDE.md

# 5. Brancher Serena (MCP) + rtk, et configurer git pour pousser via le token gh au run
RUN serena setup claude-code && rtk init -g --auto-patch \
 && git config --global credential.https://github.com.helper '!gh auth git-credential'

# Le code de la tâche est monté ici au run ; l'auth arrive par variables d'env / montage.
WORKDIR /work
CMD ["bash"]
