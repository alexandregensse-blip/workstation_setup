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
| `--lang`  / `WORKSTATION_LANG`  | Claude UI language (baked in the image) | unset (Claude default) |
| `--import-prefs` / `--no-import-prefs` | import this machine's Claude prefs (statusline/lang/theme) | ask if a local Claude is found |
| `--plug-ins` / `WORKSTATION_PLUGINS` | opt-in plugins, comma-separated keys (see `plugins/available`) | prompt per known plugin |
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
task cleanup [-y]                # delete clones that are clean AND fully pushed (asks; -y skips the prompt)
task settings                    # show your install choices; edit the Claude launch defaults
task auth [--slot <name>]        # (re)login to Claude; --slot makes an independent login (see Auth)
task slots                       # list credential slots (independent logins for parallel long tasks)
task help                        # full help (also shown for: task with no args)
```

Clones on the host (under `running/`), branches `task/<slug>`, then runs Claude in a **disposable
container** (Serena connected, auth mounted). On exit: container destroyed, clone kept on the host.

**Session persistence & resume** — each task keeps its Claude conversation history on the host inside
the clone's own `.git/claude-projects` (out of the worktree, never committed, removed with the clone).
So `task resume` (and `task open`) relaunch the disposable container and **continue where you left
off** (`claude --continue`) — handy after a reboot or a `docker restart`. A brand-new `task` starts
fresh; a clone that has no saved history just opens normally.

**Auto-launch flags** — set these in your shell (or `~/.bashrc`) and every `task` starts that way
(the container is the sandbox, so `auto`/`bypassPermissions` is reasonable):

```bash
export WORKSTATION_CLAUDE_MODE=auto      # --permission-mode: auto | acceptEdits | bypassPermissions | default
export WORKSTATION_CLAUDE_MODEL=opus     # --model: alias or full id
export WORKSTATION_CLAUDE_EFFORT=high    # --effort: low | medium | high | xhigh | max
```

> Everything Claude does stays in the container. The image uses a `dev` user
> with **uid 1000** so host-mounted files (clone, credentials) are readable. Docker **auto-falls back
> to `sudo`** until the `docker` group is active (next login) — so it works right away.

## Auth

- **GitHub** — host `gh` login (`gh auth token` passed to the container; a baked credential helper
  lets in-container `git push` use it).
- **Claude** — if you're **already logged into Claude on this machine**, install (and `task auth`)
  detect it, show the account, and offer to **reuse the existing token** (host `~/.claude` is only
  read, never modified). Otherwise `task auth` logs in **inside a container** (it prints a URL to
  open — the browser can't auto-open from a container). Either way the credentials are stored in
  `<workspace>/.workstation/.claude/.credentials.json` and mounted read-only into task containers.
  Headless: set `CLAUDE_CODE_OAUTH_TOKEN` instead.
- **Kept fresh automatically** — that stored copy is a snapshot, while your host login keeps
  refreshing its OAuth token; a stale copy makes tasks fail with **`Please run /login` / `401`**.
  So every `task` start **re-syncs the credentials from your host login when it's newer** (the host
  `~/.claude` is only *read*). Set `WORKSTATION_CLAUDE_NOSYNC=1` to opt out. A container can't
  self-heal this single shared login — Claude rewrites the file by atomic rename, which a single-file
  mount disallows — so it's fine for **one long task at a time** but a multi-hour task can hit `401`
  past the token's lifetime. For many **parallel** long tasks, use slots ↓.

### Credential slots (parallel, multi-day tasks)

A **slot** is an **independent** Claude login (its own refresh token, same account is fine — like
signing into Claude Code on another machine). Create as many as you'll run at once:

```bash
task auth --slot a      # logs in inside a container (prints a URL), once per slot
task auth --slot b
task slots              # list slots + free/busy + token expiry
```

A task automatically **borrows a free slot** (sticky per clone, so `resume` reuses the same one). Its
credentials are mounted as a **writable directory** (`CLAUDE_CONFIG_DIR`), so Claude **refreshes its
own token in place** and the session **survives for days**. Nothing is shared between slots or with
the host, so concurrent tasks never clobber each other's token (the failure mode of copying one login
everywhere). With **no slots configured**, tasks use the single host-synced login above (unchanged).

## Preferences

If a Claude install is found on the machine, install offers to **import your local preferences**
(statusline, language, theme, …). It merges them with the workstation's own Serena/rtk hooks
(host `permissions`/`enabledPlugins` are dropped) into `<workspace>/.workstation/.claude/` and
mounts them read-only into task containers — the host `~/.claude` is only read. Force with
`--import-prefs` / `--no-import-prefs`.

## Plugins (opt-in)

Extra capabilities are **baked into the image only when you ask for them** — the default image is
unchanged. Pick them with `--plug-ins peon-ping[,…]`, or answer the per-plugin prompt at install.
Known plugins live in `plugins/available`; each is installed by `plugins/install-plugin.sh` (add a
line + a case to extend). Selected plugins are recorded in `<workspace>/.workstation/.plugins`, and
the image is rebuilt when the selection changes.

- **peon-ping** — Warcraft "peon" sounds when Claude finishes / needs you. Installs its official
  way (downloads only the default sound packs, not the whole repo), merged alongside the Serena/rtk
  hooks. It adds `ffmpeg` to the image (≈ +90 MB, **only** when enabled) and makes `task` pass the
  host audio socket through (PulseAudio/PipeWire), so the sound plays on your speakers; silent if
  the host has no audio server.

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

Still-flaky DNS on a given network (e.g. a phone hotspot)? Set `WORKSTATION_DNS="1.1.1.1 8.8.8.8"`
and `task` passes those resolvers to the container.

## Image

Base: **Chainguard Wolfi** (`cgr.dev/chainguard/wolfi-base`) — a minimal, **glibc** "undistro"
(~14 MB base, ~0 CVEs). glibc is required by the prebuilt binaries (Claude Code, rtk, uv);
**Alpine (musl) is avoided** (it breaks them). Final image ≈ **194 MB**, `dev` user at uid 1000.

Built in **two layers**: a heavy **`workstation-base`** (the toolchain, from `Dockerfile.base`)
built **once and reused**, and the thin **`workstation`** (config + plugins, from `Dockerfile`,
`FROM workstation-base`) rebuilt on changes — so changing plugins/language **never re-downloads the
toolchain**. `update.sh` rebuilds only what changed; `--fresh` forces a from-scratch base for the latest tools.

## Update

```bash
<workspace>/.workstation/update.sh && source ~/.bashrc
```

Pulls the repo and rebuilds **only what changed** — the base if `Dockerfile.base` moved, the thin
image if config/plugins moved, or **nothing** if only docs/scripts changed (no rebuild for nothing),
keeping your language + plugins. `--fresh` forces a from-scratch base (`--pull --no-cache`) to fetch
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
