# workstation_setup

Portable workstation. On a fresh machine (Ubuntu), **one command** sets up Claude Code work as
**isolated Docker sessions** and adds the `task` command. **Container-only**: the whole AI toolchain
(Claude Code, Serena MCP, rtk, uv) and all config live inside the image and a self-contained
`<workspace>/.workstation` dir — **the host is left in its initial state** (only docker + git + gh,
installed if missing). No machine-specific absolute paths.

> Full design & every behavior: **[DESIGN.md](DESIGN.md)**.

## Install — one command

```bash
curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh | bash
```

It asks where to put your workspace (current dir / `~/dev` / custom), installs **only the missing**
host prerequisites (`docker`, `git`, `gh`), clones itself into `<workspace>/.workstation`, **builds
the Docker image** (which bakes Claude/Serena/rtk + hooks + your dotfiles), **auto-sources `task`**
into your `.bashrc`, runs GitHub + Claude auth, and prints a confirmation.

> The prompt and `sudo` read from `/dev/tty`, so the pipe form stays interactive.

### Headless / scripted

```bash
curl -fsSL .../install.sh | bash -s -- --home ~/dev --yes
```

| Flag / env | Meaning | Default |
|---|---|---|
| `--home`  / `WORKSTATION_HOME`  | workspace dir (clones + `.workstation`) | prompt, else `~/dev` |
| `--repos` / `WORKSTATION_REPOS` | tasks base | `<home>/repos` |
| `--dir`   / `WORKSTATION_DIR`   | where the workstation lives | `<home>/.workstation` |
| `--lang`  / `WORKSTATION_LANG`  | Claude UI language (baked in the image) | unset (Claude default) |
| `--import-prefs` / `--no-import-prefs` | import this machine's Claude prefs (statusline/lang/theme) | ask if a local Claude is found |
| `--yes` / `-y` | non-interactive (skip the prompt) | — |

## Dependencies

**Prerequisites** (before the one-liner): Debian/Ubuntu, `sudo`, internet, and `bash` + `curl`.

**Installed on the host** by `install.sh` — only what's missing, and **only these three** (recorded
so `uninstall.sh` can offer to remove exactly them): `docker.io`, `git`, `gh`. The host gets nothing
else: no Claude/Serena/rtk/uv, no `~/.claude`.

**Inside the Docker image** (Wolfi / `apk`): `bash`, `curl`, `git`, `ripgrep`, `python3`, `gh`, `jq`,
`shadow`, `ca-certificates`, plus `uv`, Claude Code, **Serena**, **rtk** — and the baked config
(settings + Serena/rtk hooks + policy + statusline).

## Work

```bash
task <repo> <topic>              # default base
task --here <repo> <topic>       # base = current directory
task --at /path <repo> <topic>   # base = given path
task auth                        # (re)login to Claude (stored in .workstation/.claude)
```

Clones on the host, branches `task/<slug>`, then runs Claude in a **disposable container** (Serena
connected, auth mounted). On exit: container destroyed, clone kept on the host.

> **Pattern C / model A**: everything Claude does stays in the container. The image uses a `dev` user
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

## Preferences

If a Claude install is found on the machine, install offers to **import your local preferences**
(statusline, language, theme, …). It merges them with the workstation's own Serena/rtk hooks
(host `permissions`/`enabledPlugins` are dropped) into `<workspace>/.workstation/.claude/` and
mounts them read-only into task containers — the host `~/.claude` is only read. Force with
`--import-prefs` / `--no-import-prefs`.

## Image

Base: **Chainguard Wolfi** (`cgr.dev/chainguard/wolfi-base`) — a minimal, **glibc** "undistro"
(~14 MB base, ~0 CVEs). glibc is required by the prebuilt binaries (Claude Code, rtk, uv);
**Alpine (musl) is avoided** (it breaks them). Final image ≈ **194 MB**, `dev` user at uid 1000.

## Update

```bash
git -C <workspace>/.workstation pull
docker build -t workstation <workspace>/.workstation
```

## Uninstall

```bash
<workspace>/.workstation/uninstall.sh        # asks before each step
```

Removes, **one confirmation at a time**: the `task` block in `.bashrc`, the Docker image, the apt
packages it installed (`docker`/`git`/`gh` — only those, read from a manifest), your docker-group
membership (only if it added you), and the `.workstation` dir (clone + Claude credentials). **Your
task clones are kept**, and nothing else on the host was ever touched. `--yes` for non-interactive.
