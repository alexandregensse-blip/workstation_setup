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
- **One container per task**, and **Claude runs *inside* the container**, so everything it does
  (bash, edits, Serena, running code) stays sandboxed from the host.
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
| `uninstall.sh` | Reverses it, asking **point-by-point**, then recaps (see §13). |
| `update.sh` | Pulls latest + rebuilds the image (see §12). |
| `plugins/` | Opt-in plugin registry (`available`) + installer (`install-plugin.sh`) (see §5). |
| `Dockerfile.base` | The heavy **`workstation-base`** image — the toolchain (Claude/Serena/rtk/uv + apk tools), built once and reused. |
| `Dockerfile` | The thin **`workstation`** image (`FROM workstation-base`) — bakes config/hooks/plugins; rebuilt on changes. |
| `shell/task.sh` | The `task` shell function, **sourced straight from the clone**. |
| `claude/CLAUDE.md` | Global code-exploration policy (Serena). Baked into the image at `~/.claude/CLAUDE.md`. |
| `claude/settings.json` | Claude prefs **+ hooks** (Serena + rtk). Baked into the image. No hardcoded language. |
| `claude/statusline.sh` | Custom status line. Baked into the image. |
| `dev/CLAUDE.md` | Multi-repo working convention. Baked into the image. |
| `README.md` / `DESIGN.md` | Quick start / this reference. |

The dotfiles are **deployed into the image only** — never copied to the host.

## 4. Components (all inside the image)

- **Claude Code** — the agent CLI (native installer, glibc binary).
- **Serena** (`serena-agent`, MIT) — semantic code MCP server (LSP-based), free for commercial use.
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
| `--running <path>` | `WORKSTATION_RUNNING` | task clones base | `<workspace>/running` |
| `--dir <path>`   | `WORKSTATION_DIR`   | where the workstation lives | `<workspace>/.workstation` |
| `--lang <code>`  | `WORKSTATION_LANG`  | Claude UI language (baked in the image) | unset (Claude default) |
| `--import-prefs` / `--no-import-prefs` | `WORKSTATION_IMPORT_PREFS` | import this machine's Claude prefs (statusline/lang/theme) | ask if a local Claude is found |
| `--plug-ins <list>` | `WORKSTATION_PLUGINS` | opt-in plugins, comma-separated keys | prompt per known plugin |
| `--no-ipv6` / `--ipv6` | `WORKSTATION_IPV6` | enable Docker IPv6 (NAT66) for task containers (see §7a) | auto — on if the host has routable IPv6 |
| `--yes` / `-y`   | —                   | non-interactive (skip prompt) | — |

**Plugins (opt-in, baked on demand).** `plugins/available` lists selectable plugins; install offers
each (or takes `--plug-ins`). The chosen keys go to the build as `--build-arg WS_PLUGINS`, and the
Dockerfile runs `plugins/install-plugin.sh sysdeps|user <key>` for each — so the default image is
unchanged and one plugin can't break the build (each call is non-fatal). The selection is recorded
in `.workstation/.plugins` (rebuild on change). If a plugin wants host audio it drops a marker in
the image; install mirrors it to `.workstation/.audio`, and `task` then passes the PulseAudio/PipeWire
socket through (uid 1000 matches; silent if the host has no audio server). First plugin: **peon-ping**
(notification sounds + `ffmpeg`, hooks merged with Serena/rtk).

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
5. **Docker IPv6 (dual-stack)** — when the host has routable IPv6, enable Docker IPv6 (NAT66) so
   task containers aren't IPv4-only (see §7a). It **creates** `/etc/docker/daemon.json` (only if
   absent — it never edits an existing one), restarts docker, drops a `.docker-ipv6` marker for the
   uninstaller, and **rolls back** if docker doesn't come back up. Skip with `--no-ipv6`; auto-skipped
   when the host has no IPv6.
6. **Image build** — builds the heavy **`workstation-base`** (toolchain, from `Dockerfile.base`)
   only if missing, then the thin **`workstation`** (config + plugins, `FROM workstation-base`),
   passing `--build-arg WS_LANG`/`WS_PLUGINS`. Uses the `docker`-or-`sudo docker` wrapper (see §8).
7. **`task` command** — auto-sourced in `~/.bashrc` (once), inside a `# >>> workstation >>>` …
   `# <<< workstation <<<` marked block that also exports `WORKSTATION_DIR`/`WORKSTATION_RUNNING`
   (and any `WORKSTATION_CLAUDE_*` launch defaults). The block sources `task` **straight from the
   clone** (`$WS_DIR/shell/task.sh`).
8. **GitHub auth** — `gh auth login --web` only if not already authenticated (skipped with no TTY).
9. **Claude credentials** — logs in **inside a container** and copies the resulting
   `.credentials.json` to `<workspace>/.workstation/.claude/` (host `~/.claude` stays untouched).
   No-op if a stored file exists or `CLAUDE_CODE_OAUTH_TOKEN` is set; deferred to `task auth` if
   there's no TTY.
10. **Confirmation banner** — verifies docker/git/gh + the image, prints locations and `task` usage.

**Idempotency**: re-running installs/configures only what is missing. The committed
`settings.json` (baked in the image) is the single source of truth for hooks.

## 6. Task workflow (`shell/task.sh`)

```
task [--here | --at <path>] [repo] [topic]   # start a task (runs in the current tab)
task resume                                   # reopen clones (checkbox menu), each in a new tab, CONTINUE its Claude session
task cleanup [-y]                             # delete clones that are clean AND fully pushed
task settings                                 # show install choices; edit the Claude launch defaults
task auth                                     # (re)login to Claude, stored in <workspace>/.workstation/.claude
```

1. **`task auth`** — runs `claude auth login` in a throwaway container and persists the
   credentials to `<workspace>/.workstation/.claude/.credentials.json`.
2. **Base selection** — `--here` (`$PWD`) > `--at <path>` > `$WORKSTATION_RUNNING` >
   `${WORKSTATION_HOME:-$HOME/dev}/running`. **Repo**: if omitted, pick from your `gh` repos or
   type `owner/name`/URL. **Topic**: if omitted, a timestamp is used as the task name.
3. **Auth checked up front** (no silent failure):
   - GitHub: requires `gh auth token` (else clear error).
   - Claude: mounts `<workstation>/.claude/.credentials.json` **if it exists**, else uses
     `$CLAUDE_CODE_OAUTH_TOKEN`, else a clear error pointing to `task auth`.
4. **Clone on the host** → `<base>/<repo>/<YYYYMMDD-HHMMSS>_<slug>` (just the timestamp if no
   topic) — WIP survives the container.
5. **Branch** `task/<slug>` and push it.
6. **Run** Claude inside the container: clone mounted at `/work`, `GH_TOKEN` injected, Claude
   credentials mounted read-only, memory/cpu limits, `--rm` (disposable). The conversation history
   is persisted on the host under the clone's `.git/claude-projects` (out of the worktree, removed
   with the clone). Optional knobs: `WORKSTATION_CLAUDE_*` set launch flags (`--permission-mode` /
   `--model` / `--effort`); `WORKSTATION_DNS` overrides the container resolver; the tab is titled
   `<repo> - <topic>` and Claude runs with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` so it keeps that.
7. **On exit** — container destroyed; clone kept on host. Delete it only when `git status` is
   clean **and** nothing is unpushed (`git log @{u}..` empty).
8. **`task resume`** — lists existing clones in a **checkbox menu** (arrow keys, Space/Enter toggle,
   "Confirmer"), opens each pick in a **new terminal tab** (`task open`, propagating the current
   `WORKSTATION_*` settings since the tab is spawned by the terminal, not this shell) and relaunches
   the container with `claude --continue` so the saved conversation resumes. **`task cleanup`**
   removes clones that are clean and fully pushed; **`task settings`** shows install choices and
   edits the launch defaults in the `~/.bashrc` block.

## 7. The Docker image (`Dockerfile`)

- **Base: Chainguard Wolfi** (`wolfi-base`) — **glibc** (required by the prebuilt Claude/rtk/uv
  binaries; Alpine's musl would break them), minimal and low-CVE, with a shell + `apk` to install
  the tools at build.
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

**Two-layer build**: a heavy `workstation-base` (`Dockerfile.base`, the toolchain) built once and
reused, and a thin `workstation` (`Dockerfile`, `FROM workstation-base`) for config/plugins — so
changing language/plugins never re-downloads the toolchain. `update.sh` rebuilds only the layer
whose inputs changed (§12).

## 7a. Networking (containers ↔ Anthropic)

Task containers use Docker's **default bridge**. On a **dual-stack** host (e.g. SFR fibre: native
IPv6 + DS-Lite IPv4), the host transparently falls back to IPv6 when the IPv4 path degrades, but
default-bridge containers are **IPv4-only** — so they stall (`FailedToOpenSocket` / `ConnectionRefused`
inside the task) while the host session stays fine. Install therefore enables **Docker IPv6 (NAT66)**
when it detects routable host IPv6 (§5, step 5): it creates `/etc/docker/daemon.json` with `ipv6` +
`fixed-cidr-v6` + `ip6tables`, giving containers the same reach. Opt out with `--no-ipv6`. For a
network with flaky DNS, `WORKSTATION_DNS="1.1.1.1 8.8.8.8"` makes `task` pass those resolvers via
`--dns`. (Requires a recent Docker — NAT66 / `ip6tables` stable since Docker 27.)

## 8. Auth model

- **GitHub** — host: gh keyring (or `GH_TOKEN`). Container: `GH_TOKEN="$(gh auth token)"`
  passed by `task`; the baked credential helper lets `git push` use it.
- **Claude** — credentials live in `<workspace>/.workstation/.claude/.credentials.json`, mounted
  read-only into task containers. They are obtained by, in order: (1) **reusing an existing host
  login** if `~/.claude/.credentials.json` is present — install/`task auth` show the account
  (`emailAddress` read from `~/.claude.json`) and ask before copying it (the host file is only
  read, never modified); (2) else a login **inside a container** (`task auth`), which prints a URL
  to open — the browser can't auto-open from inside a container; (3) else `CLAUDE_CODE_OAUTH_TOKEN`
  (generate once with `claude setup-token`). The host `~/.claude` is never written.
- **Token freshness.** The stored copy is a snapshot; the host login keeps refreshing its OAuth
  access token, so the copy goes stale and tasks fail with `Please run /login` / `401`. A task
  container **cannot self-heal**: Claude rewrites `.credentials.json` by atomic rename, which a
  single-file bind mount rejects (`Device or resource busy`). So `_task_run` **re-syncs the copy
  from the host login whenever the host file is newer** (still read-only on the host — we copy *from*
  it), and `task auth` offers the same when its copy is missing or older. Opt out with
  `WORKSTATION_CLAUDE_NOSYNC=1` (tasks then keep their own independent `task auth` credential).
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
- **Serena (MIT) for code intelligence** — LSP-based semantic MCP, free for commercial use.
- **Wolfi base** — minimal, glibc, near-zero CVEs.
- **Container per task** — strong isolation (filesystem/process/network) and a fit for the
  multi-agent model.
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

## 12. Update (`update.sh`)

```bash
<workspace>/.workstation/update.sh        # pull latest + rebuild
```

`git pull`s the clone, then rebuilds **only what the pull actually changed** — the base if
`Dockerfile.base` moved, the thin image if config/plugins moved, or **nothing** if only docs/scripts
changed — **keeping the baked language + plugins** (read from the current image and
`.workstation/.plugins`). `--fresh` forces a from-scratch base (`--pull --no-cache`) to fetch the
latest Claude/Serena/rtk. Output is concise (git's transfer noise is suppressed). Flags: `--dir`,
`--home`, `--fresh`, `--yes`. `task` is sourced from the clone, so a shell change is applied by
`source ~/.bashrc` (or a new terminal).

## 13. Uninstall (`uninstall.sh`)

Small footprint, **point-by-point confirmation** before every change, then a **recap** of what was
removed vs kept.

- **Auto-detects** the workstation dir and the `running` dir from the `WORKSTATION_DIR` /
  `WORKSTATION_RUNNING` exports in `~/.bashrc` (else `--dir`/`--home`, else `~/dev/…`).
- **Asks, one at a time**, to remove: the `task` block in `~/.bashrc`; the `workstation` and
  `workstation-base` Docker images; each apt package we installed (read from `.apt-installed` — only
  `docker`/`git`/`gh`, still-present); your `docker`-group membership (only if a `.docker-group-added`
  marker shows we added it); the **Docker IPv6 `daemon.json`** (only if a `.docker-ipv6` marker shows
  install created it — restarts docker); your **task clones** under `running` — **git-scanned first**,
  so it lists exactly which clones still have uncommitted or unpushed work before you decide; and the
  `<workspace>/.workstation` dir (clone + Claude credentials).
- **Never touches**: `~/.claude` (never created), your gh login, or any tool you already had.
- Flags: `--dir`, `--home`, `--yes` (assume yes to every prompt).

## 14. Future: autodev / headless agents

The same image runs headless (`claude` non-interactive) with a dedicated bot GitHub identity
and `CLAUDE_CODE_OAUTH_TOKEN`, under tighter resource/network limits, orchestrated to run many
disposable containers against the same repo (each on its own branch, coordinated via PRs).
