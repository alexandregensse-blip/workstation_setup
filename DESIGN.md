# workstation_setup — Design & Behaviors

Full reference for what this repo does and every behavior it implements.
For the quick start, see [README.md](README.md).

## 1. Purpose

A **portable workstation**: one command sets up a fresh Ubuntu machine to run Claude Code work
as **isolated, disposable Docker containers** via a `task` command. **Container-only**: the AI
toolchain (Claude Code, Serena MCP, rtk, uv) and all config live **only inside the image and a
self-contained `<workspace>/.workstation` dir** — the host is left in its initial state.

## 2. Mental model

- **Local is a disposable cache; GitHub is the only source of truth.** Anything correct is
  pushed; a task folder (or container) can be destroyed at any time without loss.
- **Pattern C / model A**: one container per task, and **Claude runs *inside* the container**,
  so everything it does (bash, edits, Serena, running code) stays sandboxed from the host.
- **The host stays clean.** Only `docker`, `git`, `gh` may be installed (if missing), and they
  are recorded so the uninstaller can offer to remove exactly those. No `claude`/`serena`/`rtk`/
  `uv` on the host, and `~/.claude` is never written there.
- **Everything is self-contained in `<workspace>/.workstation`** — the clone, the Claude
  credentials, and the install bookkeeping all live in that one dir, next to your task clones.
- **Same principle for maintainer and (future) autodev agents**: same image, same container
  lifecycle, Git as the coordination layer — only the trigger and auth differ.

## 3. Repository layout

| Path | Role |
|---|---|
| `install.sh` | One-command, idempotent installer (container-only). |
| `uninstall.sh` | Reverses it, asking **point-by-point** (see §13). |
| `Dockerfile` | The `workstation` image — bakes the toolchain **and** the config (Wolfi base). |
| `shell/task.sh` | The `task` shell function, **sourced straight from the clone**. |
| `claude/CLAUDE.md` | Global code-exploration policy (Serena). Baked into the image at `~/.claude/CLAUDE.md`. |
| `claude/settings.json` | Claude prefs **+ hooks** (Serena + rtk). Baked into the image. No hardcoded language. |
| `claude/statusline.sh` | Custom status line. Baked into the image. |
| `dev/CLAUDE.md` | Multi-repo working convention. Baked into the image. |
| `README.md` / `DESIGN.md` | Quick start / this reference. |

The dotfiles are **deployed into the image only** — never copied to the host.

## 4. Components (all inside the image)

- **Claude Code** — the agent CLI (native installer, glibc binary).
- **Serena** (`serena-agent`, MIT) — semantic code MCP server (LSP-based). License-safe for
  commercial use, unlike jCodeMunch (dual-licensed) which this setup replaced.
- **rtk** (`rtk-ai/rtk`, MIT) — token-saving CLI proxy; hooks into Claude's Bash tool.
- **uv** — installs Serena and its standalone Python.
- **gh**, **git**, **ripgrep**, **jq**, **python3** — image tools.

On the **host**, only `docker`, `git`, `gh` are required (git/gh for cloning + the GitHub token;
docker to build/run the image).

## 5. Install process (`install.sh`)

### Invocation
```bash
curl -fsSL .../install.sh | bash                 # interactive
curl -fsSL .../install.sh | bash -s -- --home ~/dev --yes   # headless
```
The prompt and `sudo` read from `/dev/tty`, so the pipe form stays interactive.

### Flags & environment (all optional)
| Flag | Env | Meaning | Default |
|---|---|---|---|
| `--home <path>`  | `WORKSTATION_HOME`  | workspace dir (clones + `.workstation`) | prompt, else `~/dev` |
| `--repos <path>` | `WORKSTATION_REPOS` | tasks base | `<home>/repos` |
| `--dir <path>`   | `WORKSTATION_DIR`   | where the workstation lives | `<home>/.workstation` |
| `--lang <code>`  | `WORKSTATION_LANG`  | Claude UI language (baked in the image) | unset (Claude default) |
| `--yes` / `-y`   | —                   | non-interactive (skip prompt) | — |

Missing flag values fail fast with a clear message (guarded against `set -u`).

### Behaviors, in order
1. **Workspace prompt** — unless `--home`/env given, or `--yes`, or no TTY (then `~/dev`). The
   `.workstation` dir defaults to `<workspace>/.workstation`.
2. **Host prerequisites** — installs **only what's missing** among `docker.io`, `git`, `gh`. The
   packages actually installed are recorded in `<workspace>/.workstation/.apt-installed` so the
   uninstaller can later remove **exactly those** (and nothing pre-existing).
3. **Fetch the workstation** — clones the repo into `<workspace>/.workstation` (or `git pull` if
   already present). Everything else is keyed off this dir (`REPO_DIR`).
4. **Docker group** — `usermod -aG docker` unless already a member; if it adds you, it drops a
   `.docker-group-added` marker so uninstall can offer to undo exactly that.
5. **Image build** — builds `workstation` if missing, passing the language as `--build-arg
   WS_LANG`. Uses the `docker`-or-`sudo docker` wrapper (see §8). The image bakes the toolchain
   **and** the dotfiles/hooks.
6. **`task` command** — auto-sourced in `~/.bashrc` (once), inside a `# >>> workstation >>>` …
   `# <<< workstation <<<` marked block that also exports `WORKSTATION_DIR`/`WORKSTATION_REPOS`.
   The block sources `task` **straight from the clone** (`$WS_DIR/shell/task.sh`).
7. **GitHub auth** — `gh auth login --web` only if not already authenticated (skipped with no TTY).
8. **Claude credentials** — logs in **inside a container** and copies the resulting
   `.credentials.json` to `<workspace>/.workstation/.claude/` (host `~/.claude` stays untouched).
   No-op if a stored file exists or `CLAUDE_CODE_OAUTH_TOKEN` is set; deferred to `task auth` if
   there's no TTY.
9. **Confirmation banner** — verifies docker/git/gh + the image, prints locations and `task` usage.

**Idempotency**: re-running installs/configures only what is missing. The committed
`settings.json` (baked in the image) is the single source of truth for hooks.

## 6. Task workflow (`shell/task.sh`)

```
task [--here | --at <path>] <repo> <topic>
task auth        # (re)login to Claude, stored in <workspace>/.workstation/.claude
```

1. **`task auth`** — runs `claude auth login` in a throwaway container and persists the
   credentials to `<workspace>/.workstation/.claude/.credentials.json`.
2. **Base selection** — `--here` (`$PWD`) > `--at <path>` > `$WORKSTATION_REPOS` >
   `${WORKSTATION_HOME:-$HOME/dev}/repos`.
3. **Auth checked up front** (no silent failure):
   - GitHub: requires `gh auth token` (else clear error).
   - Claude: mounts `<workstation>/.claude/.credentials.json` **if it exists**, else uses
     `$CLAUDE_CODE_OAUTH_TOKEN`, else a clear error pointing to `task auth`.
4. **Clone on the host** → `<base>/<repo>/<YYYYMMDD-HHMM>_<slug>` — WIP survives the container.
5. **Branch** `task/<slug>` and push it.
6. **Run** Claude inside the container: clone mounted at `/work`, `GH_TOKEN` injected, Claude
   credentials mounted read-only, memory/cpu limits, `--rm` (disposable).
7. **On exit** — container destroyed; clone kept on host. Delete it only when `git status` is
   clean **and** nothing is unpushed (`git log @{u}..` empty).

## 7. The Docker image (`Dockerfile`)

- **Base: Chainguard Wolfi** (`wolfi-base`). Chosen after benchmarking: it is **glibc**
  (required by the prebuilt Claude/rtk/uv binaries — Alpine's musl would break them), yet
  far smaller and lower-CVE than Debian/Ubuntu. Distroless/scratch were excluded (no shell /
  package manager to install tools at build).
- **`dev` user, uid 1000** — explicitly created to match the host user, so host-mounted files
  (clone, `0600` credentials) are readable. (A default new user would get uid 1001 and fail.)
- **Tools**: bash, curl, git, ripgrep, **python3** (kept — `uv -p 3.13` reuses it, which makes
  the image *smaller*: 194 MB vs 215 MB without), gh, jq, shadow (useradd), ca-certificates.
- **Config baked in**: the policy, prefs + hooks, statusline and convention are COPYed into the
  image's `~/.claude` and `~/dev` — so the container is fully configured with no host deployment.
- **Language**: `ARG WS_LANG` injected into the image's `settings.json` when provided.
- **Wiring**: `serena setup claude-code` (MCP), `rtk init -g --no-patch` (RTK.md only), and a
  git credential helper (`!gh auth git-credential`) so in-container `git push` uses `GH_TOKEN`.

Final image ≈ **194 MB**.

## 8. Auth model

- **GitHub** — host: gh keyring (or `GH_TOKEN`). Container: `GH_TOKEN="$(gh auth token)"`
  passed by `task`; the baked credential helper lets `git push` use it.
- **Claude** — credentials live in `<workspace>/.workstation/.claude/.credentials.json`,
  produced by `task auth` (login inside a container, copied out to that file) and mounted
  read-only into task containers. The host `~/.claude` is never created. Headless alternative:
  `CLAUDE_CODE_OAUTH_TOKEN` (generate once with `claude setup-token`).
- **Browser login can't be fully automated** (the "Authorize" click is the security boundary);
  the CLI prints a URL/code and zero-interaction is only possible with a pre-provisioned token.
- **Docker group**: `usermod -aG docker` only takes effect on next login. Because `sg`/`newgrp`
  are not always present, both `install.sh` and `task` use a `docker`-or-`sudo docker` wrapper
  → Docker works immediately (via sudo) and drops the sudo prompt automatically once the group
  is active.

## 9. Hooks (in `claude/settings.json`, baked into the image, deterministic)

| Event | Command | Purpose |
|---|---|---|
| SessionStart | `serena-hooks activate` | activate the project + read Serena's instructions |
| PreToolUse (all) | `serena-hooks remind` | nudge the agent to use Serena over read/grep |
| PreToolUse (all) | `serena-hooks auto-approve` | auto-approve Serena tool calls in permissive mode |
| PreToolUse (Bash) | `rtk hook claude` | rewrite Bash commands to save tokens |
| SessionEnd | `serena-hooks cleanup` | clear the session's hook data |

These are committed in `settings.json` (not generated), so they survive rebuilds and rtk never
overwrites them.

## 10. Key design decisions

- **Container-only / host left clean** — the AI toolchain and config never touch the host; they
  live in the image and in `<workspace>/.workstation`. Only docker/git/gh may be installed, and
  they're tracked for a precise, point-by-point uninstall.
- **Serena over jCodeMunch** — jCodeMunch is dual-licensed (paid for commercial use); Serena is
  MIT, so it stays free as usage goes from personal to professional.
- **Wolfi base** — most minimal option that keeps glibc + near-zero CVEs.
- **Clone-per-task → container-per-task** — directories give light isolation; containers give
  strong isolation (filesystem/process/network) and match the future multi-agent model.
- **No hardcoded absolute paths** — everything is `$HOME`/workspace-relative; `/home/dev` is
  internal to the image only.
- **Repo stores hand-made config only** — the policy, prefs, hooks, statusline; secrets and
  runtime state are never committed (`.gitignore` covers `.apt-installed`, `.claude/`, creds).

## 11. Known limitations

- `task` prompts for the sudo password until your next login activates the docker group.
- Claude auth needs a one-time interactive `task auth` (or `CLAUDE_CODE_OAUTH_TOKEN`); the
  install does it automatically only when a TTY is available.
- The in-container status line is best-effort (needs jq, present; tput optional).
- The **autodev / headless** side (bot identity, hardened sandbox, orchestration) is future
  work — the image and container model are the shared foundation.

## 12. Update

```bash
git -C <workspace>/.workstation pull
docker build -t workstation <workspace>/.workstation
```

## 13. Uninstall (`uninstall.sh`)

Small footprint, **point-by-point confirmation** before every change (your work is never touched).

- **Auto-detects** the workstation dir from the `WORKSTATION_DIR` export in `~/.bashrc` (else
  `--dir`/`--home`, else `~/dev/.workstation`).
- **Asks, one at a time**, to remove: the `task` block in `~/.bashrc`; the `workstation` Docker
  image; each apt package we installed (read from `.apt-installed` — only `docker`/`git`/`gh`,
  and only those still present); your `docker`-group membership (only if a `.docker-group-added`
  marker shows we added it); and finally the `<workspace>/.workstation` dir (clone + Claude
  credentials).
- **Never had to touch**: `~/.claude` (never created), your gh login, your task clones, or any
  tool you already had — so there's nothing else to undo.
- Flags: `--dir`, `--home`, `--yes` (assume yes to every prompt).

## 14. Future: autodev / headless agents

The same image runs headless (`claude` non-interactive) with a dedicated bot GitHub identity
and `CLAUDE_CODE_OAUTH_TOKEN`, under tighter resource/network limits, orchestrated to run many
disposable containers against the same repo (each on its own branch, coordinated via PRs).
