# workstation_setup

Workstation **portable**. Sur une machine neuve (Ubuntu), on clone ce repo et on lance
`install.sh` : ça installe tous les outils, recrée la structure `~/dev/repos/`, et configure
Claude Code prêt à l'emploi.

## Installation (machine neuve)

```bash
# 1. De quoi s'authentifier sur GitHub (ce repo est privé)
sudo apt update && sudo apt install -y gh
gh auth login

# 2. Cloner + TOUT installer
gh repo clone alexandregensse-blip/workstation_setup ~/workstation_setup
cd ~/workstation_setup && ./install.sh
```

Puis deux étapes interactives que le script ne peut pas automatiser :

```bash
claude            # se connecter (compte / clé API)
gh auth status    # vérifier l'auth GitHub
```

Ensuite : lance `claude` depuis `~/dev` et dis « travaille sur \<repo\>, sujet \<B\> »
(voir `dev/CLAUDE.md` pour la convention multi-repo).

## Ce que fait `install.sh` (l'ordre compte)

`jcodemunch` et `rtk` s'installent **eux-mêmes** dans la config Claude via leur propre `init`
(ils modifient `~/.claude/CLAUDE.md` et `~/.claude/settings.json`). D'où l'ordre :

1. paquets système (`apt`) : gh, node, npm, ripgrep
2. `uv`
3. Claude Code (installeur natif, pas npm)
4. `jcodemunch-mcp` (via `uv tool` ; pas de toolchain Rust requise)
5. `rtk` (binaire précompilé, **sans** Rust)
6. dotfiles fait-main (préférences `settings.json`, `statusline.sh`, `dev/CLAUDE.md`,
   `dev/AGENTS.md`) + `mkdir -p ~/dev/repos`
7. `jcodemunch-mcp init` → enregistre le MCP, écrit la politique `CLAUDE.md`, pose les hooks
8. `jcodemunch-mcp watch-install` → watcher systemd (auto-réindexation)
9. `rtk init -g` → **EN DERNIER** : ajoute `@RTK.md` à `CLAUDE.md`, patche `settings.json`

Le repo ne stocke **que** le fait-main. La politique globale `~/.claude/CLAUDE.md` et les hooks
sont **régénérés** par les `init` (toujours à jour avec la version installée).
`~/.claude.json` (secrets + état machine) n'est **jamais** versionné.

## Mise à jour

Pas d'auto-update natif. Manuellement :

```bash
jcodemunch-mcp upgrade --yes          # met à jour jcodemunch + rafraîchit hooks/config
uv tool upgrade jcodemunch-mcp        # (équivalent côté uv)
# rtk / claude : relancer leur installeur respectif
```
