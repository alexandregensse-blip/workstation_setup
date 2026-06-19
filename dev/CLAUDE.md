# ~/dev — multi-repo working convention

> Complements the global policy (`~/.claude/CLAUDE.md`, Serena-oriented).
> Here: multi-repo / multi-session handling.

## Principle
Local is a DISPOSABLE cache. GitHub is the ONLY source of truth. Every correct piece of work is pushed.
A task folder can be deleted at any time WITHOUT loss as long as everything is on the cloud.

## When asked "work on <repo>, topic <B>"

1. **Resolve <repo> via gh** (no table to maintain):
   - `<owner/name>` or a URL → use as-is;
   - otherwise search `gh repo list --json nameWithOwner` then
     `gh search prs --author=@me --json repository` (deduplicated);
   - 1 match → use it; several → ask which; none → ask for the link / exact name.

2. **Clone** into a timestamped folder:
   ```bash
   ts=$(date +%Y%m%d-%H%M); slug=<kebab-case(B)>
   gh repo clone <owner/name> <base>/<name>/${ts}_${slug}
   ```

3. **Branch**: `cd` in → `git switch -c task/<slug>` → `git push -u origin task/<slug>`.
   Activate the project in Serena (`activate_project` / `--project-from-cwd`).

4. **Work**, pushing at every finished and correct step.

5. **Loss-free deletion** — delete ONLY if BOTH are true:
   - `git status --porcelain` is empty, AND
   - `git log @{u}..` is empty (nothing unpushed).

   Otherwise push first. Then `rm -rf` the folder (Serena's `.serena/` cache goes with it;
   no external index to release). The remote branch STAYS.

No auto-push: a crash mid-task → redo the task.
