# draft — the broker (note from the future)

> **Status: NOT built. Idea parked — "we'll see later."** Today tasks talk to GitHub directly with
> a per-run `GH_TOKEN`. This file captures the design so we don't lose it.

## Why

A **host-side broker** that becomes the **only link to the remote** (GitHub). Then:

- **Tasks hold no credentials.** The broker keeps the token + signing key; tasks commit/push to a
  **local** endpoint and the broker relays to GitHub with *its* creds. Untrusted agent code in a
  task container can't exfiltrate a token/key that isn't there. This is the big win for **autodev**.
- **One control point** for policy (e.g. "autodev pushes only to `task/*`, never `main`"), audit,
  rate-limiting, and **inter-task delegation / messaging** (the "passe-plat", extensible to remote
  workers later).

For trusted single-user maintainer sessions it's more infra than needed — its value scales with
untrusted code, many parallel tasks, and remote/distributed workers.

## Three layers (target: all three)

1. **Relay / delegation** — broker process on the host + `task delegate <repo> <topic>`: a task
   posts a request (unix socket or a mounted "outbox"), the broker spawns the sibling task. No
   docker socket inside the container; the host stays in control.
2. **Git proxy** — broker serves a local git remote (smart-HTTP), **mirrors** GitHub repos, accepts
   pushes and relays them upstream with policy. Tasks lose direct remote access.
3. **Remote signing + distributed** — broker signs *for* tasks (key never enters a task) and
   federates to remote brokers/queues for distributed workers.

## Transparency — invisible to tasks, no task changes

Done at the **git plumbing** layer, not in task logic:

- `task` (host) sets the clone's `origin` to the broker, not GitHub. The task just `git push origin`.
- Baked gitconfig rewrites everything else: `git config --global url."http://broker.local/".insteadOf
  "https://github.com/"` → any `github.com` URL a task uses is silently redirected to the broker.

Tasks keep "writing" `github.com`; git redirects under the hood. **No task adaptation.**

## Latency — non-issue for a local broker

- task→broker = loopback / unix socket (sub-ms); broker→GitHub = the same hop you'd pay directly.
- The broker **caches** mirrors → `fetch` can be *faster* than GitHub.
- Only choice: **sync** push-relay (latency ≈ direct + epsilon; recommended) vs async (task returns
  immediately, eventual propagation).

## Open points / caveats (decided so far)

- **Must proxy the `gh` API too.** `insteadOf` only covers **git** (clone/fetch/push). The `gh` CLI
  hits `api.github.com` (PRs, issues, reviews) — that bypasses the broker. For full isolation the
  broker also proxies the gh API (e.g. `GH_HOST` / a `gh` config pointing at the broker, or an HTTP
  proxy). Maintainer case: just allow `api.github.com`; hardened autodev: proxy it.
- **`--network none` is the wrong isolation.** Tasks legitimately need the internet for other things
  (deps: npm/pip/apt, web research, etc.). So we can't cut the network to force traffic through the
  broker. Instead: **selective egress** — allow general internet, but route/force **only** GitHub
  (git via `insteadOf`, the API via the proxy) through the broker, and optionally **block direct
  `github.com`/`api.github.com`** at the firewall (nftables in the netns, or a filtering gateway) so
  a task can't bypass the broker while still reaching the rest of the net.
- **Signing** stays at the broker via a forward: tasks' git points `gpg.program` /
  `gpg.ssh.program` at a tiny relay that asks the broker to sign. Keys never enter a task. This is
  why we did NOT mount signing keys into task containers.

## Tech choices (TBD)

- Broker = small host daemon (language TBD). Git smart-HTTP server (a thin layer over `git
  http-backend`, or a minimal server). Message protocol for delegation (line/JSON over a unix
  socket). Policy as declarative rules. Mirror cache on disk.

## Status today

Layer 0: direct `GH_TOKEN` per task (host gh login), in-container git identity via env, commit
signing deferred to this broker. None of the above is implemented yet.
