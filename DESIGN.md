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
| `Dockerfile.base` | The heavy **`workstation-base`** image — the toolchain (Claude/Serena/rtk/uv + apk tools), built once and reused. |
| `Dockerfile` | The thin **`workstation`** image (`FROM workstation-base`) — bakes config/hooks; rebuilt on changes. |
| `<ws>/toolchains/<key>/Dockerfile` | Optional **per-repo** toolchains (host-side, not committed) → image `workstation-<key>` (`FROM workstation`). Built on demand by `task toolchain` / the next task (see §7). |
| `shell/task.sh` | The `task` shell function, **sourced straight from the clone**. |
| `.github/workflows/shellcheck.yml` | CI lint (shellcheck) over the shell scripts; signal-only. |
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
| `--lang <code>`  | `WORKSTATION_LANG`  | Claude UI language — seeds the `lang` feature (run-time, not baked) | unset (Claude default) |
| `--import-prefs` / `--no-import-prefs` | `WORKSTATION_IMPORT_PREFS` | import this machine's Claude prefs (statusline/lang/theme) | ask if a local Claude is found |
| `--no-ipv6` / `--ipv6` | `WORKSTATION_IPV6` | enable Docker IPv6 (NAT66) for task containers (see §7a) | auto — on if the host has routable IPv6 |
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
5. **Docker IPv6 (dual-stack)** — when the host has routable IPv6, enable Docker IPv6 (NAT66) so
   task containers aren't IPv4-only (see §7a). It **creates** `/etc/docker/daemon.json` (only if
   absent — it never edits an existing one), restarts docker, drops a `.docker-ipv6` marker for the
   uninstaller, and **rolls back** if docker doesn't come back up. Skip with `--no-ipv6`; auto-skipped
   when the host has no IPv6.
6. **Image build** — builds the heavy **`workstation-base`** (toolchain, from `Dockerfile.base`)
   only if missing, then the thin **`workstation`** (config + hooks, `FROM workstation-base`). Uses
   the `docker`-or-`sudo docker` wrapper (see §8). Optional features are applied at run time, not baked.
7. **`task` command** — auto-sourced in `~/.bashrc` (once), inside a `# >>> workstation >>>` …
   `# <<< workstation <<<` MINIMAL marked block: it exports only `WORKSTATION_DIR`/`WORKSTATION_RUNNING`
   and sources `task` **straight from the clone** (`$WS_DIR/shell/task.sh`). Feature settings are NOT
   exported here — install seeds them into `<ws>/.config` (first install only; notifications default
   ON, plus language/launch defaults), later edited by `task settings`, so the host env stays clean.
8. **GitHub auth** — `gh auth login --web` only if not already authenticated (skipped with no TTY).
9. **Claude login** — browser-logs in **inside a container** into the `default` login
   (`<ws>/.claude-slots/default/`, via `CLAUDE_CONFIG_DIR`; host `~/.claude` is never touched). No-op
   if `default` already exists or `CLAUDE_CODE_OAUTH_TOKEN` is set; deferred to `task auth default` if
   there's no TTY. See §8.
10. **Confirmation banner** — verifies docker/git/gh + the image, prints locations and `task` usage.

**Idempotency**: re-running installs/configures only what is missing. The committed
`settings.json` (baked in the image) is the single source of truth for hooks.

## 6. Task workflow (`shell/task.sh`)

```
task [--here | --at <path>] [repo] [topic]   # start a task (runs in the current tab)
task resume                                   # reopen clones (checkbox menu), each in a new tab, CONTINUE its Claude session
task list                                     # read-only status of all clones (running/idle, login, git state) + logins
task cleanup [-y] | -f | <name>               # delete clones; -f (checklist) or <name> also discards work
task settings                                 # show/edit features (notifications, language, theme, cpus/ram, DNS, launch defaults)
task toolchain [<repo>]                       # scaffold/edit a repo's extra toolchains → its own image (see §7)
task auth [<name> | rm <name>]                # manage Claude logins (independent, self-refreshing; see §8)
```

1. **`task auth`** — manages Claude *logins* (see §8): no arg lists them, `<name>` browser-logs into
   a login, `rm <name>` removes one. Each login is an independent, self-refreshing credential.
2. **Base selection** — `--here` (`$PWD`) > `--at <path>` > `$WORKSTATION_RUNNING` >
   `${WORKSTATION_HOME:-$HOME/dev}/running`. **Repo**: if omitted, pick from your `gh` repos or
   type `owner/name`/URL. **Topic**: if omitted, a timestamp is used as the task name.
3. **Auth checked up front** (no silent failure):
   - GitHub: requires `gh auth token` (else clear error).
   - Claude: auto-borrows a free **login** (§8); else `$CLAUDE_CODE_OAUTH_TOKEN` (headless); else a
     clear error pointing to `task auth <name>`.
4. **Clone on the host** → `<base>/<repo>/<YYYYMMDD-HHMMSS>_<slug>` (just the timestamp if no
   topic) — WIP survives the container. Known **MCP artifacts** (Serena's `.serena/` — cache,
   memories, project config) are added to the clone-LOCAL `.git/info/exclude` (never the repo's
   committed `.gitignore`), so they don't pollute `git status` on the host or in the container and
   vanish with the clone. Curated list in `_task_mcp_artifacts` (extend per MCP).
5. **Branch** `task/<slug>` and push it.
6. **Run** Claude inside the container: clone mounted at `/work`, `GH_TOKEN` injected, Claude
   credentials mounted read-only, `--rm` (disposable). The **image** is `workstation-<key>` if the repo
   has a per-repo toolchain spec (built/refreshed lazily, see §7), else the shared `workstation`.
   Resource limits are configurable: `cpus`/`ram` from `<ws>/.config` → `--cpus`/`--memory` (defaults `2` / `4g`). The conversation history
   is persisted on the host under the clone's `.git/claude-projects` (out of the worktree, removed
   with the clone). **Features** from `<ws>/.config` (`task settings`) apply here: `claude_mode`/
   `claude_model`/`claude_effort` → launch flags; `notify`/`lang`/`theme`/`statusline` → merged onto
   the baked settings.json via `claude --settings '{…}'`. That JSON is assembled **inside the
   container with jq** (the feature values are passed as `WS_*` env vars) — so it's always well-formed
   even for ad-hoc env overrides, and the host needs no jq; the baked Serena/rtk hooks are kept.
   `dns` → `--dns`. **Auto-memory** persists across *future* tasks (not just this clone): Claude's
   `autoMemoryDirectory` is pointed (via the same `--settings`) at `/memory`, a mounted host dir under
   `<ws>/.memory/<owner>-<repo>` (`memory=repo`, default — keyed by the clone's origin so same-named
   repos from different owners stay separate) or `<ws>/.memory/_global` (`memory=global`), so it
   survives the disposable container and is shared by every task on the repo; `memory=off` keeps it
   per-task. History stays per-clone — the two are separate mounts. The container emits a short
   `<repo> - <topic>` OSC tab title at startup (so VTE terminals don't leave the long `docker run`
   command in the title); Claude may then update it as the session goes. The container name is
   `task-<repo>-<clone>` (stable across start/resume; a natural guard against running a clone twice).
7. **On exit** — container destroyed; clone kept on host. Delete it only when `git status` is
   clean **and** nothing is unpushed (`git log @{u}..` empty).
8. **`task resume`** — lists existing clones in a **checkbox menu** (arrow keys, Space/Enter toggle,
   "Confirmer"), opens each pick in a **new terminal tab** (`task open`, propagating the current
   `WORKSTATION_*` settings since the tab is spawned by the terminal, not this shell) and relaunches
   the container with `claude --continue` so the saved conversation resumes. **`task list`** is a
   read-only status view (running/idle, which login, git state, + a logins summary; running containers
   are matched to clones by their `/work` mount source via `docker inspect --format`, so no host jq).
   **`task cleanup`** removes clones that are clean and fully pushed; `-f`/`--force` opens a **checkbox
   menu** to discard clones *including* their uncommitted/unpushed work, and `task cleanup <name>`
   targets matching clone(s) (with `-f` to discard their work). A clone mounted in a **running**
   container is never deleted (detected via the shared `_task_running_pairs`, same mount-source map as
   `list`). **`task settings`** edits the features in `<ws>/.config`. `resume`/`list`/`cleanup` scan
   the default `running/` base **plus** any base used via `--here`/`--at`, recorded in `<ws>/.bases`
   (so those clones aren't lost). The git "clean + pushed" check is one shared helper (`_task_git_state`)
   used by both `list` and `cleanup`.

## 7. The Docker image (`Dockerfile`)

- **Base: Chainguard Wolfi** (`wolfi-base`) — **glibc** (required by the prebuilt Claude/rtk/uv
  binaries; Alpine's musl would break them), minimal and low-CVE, with a shell + `apk` to install
  the tools at build.
- **`dev` user, uid 1000** — explicitly created to match the host user, so host-mounted files
  (clone, `0600` credentials) are readable. (A default new user would get uid 1001 and fail.)
- **Tools**: bash, curl, git, ripgrep, **python3** (kept — `uv -p 3.13` reuses it, avoiding a
  second standalone Python), gh, jq, shadow (useradd), ca-certificates.
- **Config baked in**: the policy, prefs + hooks, statusline and convention are COPYed into the
  image's `~/.claude` and `~/dev` — so the container is fully configured with no host deployment.
  **Optional features (incl. language) are NOT baked** — they're applied at run time by `task` (see §6).
- **GNU userland**: grep/sed/gawk/coreutils/findutils/diffutils/util-linux/flock/gzip/patch/procps are
  installed so in-container scripts get GNU behavior (e.g. `grep --include`, `date +%s%N`), not Wolfi's
  busybox fallbacks. Added as the LAST base layer so rebuilds reuse the cached toolchain above.
- **Wiring**: `serena setup claude-code` (MCP), `rtk init -g --no-patch` (RTK.md only), and a
  git credential helper (`!gh auth git-credential`) so in-container `git push` uses `GH_TOKEN`.

On-disk image ≈ **830 MB** (Claude Code alone ~234 MB).

**Two-layer build**: a heavy `workstation-base` (`Dockerfile.base`, the toolchain) built once and
reused, and a thin `workstation` (`Dockerfile`, `FROM workstation-base`) for config/hooks — so
changing the dotfiles never re-downloads the toolchain. `update.sh` rebuilds only the layer whose
inputs changed (§12).

**Per-repo toolchains (optional third layer).** A repo that needs extra tools (Go/Rust/C++…) without
bloating every other task declares them in `<ws>/toolchains/<key>/Dockerfile` (`<key>` = the
`<owner>-<repo>` from `_task_repo_key`; **host-side, NOT committed to the repo** — same host-clean
principle as the rest). `task` builds `workstation-<key>` **`FROM workstation`** (the line is
prepended automatically) and runs that repo's tasks on it; repos with no spec use the shared
`workstation` image, so one repo's toolchains never leak into another. The build is **lazy and
cached**: `_task_ensure_repo_image` rebuilds only when the image is missing, the Dockerfile changed
(mtime vs a `.image-base` stamp), or the base `workstation` image id moved — so an `update.sh`
self-heals every overlay on its next task. Concurrent launches for the same repo (e.g. resuming two
of its tasks at once) are serialized by a **pure-bash build lock** (the same `ln` hard-link mutex as
the login reservation, markers in `toolchains/.locks/`, stale-stolen after 1h) — the first builds,
the rest **wait then reuse**, so the heavy toolchain is never built twice in parallel.
`task toolchain` opens an **interactive menu** (like
`settings`: arrow keys) to **add / edit / remove** specs — each row shows whether its image is built;
`task toolchain <repo>` jumps straight to scaffolding/editing one. `uninstall.sh` removes all
`workstation-*` overlays. Build output is hidden unless it fails.

## 7a. Networking (containers ↔ Anthropic)

Task containers use Docker's **default bridge**. On a **dual-stack** host (e.g. SFR fibre: native
IPv6 + DS-Lite IPv4), the host transparently falls back to IPv6 when the IPv4 path degrades, but
default-bridge containers are **IPv4-only** — so they stall (`FailedToOpenSocket` / `ConnectionRefused`
inside the task) while the host session stays fine. Install therefore enables **Docker IPv6 (NAT66)**
when it detects routable host IPv6 (§5, step 5): it creates `/etc/docker/daemon.json` with `ipv6` +
`fixed-cidr-v6` + `ip6tables`, giving containers the same reach. Opt out with `--no-ipv6`. For a
network with flaky DNS, the `dns` feature (`task settings`) makes `task` pass those resolvers via
`--dns`. (Requires a recent Docker — NAT66 / `ip6tables` stable since Docker 27.)

## 8. Auth model

- **GitHub** — host: gh keyring (or `GH_TOKEN`). Container: `GH_TOKEN="$(gh auth token)"`
  passed by `task`; the baked credential helper lets `git push` use it.
- **Claude — logins** (`<ws>/.claude-slots/<name>/`). All Claude credentials are **logins** managed by
  `task auth`: a login is an **independent** Claude session — its own OAuth refresh token, possibly its
  **own Anthropic account**. Created by `task auth <name>` (an in-container `claude auth login` writing
  straight into the login dir via `CLAUDE_CONFIG_DIR`); install creates `default`. The host `~/.claude`
  is never read or copied (a copied token would share refresh-token rotation with the host and could
  log it out — and couldn't be a separate account).
- **Self-refreshing.** `_task_run` borrows a **free** login (sticky per clone, recorded in
  `.git/claude-slot`, so resume reuses it; a login is *busy* while a container labeled
  `workstation.slot=<name>` runs; all busy + TTY ⇒ offer to create one). Concurrent launches (resume
  opening many tabs at once) each get a **different** login via a lock-free reservation: a `.reservations/<name>`
  marker claimed by hard-linking a fully-written temp file (`ln` fails if it exists → atomic, pure
  bash — no `flock`), epoch-stamped and honored for 60 s (bridging the gap until the container's busy
  label appears). It mounts the login as the container's
  `CLAUDE_CONFIG_DIR` — a **writable directory**, so the atomic rename Claude uses works and it
  **refreshes its own token in place**, persisting it for the next task → **multi-day sessions survive,
  no `401`** (the old single read-only `.credentials.json` couldn't, hence the disconnections). The
  clone's history is overlaid at `/cfg/projects`; baked config is seeded into the login dir each start.
  Nothing is shared between logins or with the host, so concurrent refreshes never collide and logins
  stay on independent accounts. `task auth` lists them (account, free/busy, expiry); `task auth rm`.
- **Headless** — `CLAUDE_CODE_OAUTH_TOKEN` (generate once with `claude setup-token`): a task with no
  stored login runs with the env token (ephemeral, no refresh persistence).
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
`Dockerfile.base` moved, the thin image if config moved, or **nothing** if only docs/scripts
changed. `--fresh` forces a from-scratch base (`--pull --no-cache`) to fetch the
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
  `<workspace>/.workstation` dir (clone + Claude credentials). Clones made with `--here`/`--at` live
  **outside** the workspace and are **never deleted** — uninstall just lists them (from `<ws>/.bases`).
- **Never touches**: `~/.claude` (never created), your gh login, or any tool you already had.
- Flags: `--dir`, `--home`, `--yes` (assume yes to every prompt).

## 14. Future: autodev / headless agents

The same image runs headless (`claude` non-interactive) with a dedicated bot GitHub identity
and `CLAUDE_CODE_OAUTH_TOKEN`, under tighter resource/network limits, orchestrated to run many
disposable containers against the same repo (each on its own branch, coordinated via PRs).
