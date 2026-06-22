# workstation_setup

Portable workstation. On a fresh machine (Ubuntu), **one command** sets up Claude Code work as
**isolated Docker sessions** and adds the `task` command. **Container-only**: the whole AI toolchain
(Claude Code, Serena MCP, rtk, uv) and all config live inside the image and a self-contained
`<workspace>/.workstation` dir — **the host is left in its initial state** (only docker + git + gh,
installed if missing). No machine-specific absolute paths.

> Full design & every behavior: **[DESIGN.md](DESIGN.md)**.

## Install — one command

```bash
curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh | bash && source ~/.bashrc
```

It asks where to put your workspace (current dir / `~/dev` / custom), installs **only the missing**
host prerequisites (`docker`, `git`, `gh`), clones itself into `<workspace>/.workstation`, **builds
the Docker image** (which bakes Claude/Serena/rtk + hooks + your dotfiles), adds `task` to your
`.bashrc`, runs GitHub + Claude auth, and prints a confirmation.

The trailing **`&& source ~/.bashrc`** runs in your *current* shell (it's not part of the pipe), so
`task` is available immediately. If you drop it, run `source ~/.bashrc` (or open a new terminal)
afterward — a piped installer runs in a child process and can't load a shell function into its parent.

> The prompt and `sudo` read from `/dev/tty`, so the pipe form stays interactive.

### Headless / scripted

```bash
curl -fsSL .../install.sh | bash -s -- --home ~/dev --yes
```

| Flag / env | Meaning | Default |
|---|---|---|
| `--home`  / `WORKSTATION_HOME`  | workspace dir (clones + `.workstation`) | prompt, else `~/dev` |
| `--running` / `WORKSTATION_RUNNING` | task clones base | `<workspace>/running` |
| `--dir`   / `WORKSTATION_DIR`   | where the workstation lives | `<workspace>/.workstation` |
| `--lang`  / `WORKSTATION_LANG`  | Claude UI language — seeds the `lang` feature (run-time, not baked) | unset (Claude default) |
| `--import-prefs` / `--no-import-prefs` | import this machine's Claude prefs (statusline/lang/theme) | ask if a local Claude is found |
| `--no-ipv6` / `WORKSTATION_IPV6=0` | don't enable Docker IPv6 (NAT66) for task containers (see [Networking](#networking-ipv6)) | enable if the host has routable IPv6 |
| `--yes` / `-y` | non-interactive (skip the prompt) | — |

## Dependencies

**Prerequisites** (before the one-liner): Debian/Ubuntu, `sudo`, internet, and `bash` + `curl`.

**Installed on the host** by `install.sh` — only what's missing, and **only these three** (recorded
so `uninstall.sh` can offer to remove exactly them): `docker.io`, `git`, `gh`. The host gets nothing
else: no Claude/Serena/rtk/uv, no `~/.claude`.

The one other host change is conditional: on a **dual-stack** machine, install enables **Docker
IPv6** by *creating* `/etc/docker/daemon.json` (only if absent — it never edits an existing one) and
restarting docker. It's **recorded** so `uninstall.sh` reverts it, and you can skip it with
`--no-ipv6`. See [Networking](#networking-ipv6).

**Inside the Docker image** (Wolfi / `apk`): `bash`, `curl`, `git`, `ripgrep`, `python3`, `gh`, `jq`,
`shadow`, `ca-certificates`, plus `uv`, Claude Code, **Serena**, **rtk** — and the baked config
(settings + Serena/rtk hooks + policy + statusline).

## Work

```bash
task <repo> [topic]              # start: repo fuzzy-matched to your gh repos; topic → timestamp if omitted
task --here <repo> [topic]       # base = current directory
task --at /path <repo> [topic]   # base = given path
task resume                      # reopen task clones (pick some in a checkbox menu), each in a new tab, CONTINUING its Claude session
task list                        # status of every clone: running/idle, which login, git state — plus a logins summary
task cleanup [-y]                # delete clones that are clean AND fully pushed (asks; -y skips the prompt)
task cleanup -f                  # checkbox menu to DISCARD clones incl. uncommitted/unpushed work
task cleanup <name> [-f]         # target clone(s) matching <name>; -f also discards their work
task settings                    # show/edit features (notifications, language, theme, cpus/ram, DNS, launch defaults)
task toolchain [<repo>]          # add per-repo toolchains (Go/Rust/C++…): a dedicated image FROM workstation
task auth                        # list Claude logins (account, free/busy, token expiry)
task auth <name>                 # browser-login into <name> — an independent, self-refreshing login
task auth rm <name>              # remove a login
task help                        # full help (also shown for: task with no args)
```

Clones on the host (under `running/`), branches `task/<slug>`, then runs Claude in a **disposable
container** (Serena connected, auth mounted). On exit: container destroyed, clone kept on the host.

**Session persistence & resume** — each task keeps its Claude conversation history on the host inside
the clone's own `.git/claude-projects` (out of the worktree, never committed, removed with the clone).
So `task resume` (and `task open`) relaunch the disposable container and **continue where you left
off** (`claude --continue`) — handy after a reboot or a `docker restart`. A brand-new `task` starts
fresh; a clone that has no saved history just opens normally.

Distinct from history, **Claude's auto-memory persists across *different* tasks**: history is
per-clone (for resume), but memory is per-repo — see the `memory` feature below. So what Claude
learns about a repo in one task is available in the next, while each task keeps its own transcript.

**MCP artifacts stay out of `git status`** — tools like Serena write a `.serena/` dir (cache,
memories, project config) into the repo. `task` adds known MCP artifacts to the clone-local
`.git/info/exclude` (never the repo's committed `.gitignore` — we don't impose our tooling on the
project), so they're invisible to git on the host and in the container, and vanish with the clone.
The list is curated (Serena today); extend `_task_mcp_artifacts` in `shell/task.sh` to add an MCP.

**Features** — optional capabilities applied to every task, set with **`task settings`** and stored
in `<workspace>/.workstation/.config` (a `key=value` file — **not** host env vars, so your shell
environment stays clean). They take effect on the next task, no rebuild:

| Feature | Effect |
|---|---|
| `memory` | persist Claude's auto-memory across future tasks: `repo` (default — keyed by `<owner>-<repo>` so same-named repos from different owners stay separate), `global` (all repos), `off` (per-task). Stored in `.workstation/.memory/` |
| `notify` | `terminal_bell` → bell + flash when Claude is done / needs you (native; via `claude --settings`) |
| `lang` | Claude UI language code (e.g. `fr`) |
| `theme` | `dark` / `light` / … |
| `statusline` | `off` to disable the status line |
| `dns` | reliable resolvers for the container, e.g. `1.1.1.1 8.8.8.8` (flaky-network hotspots) |
| `cpus` / `ram` | container resource limits per task — `cpus` (e.g. `2`, `1.5`) and `ram` (e.g. `512m`, `4g`). Defaults `2` / `4g` |
| `claude_mode` / `claude_model` / `claude_effort` | launch defaults: `--permission-mode` / `--model` / `--effort` (the container is the sandbox, so `auto` is reasonable) |

> Each also accepts an ad-hoc env override (`WORKSTATION_NOTIFY`, `WORKSTATION_CLAUDE_MODE`, …) for a
> one-off, but we never write those to your `~/.bashrc`.

> Everything Claude does stays in the container. The image uses a `dev` user
> with **uid 1000** so host-mounted files (clone, credentials) are readable. Docker **auto-falls back
> to `sudo`** until the `docker` group is active (next login) — so it works right away.

## Recipes (one per use case)

**Start working on a repo** — `autodev` is fuzzy-matched against your GitHub repos; it clones, branches
`task/fix-login`, and opens Claude in a disposable container:
```bash
task autodev fix-login
```

**Start from a repo you're already in** (base = current dir instead of `running/`):
```bash
cd ~/projects/site && task site hotfix
task --here site hotfix          # equivalent, explicit
task --at /srv/code site hotfix  # base = a given path
```

**Reopen earlier tasks and continue their Claude conversation** (checkbox menu; each reopens in a tab):
```bash
task resume
```

**See what's running and which login each task uses** (read-only; includes git state + logins):
```bash
task list
```

**Delete finished clones** — only those that are clean AND fully pushed are removed:
```bash
task cleanup        # asks per clone
task cleanup -y     # no prompts
```

**Throw away a task you don't want to keep** (discards uncommitted/unpushed work — local is disposable):
```bash
task cleanup -f             # checkbox menu: tick the ones to discard, confirm once
task cleanup fix-login -f   # or target one by name
```
> A clone mounted in a **running** container is never deleted — exit that task first.

**Get notified when Claude finishes / needs you** (terminal bell + window flash):
```bash
task settings       # set  notify = terminal_bell
```

**Always launch Claude a certain way** (no per-task flags):
```bash
task settings       # set  claude_mode = auto,  claude_model = opus,  claude_effort = high
```

**Cap (or raise) each task's container resources** (defaults 2 CPUs / 4g):
```bash
task settings                                  # set  cpus = 4,  ram = 8g
WORKSTATION_CPUS=1 WORKSTATION_RAM=2g task autodev small-job   # or one-off
```

**Give one repo extra toolchains** (e.g. Go/Rust/C++ to build & run its test mockups) without bloating
the others — that repo gets its own image `FROM workstation`:
```bash
task toolchain            # interactive menu (like 'settings'): add / edit / remove per-repo toolchains
task toolchain myrepo     # or jump straight in: scaffolds toolchains/<owner>-<repo>/Dockerfile + opens $EDITOR
# add e.g.:  USER root
#            RUN apk add --no-cache go-1.25 rustup clang-17 lld-17 cmake ninja-build build-base
#            RUN rustup toolchain install stable nightly && rustup component add clippy miri
#            USER dev
task myrepo build-mockups # first task on myrepo builds 'workstation-<owner>-<repo>' (FROM workstation), then runs on it
```
The Dockerfile lives **host-side** (`<workspace>/.workstation/toolchains/`), not committed to the repo.
It's rebuilt automatically when you edit it or after a base `update.sh`. Repos with no toolchain spec
keep using the shared `workstation` image. `FROM workstation` is prepended for you — don't add your own.

**Override one setting for a single task** (env var — never written to your shell config):
```bash
WORKSTATION_CLAUDE_MODEL=sonnet task autodev quick-experiment
```

**Persist what Claude learns about a repo across tasks** (per-repo by default; switch scope or disable):
```bash
task settings       # set  memory = repo (default) | global | off
```

**Run several long (hours/days) tasks in parallel** — one independent login per concurrent task:
```bash
task auth work                # browser login, once per login (can be a different account)
task auth perso
task auth                     # see logins: account, free / busy, token expiry
task autodev big-refactor     # auto-borrows a free login
task site i18n-migration      # borrows another
```

**Work on a flaky network** (phone hotspot, captive DNS):
```bash
task settings                              # set  dns = 1.1.1.1 8.8.8.8
WORKSTATION_DNS="1.1.1.1 8.8.8.8" task site demo   # or one-off
```

**See / change everything** and **update / remove**:
```bash
task settings                              # show all features + edit
~/dev/.workstation/update.sh && source ~/.bashrc   # latest; silent unless a build fails
~/dev/.workstation/uninstall.sh            # remove, asking before each step
```

## Auth

- **GitHub** — host `gh` login (`gh auth token` passed to the container; a baked credential helper
  lets in-container `git push` use it).
- **Claude — logins.** Credentials are managed entirely through **`task auth`**. A *login* is an
  **independent, self-refreshing** Claude session stored in `<workspace>/.workstation/.claude-slots/<name>/`
  — its own OAuth token, and it can be its **own Anthropic account**. Install creates a `default`
  login; add more for parallel tasks / extra accounts.

```bash
task auth                 # list logins: name, account, free/busy, token expiry
task auth default         # browser-login into 'default' (prints a URL — the browser can't auto-open
                          # from a container; authorizing redirects and captures the code for you)
task auth work            # another independent login (a different account is fine)
task auth rm work         # remove one
```

- **Self-refreshing — no more `Please run /login` / `401`.** Each login is mounted into the task as a
  **writable directory** (`CLAUDE_CONFIG_DIR`), so Claude **refreshes its own token in place** and a
  session **survives for days**. (The old single read-only credential couldn't do that — a single-file
  mount forbids the atomic rename Claude uses — which is why long tasks used to drop.)
- **A task auto-borrows a free login** (sticky per clone, so `resume` reuses the same one). Run
  several logins to drive **parallel** long tasks; if all are busy when you start one, `task` offers
  to create another on the spot. Nothing is shared between logins or with the host `~/.claude`, so
  concurrent refreshes never collide and different logins stay on different accounts.
- **Headless**: set `CLAUDE_CODE_OAUTH_TOKEN` and tasks run with no stored login (ephemeral, no refresh).

## Preferences

If a Claude install is found on the machine, install offers to **import your local preferences**
(statusline, language, theme, …). It merges them with the workstation's own Serena/rtk hooks
(host `permissions`/`enabledPlugins` are dropped) into `<workspace>/.workstation/.claude/` and
mounts them read-only into task containers — the host `~/.claude` is only read. Force with
`--import-prefs` / `--no-import-prefs`.

## Networking (IPv6)

Task containers run on Docker's **default bridge**. On a **dual-stack** network (e.g. SFR fibre:
native IPv6 + DS-Lite IPv4), the **host** transparently falls back to IPv6 when the IPv4 path
degrades — but default-bridge containers are **IPv4-only**, so they'd get stuck on the bad IPv4 path
and Claude would drop inside the task (`FailedToOpenSocket` / `ConnectionRefused`) **while your host
session stays fine**. To give containers the same reach, install **enables Docker IPv6 (NAT66)** when
it detects routable IPv6 on the host: it **creates** `/etc/docker/daemon.json` with

```json
{ "ipv6": true, "fixed-cidr-v6": "fd00:dead:beef::/64", "ip6tables": true }
```

restarts docker, and **records it** so `uninstall.sh` can revert (it rolls back automatically if
docker won't restart). It **won't edit an existing `daemon.json`** — it prints the keys to add
instead. Skip entirely with `--no-ipv6` (or `WORKSTATION_IPV6=0`); on a host without IPv6 it's
skipped on its own. Requires a recent Docker (NAT66 / `ip6tables` is stable since Docker 27).

Still-flaky DNS on a given network (e.g. a phone hotspot)? Set the `dns` feature (`task settings`, or
a one-off `WORKSTATION_DNS="1.1.1.1 8.8.8.8"`) and `task` passes those resolvers to the container.

## Image

Base: **Chainguard Wolfi** (`cgr.dev/chainguard/wolfi-base`) — a minimal, **glibc** "undistro"
(~14 MB base, ~0 CVEs). glibc is required by the prebuilt binaries (Claude Code, rtk, uv);
**Alpine (musl) is avoided** (it breaks them). The image bundles the GNU userland (grep/coreutils/
findutils/diffutils/util-linux/procps/…) so in-container scripts behave like a normal GNU box, not
busybox. On-disk ≈ **830 MB** (Claude Code alone is ~234 MB); `dev` user at uid 1000.

Built in **layers**: a heavy **`workstation-base`** (the toolchain, from `Dockerfile.base`)
built **once and reused**, and the thin **`workstation`** (config + hooks, from `Dockerfile`,
`FROM workstation-base`) rebuilt on changes — so changing the dotfiles **never re-downloads the
toolchain**. `update.sh` rebuilds only what changed; `--fresh` forces a from-scratch base for the latest tools.
A repo that needs extra tools gets a third, **per-repo** layer **`workstation-<owner>-<repo>`**
(`FROM workstation`), built on demand from its own `toolchains/<key>/Dockerfile` — see
[`task toolchain`](#work) — so one repo's Go/Rust/C++ stack never lands in another's tasks.

## Update

```bash
<workspace>/.workstation/update.sh && source ~/.bashrc
```

Pulls the repo and rebuilds **only what changed** — the base if `Dockerfile.base` moved, the thin
image if config moved, or **nothing** if only docs/scripts changed (no rebuild for nothing). Builds
are **quiet** — docker's step-by-step output is hidden and only shown if a build fails.
`--fresh` forces a from-scratch base (`--pull --no-cache`) to fetch
the latest Claude/Serena/rtk. The trailing `&& source ~/.bashrc` reloads `task` in your current
shell if it changed — running the script is a child process, so it can't do that by itself.

## Uninstall

```bash
<workspace>/.workstation/uninstall.sh        # asks before each step, then recaps
```

Removes, **one confirmation at a time**: the `task` block in `.bashrc`, the Docker image, the apt
packages it installed (`docker`/`git`/`gh` — only those, read from a manifest), your docker-group
membership (only if it added you), the Docker IPv6 `daemon.json` (only if install created it; restarts
docker), your **task clones** under `running` (it **git-scans them first** and tells you which still
have unpushed/uncommitted work), and the `.workstation` dir (clone + Claude credentials). Ends with a recap of what was removed vs kept; `~/.claude` and your gh login
are never touched. `--yes` for non-interactive.
