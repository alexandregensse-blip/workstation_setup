# workstation_setup

Workstation **portable**. Sur une machine neuve (Ubuntu), **une seule commande** installe tous
les outils, recrée `~/dev/repos/`, configure Claude Code, et pose Docker + la commande `task`
pour travailler en **sessions isolées**.

## Installation (machine neuve)

Le repo est public → commande unique (aucune auth nécessaire pour récupérer le script) :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh)
```

Le script gère l'élévation de droits (`sudo -v`), installe tout, puis lance l'auth GitHub + Claude
(via navigateur) — **sauf** si tu fournis `GH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` en variables
d'environnement (install entièrement automatique alors). `claude setup-token` une fois sur une
machine donne un jeton long réutilisable.

Après l'install : déconnecte/reconnecte (pour le groupe `docker`), puis construis l'image une fois :

```bash
docker build -t workstation ~/workstation_setup
```

## Travailler — deux modes

- **Sur l'hôte** (rapide) : `claude` depuis `~/dev`.
- **En session isolée** (recommandé) : `task <repo> <sujet>` — clone sur l'hôte, crée la branche
  `task/<slug>`, et lance **Claude dans un conteneur jetable** (toolchain figé, ton clone monté,
  auth réutilisée depuis tes logins hôte). À la sortie, le conteneur est détruit, le clone reste.
  Voir `shell/task.sh` et `Dockerfile`.

> Isolation forte : tout ce que fait Claude (bash, édition, Serena) reste dans le conteneur.
> C'est le **Pattern C / modèle A**. Le côté autodev (agents headless) réutilisera la même image,
> avec auth par jetons, identité bot dédiée et sandbox renforcé (phase ultérieure).

## Ce que fait `install.sh` (l'ordre compte)

Serena et rtk se branchent dans la config Claude via leur propre setup/init (ils modifient
`~/.claude/CLAUDE.md` et `settings.json`). D'où l'ordre :

1. `apt` : gh, node, npm, ripgrep, **docker.io**
2. `uv`
3. Claude Code (installeur natif)
4. **Serena** (`uv tool install -p 3.13 serena-agent` + `serena init`) — MCP de code, MIT
5. `rtk` (binaire, sans Rust)
6. dotfiles fait-main (politique Serena, `settings.json`, `statusline.sh`, `dev/CLAUDE.md`) +
   `~/dev/repos` + déploiement de la commande `task`
7. `serena setup claude-code` → MCP Serena + hooks
8. `rtk init -g` → **EN DERNIER** (ajoute `@RTK.md`, patche `settings.json`)
9. groupe `docker` pour ton user
10. auth GitHub + Claude

Le repo ne stocke **que** le fait-main ; les hooks sont posés par les setup respectifs.
`~/.claude.json` (secrets/état) n'est **jamais** versionné.

## Mise à jour

```bash
uv tool upgrade serena-agent            # Serena
docker build -t workstation ~/workstation_setup   # reconstruire l'image après MAJ d'outils
```
