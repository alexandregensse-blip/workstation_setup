# ~/dev — convention de travail multi-repo

> Complète la politique globale (`~/.claude/CLAUDE.md`, orientée Serena).
> Ici : gestion multi-repo / multi-session.

## Principe
Le local est un cache **JETABLE**. GitHub est la **SEULE** vérité. Tout travail correct est poussé.
Un dossier de tâche peut être supprimé à tout moment SANS perte si tout est sur le cloud.

## Quand on me dit « travaille sur <repo>, sujet <B> »

1. **Résoudre <repo> via gh** (aucune table à maintenir) :
   - `<owner/name>` ou URL → utiliser tel quel ;
   - sinon chercher dans `gh repo list --json nameWithOwner` puis
     `gh search prs --author=@me --json repository` (dédupliqué) ;
   - 1 résultat → on prend ; plusieurs → demander lequel ; aucun → demander le lien/nom exact.

2. **Cloner** dans un dossier horodaté :
   ```bash
   ts=$(date +%Y%m%d-%H%M); slug=<kebab-case(B)>
   gh repo clone <owner/name> ~/dev/repos/<name>/${ts}_${slug}
   ```

3. **Brancher** : `cd` dedans → `git switch -c task/<slug>` → `git push -u origin task/<slug>`.
   Activer le projet dans Serena (`activate_project` / `--project-from-cwd`).

4. **Travailler**, en poussant à chaque étape terminée et correcte.

5. **Suppression SANS perte** — supprimer UNIQUEMENT si les DEUX sont vrais :
   - `git status --porcelain` vide (rien de non commité / non suivi de valeur), ET
   - `git log @{u}..` vide (rien de non poussé).

   Sinon pousser d'abord. Puis `rm -rf` le dossier (le cache Serena `.serena/` part avec lui ;
   pas d'index externe à libérer, contrairement à un watcher). La branche **distante RESTE**.

Pas d'auto-push : un crash en cours de tâche → on refait la tâche.
