# Politique d'exploration de code (Serena)

Pour naviguer et comprendre du code, privilégier les outils sémantiques de **Serena** (MCP) plutôt que de lire des fichiers entiers.

**Début de session dans un repo :**
- Activer le projet : outil `activate_project` (automatique si lancé avec `--project-from-cwd`).
- Laisser Serena indexer via le Language Server si nécessaire.

**Trouver / lire du code :**
- Vue d'ensemble d'un fichier → `get_symbols_overview` avant de l'ouvrir.
- Un symbole précis (fonction, classe, méthode) → `find_symbol` (par chemin de symbole), au lieu de lire tout le fichier.
- Qui référence quoi → `find_referencing_symbols`.
- Recherche par motif texte / regex → `search_for_pattern`.

**Éditer :**
- Préférer l'édition symbolique de Serena (`replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`) — plus sûre et plus économe en tokens que réécrire un fichier entier.
- `Read` reste autorisé avant un `Edit`/`Write` ponctuel.

Serena délègue au Language Server du langage (LSP) pour une analyse sémantique réelle (types, définitions, références). 40+ langages supportés ; pour un langage non couvert, repli sur la recherche texte.
