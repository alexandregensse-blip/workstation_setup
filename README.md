# workstation_setup

Workstation **portable**. Sur une machine neuve (Ubuntu), **une seule commande** installe tous les
outils, configure Claude Code (MCP **Serena** + rtk), prépare Docker, et pose la commande `task`
pour travailler en **sessions isolées**. Aucun chemin absolu machine-spécifique (tout est relatif à `$HOME`).

## Installation — une commande

```bash
curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh | bash
```

Le script **te demande où placer ton espace de travail** (dossier courant / `~/dev` / chemin précis),
élève les droits (`sudo`), installe les paquets, **se clone lui-même dans un dossier caché**
(`~/.local/share/workstation`), installe uv/Claude/Serena/rtk, déploie tes dotfiles, **construit l'image
Docker**, et **ajoute le `source` de `task` à ton `.bashrc`** automatiquement. Puis il lance l'auth
GitHub + Claude (navigateur) — sauf si `GH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` sont en variables d'env —
et **affiche une confirmation** avec les commandes `task`.

> Le prompt et `sudo` lisent sur `/dev/tty`, donc le format pipe (`| bash`) reste interactif.

Après l'install, **active le groupe docker** (déconnexion/reconnexion ou `reboot`), puis ouvre un
nouveau terminal : `task` est dispo.

### Choisir les emplacements (optionnel)

Variables d'env, toutes facultatives (défauts entre parenthèses) :

| Variable | Rôle | Défaut |
|---|---|---|
| `WORKSTATION_DIR`   | où vit la workstation (scripts/Dockerfile) | `~/.local/share/workstation` (caché) |
| `WORKSTATION_HOME`  | ton espace de travail | `~/dev` |
| `WORKSTATION_REPOS` | base des clones de tâches | `$WORKSTATION_HOME/repos` |

Ex. : `WORKSTATION_HOME=~/projets bash <(curl -fsSL …/install.sh)`

## Travailler

- **Sur l'hôte** : `claude` depuis ton espace de travail.
- **En session isolée** (recommandé) :
  ```bash
  task <repo> <sujet>            # base par défaut (~/dev/repos)
  task --here <repo> <sujet>     # clone sous le dossier courant
  task --at /chemin <repo> <sujet>   # clone sous un chemin précis
  ```
  → clone sur l'hôte, branche `task/<slug>`, puis **Claude dans un conteneur jetable** (Serena
  connecté, auth réutilisée). À la sortie : conteneur détruit, clone conservé sur l'hôte.
  Détails : `shell/task.sh` et `Dockerfile`.

> Isolation forte (Pattern C / modèle A) : tout ce que fait Claude reste dans le conteneur.
> Le conteneur réutilise l'utilisateur `ubuntu` (uid 1000) de l'image → les fichiers montés
> (clone, identifiants) sont accessibles sans souci de permissions.

## Mise à jour

```bash
git -C ~/.local/share/workstation pull        # récupérer les changements
uv tool upgrade serena-agent                  # Serena
docker build -t workstation ~/.local/share/workstation   # reconstruire l'image
```
