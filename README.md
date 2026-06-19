# workstation_setup

Portable workstation. On a fresh machine (Ubuntu), **one command** installs every tool, configures
Claude Code (**Serena** MCP + rtk), sets up Docker, and adds the `task` command for **isolated
sessions**. No machine-specific absolute paths (everything is `$HOME`-relative).

## Install — one command

```bash
curl -fsSL https://raw.githubusercontent.com/alexandregensse-blip/workstation_setup/main/install.sh | bash
```

It asks where to put your workspace (current dir / `~/dev` / custom), elevates with `sudo`, installs
**only what's missing**, clones itself into a **hidden dir** (`~/.local/share/workstation`), installs
uv/Claude/Serena/rtk, deploys your dotfiles, **builds the Docker image**, **auto-sources `task`** into
your `.bashrc`, runs GitHub + Claude auth, and prints a confirmation.

> The prompt and `sudo` read from `/dev/tty`, so the pipe form stays interactive.

### Headless / scripted

```bash
curl -fsSL .../install.sh | bash -s -- --home ~/dev --yes
```

| Flag / env | Meaning | Default |
|---|---|---|
| `--home`  / `WORKSTATION_HOME`  | workspace dir for task clones | prompt, else `~/dev` |
| `--repos` / `WORKSTATION_REPOS` | tasks base | `<home>/repos` |
| `--dir`   / `WORKSTATION_DIR`   | where the workstation lives | `~/.local/share/workstation` (hidden) |
| `--yes` / `-y` | non-interactive (skip the prompt) | — |

## Work

- **On the host**: `claude` from your workspace.
- **Isolated** (recommended):
  ```bash
  task <repo> <topic>              # default base
  task --here <repo> <topic>       # base = current directory
  task --at /path <repo> <topic>   # base = given path
  ```
  Clones on the host, branches `task/<slug>`, then runs Claude in a **disposable container** (Serena
  connected, auth reused). On exit: container destroyed, clone kept on the host.

> **Pattern C / model A**: everything Claude does stays in the container. The image uses a `dev` user
> with **uid 1000** so host-mounted files (clone, credentials) are readable. Docker **auto-falls back
> to `sudo`** until the `docker` group is active (next login) — so it works right away.

## Image

Base: **`debian:12-slim`** — glibc (required by the prebuilt binaries: Claude Code, rtk, uv) and much
smaller than a full Ubuntu image. **Alpine (musl) is avoided**: it breaks glibc prebuilt binaries.

## Update

```bash
git -C ~/.local/share/workstation pull
uv tool upgrade serena-agent
docker build -t workstation ~/.local/share/workstation
```
