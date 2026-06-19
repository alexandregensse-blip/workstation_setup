# workstation_setup — Design & Behaviors

Full reference for what this repo does and every behavior it implements.
For the quick start, see [README.md](README.md).

## 1. Purpose

A **portable workstation**: one command turns a fresh Ubuntu machine into a ready-to-use
Claude Code environment (Serena MCP + rtk), and provides a `task` command that runs each
piece of work as an **isolated, disposable Docker container**.

## 2. Mental model

- **Local is a disposable cache; GitHub is the only source of truth.** Anything correct is
  pushed; a task folder (or container) can be destroyed at any time without loss.
- **Pattern C / model A**: one container per task, and **Claude runs *inside* the container**,
  so everything it does (bash, edits, Serena, running code) stays sandboxed from the host.
- **Same principle for maintainer and (future) autodev agents**: same image, same container
  lifecycle, Git as the coordination layer — only the trigger and auth differ.

## 3. Repository layout

| Path | Role |
|---|---|
| `install.sh` | One-command, idempotent host installer. |
| `Dockerfile` | The `workstation` image baked from the same tools (Wolfi base). |
| `shell/task.sh` | The `task` shell function (isolated session launcher). |
| `claude/CLAUDE.md` | Global code-exploration policy (Serena). Deployed to `~/.claude/CLAUDE.md` and `<workspace>/AGENTS.md`. |
| `claude/settings.json` | Claude prefs **+ hooks** (Serena + rtk). No hardcoded language. |
| `claude/statusline.sh` | Custom status line. |
| `dev/CLAUDE.md` | Multi-repo working convention. Deployed to `<workspace>/CLAUDE.md`. |
| `README.md` / `DESIGN.md` | Quick start / this reference. |

## 4. Components

- **Claude Code** — the agent CLI (native installer, glibc binary).
- **Serena** (`serena-agent`, MIT) — semantic code MCP server (LSP-based). License-safe for
  commercial use, unlike jCodeMunch (dual-licensed) which this setup replaced.
- **rtk** (`rtk-ai/rtk`, MIT) — token-saving CLI proxy; hooks into Claude's Bash tool.
- **uv** — installs Serena and its standalone Python.
- **gh**, **git**, **ripgrep**, **jq**, **Docker**.

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
| `--home <path>`  | `WORKSTATION_HOME`  | workspace dir for task clones | prompt, else `~/dev` |
| `--repos <path>` | `WORKSTATION_REPOS` | tasks base | `<home>/repos` |
| `--dir <path>`   | `WORKSTATION_DIR`   | where the workstation lives | `~/.local/share/workstation` (hidden) |
| `--lang <code>`  | `WORKSTATION_LANG`  | Claude UI language | keep host pref, else system default |
| `--yes` / `-y`   | —                   | non-interactive (skip prompt) | — |

Missing flag values fail fast with a clear message (guarded against `set -u`).

### Behaviors, in order
1. **Workspace prompt** — unless `--home`/env given, or `--yes`, or no TTY (then `~/dev`).
2. **System packages** — installs **only what's missing** (curl, git, ripgrep, gh, node, npm,
   docker.io, jq) via a presence check.
3. **Self-bootstrap** — if not already run from a clone, clones the repo into the **hidden**
   `WORKSTATION_DIR` (or `git pull` if present).
4. **uv / Claude / Serena / rtk** — each installed only if absent (`command -v` guard).
5. **Dotfiles + workspace + `task`** — deploys the policy/settings/statusline, creates the
   workspace and tasks dirs, installs the `task` function and **auto-sources it in `~/.bashrc`**
   (only once). Language is resolved: **`--lang` > existing host preference > unset (system
   default)** and injected with `jq`.
6. **Serena MCP** — `serena setup claude-code`, skipped if already registered.
7. **rtk** — `rtk init -g --no-patch` (creates `RTK.md` + `@RTK.md`; does **not** touch
   `settings.json`, because the hooks are already declared there). Skipped if `RTK.md` exists.
8. **Docker group** — `usermod -aG docker` unless already a member.
9. **Image build** — builds `workstation` if missing, passing the resolved language as
   `--build-arg WS_LANG`. Uses the `docker`-or-`sudo docker` wrapper (see §8).
10. **Auth** — `gh auth login --web` and `claude auth login` only if not already authenticated
    (env tokens make this a no-op; see §8).
11. **Confirmation banner** — verifies every tool + the image, prints locations and `task` usage.

**Idempotency**: re-running installs/configures only what is missing; the committed
`settings.json` is the single source of truth for hooks (rtk never patches it).

## 6. Task workflow (`shell/task.sh`)

```
task [--here | --at <path>] <repo> <topic>
```

1. **Base selection** — `--here` (`$PWD`) > `--at <path>` > `$WORKSTATION_REPOS` >
   `${WORKSTATION_HOME:-$HOME/dev}/repos`.
2. **Auth checked up front** (no silent failure):
   - GitHub: requires `gh auth token` (else clear error).
   - Claude: mounts `~/.claude/.credentials.json` **if it exists**, else uses
     `$CLAUDE_CODE_OAUTH_TOKEN` (headless), else a clear error telling you to log in.
     (This avoids Docker silently creating a bogus directory for a missing mount source.)
3. **Clone on the host** → `<base>/<repo>/<YYYYMMDD-HHMM>_<slug>` — WIP survives the container.
4. **Branch** `task/<slug>` and push it.
5. **Run** Claude inside the container: clone mounted at `/work`, `GH_TOKEN` injected, Claude
   credentials mounted read-only, memory/cpu limits, `--rm` (disposable).
6. **On exit** — container destroyed; clone kept on host. Delete it only when `git status` is
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
- **Language**: `ARG WS_LANG` injected into the image's `settings.json` when provided.
- **Wiring**: `serena setup claude-code` (MCP), `rtk init -g --no-patch` (RTK.md only), and a
  git credential helper (`!gh auth git-credential`) so in-container `git push` uses `GH_TOKEN`.

Final image ≈ **194 MB**.

## 8. Auth model

- **GitHub** — host: gh keyring (or `GH_TOKEN`). Container: `GH_TOKEN="$(gh auth token)"`
  passed by `task`; the baked credential helper lets `git push` use it.
- **Claude** — host: `~/.claude/.credentials.json` (file-based; no keyring CLI present).
  Container: that file is mounted read-only, **or** `CLAUDE_CODE_OAUTH_TOKEN` for headless
  (generate once with `claude setup-token`).
- **Browser login can't be fully automated** (the "Authorize" click is the security boundary);
  the CLIs auto-open the browser, and zero-interaction is only possible with pre-provisioned
  tokens.
- **Docker group**: `usermod -aG docker` only takes effect on next login. Because `sg`/`newgrp`
  are not always present, both `install.sh` and `task` use a `docker`-or-`sudo docker` wrapper
  → Docker works immediately (via sudo) and drops the sudo prompt automatically once the group
  is active.

## 9. Hooks (in `claude/settings.json`, deterministic)

| Event | Command | Purpose |
|---|---|---|
| SessionStart | `serena-hooks activate` | activate the project + read Serena's instructions |
| PreToolUse (all) | `serena-hooks remind` | nudge the agent to use Serena over read/grep |
| PreToolUse (all) | `serena-hooks auto-approve` | auto-approve Serena tool calls in permissive mode |
| PreToolUse (Bash) | `rtk hook claude` | rewrite Bash commands to save tokens |
| SessionEnd | `serena-hooks cleanup` | clear the session's hook data |

These are committed in `settings.json` (not generated), so they survive re-runs and rtk never
overwrites them.

## 10. Key design decisions

- **Serena over jCodeMunch** — jCodeMunch is dual-licensed (paid for commercial use); Serena is
  MIT, so it stays free as usage goes from personal to professional.
- **Wolfi base** — most minimal option that keeps glibc + near-zero CVEs.
- **Clone-per-task → container-per-task** — directories give light isolation; containers give
  strong isolation (filesystem/process/network) and match the future multi-agent model.
- **No hardcoded absolute paths** — everything is `$HOME`-relative; `/home/dev` is internal to
  the image only.
- **Repo stores hand-made config only** — the policy, prefs, hooks, statusline; secrets are
  never committed (`.gitignore` has a safety net).

## 11. Known limitations

- `task` prompts for the sudo password until your next login activates the docker group.
- The in-container status line is best-effort (needs jq, present; tput optional).
- The **autodev / headless** side (bot identity, hardened sandbox, orchestration) is future
  work — the image and container model are the shared foundation.

## 12. Update

```bash
git -C ~/.local/share/workstation pull
uv tool upgrade serena-agent
docker build -t workstation ~/.local/share/workstation
```

## 13. Future: autodev / headless agents

The same image runs headless (`claude` non-interactive) with a dedicated bot GitHub identity
and `CLAUDE_CODE_OAUTH_TOKEN`, under tighter resource/network limits, orchestrated to run many
disposable containers against the same repo (each on its own branch, coordinated via PRs).
