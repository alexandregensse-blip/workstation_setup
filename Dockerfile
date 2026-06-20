# "workstation" image — Claude runs INSIDE the container.
# This is install.sh "baked": same tools, but as root at build time and WITHOUT auth
# (tokens/credentials arrive at `run`). Agent toolchain only (claude + serena + rtk);
# per-language toolchains belong in per-project devcontainers.
#
# Base: Chainguard Wolfi (wolfi-base) — a minimal, glibc-based "undistro" for containers
# (~14 MB base, ~0 CVEs, security patches in hours). glibc is REQUIRED by the prebuilt
# binaries we install (Claude Code, rtk, uv); Alpine (musl) would break them.
#
# We create a `dev` user with uid 1000 so it matches the host user → mounted files
# (clone, 0600 credentials) are readable without permission issues.
FROM cgr.dev/chainguard/wolfi-base

# 1. System tools via apk (glibc). gh ships in Wolfi's repos (no external apt repo needed).
#    bash is required by the Claude installer; jq by the status line.
#    python3 is KEPT on purpose: `uv -p 3.13` reuses it, which is SMALLER than letting uv
#    download a standalone CPython (measured: with python3 = 194 MB, without = 215 MB).
USER root
RUN apk add --no-cache bash curl git ripgrep python3 gh jq ca-certificates-bundle shadow

# 2. Non-root user with uid 1000 (matches the host → host mounts are readable)
RUN useradd -m -u 1000 -s /bin/bash dev
USER dev
ENV HOME=/home/dev
ENV PATH="/home/dev/.local/bin:${PATH}"
WORKDIR /home/dev

# 3. uv, Claude Code, Serena, rtk — same installers as install.sh (all glibc binaries)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN i=1; until curl -fsSL https://claude.ai/install.sh | bash && command -v claude >/dev/null 2>&1; do \
      [ "$i" -ge 5 ] && { echo "claude install failed after $i tries"; exit 1; }; \
      echo "  claude download interrupted — retry $i…"; i=$((i+1)); sleep 5; done
RUN i=1; until uv tool install -p 3.13 serena-agent; do \
      [ "$i" -ge 5 ] && { echo "serena install failed after $i tries"; exit 1; }; \
      echo "  serena download interrupted — retry $i…"; i=$((i+1)); sleep 5; done; serena init
RUN i=1; until curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh && command -v rtk >/dev/null 2>&1; do \
      [ "$i" -ge 5 ] && { echo "rtk install failed after $i tries"; exit 1; }; \
      echo "  rtk download interrupted — retry $i…"; i=$((i+1)); sleep 5; done

# 4. Hand-made dotfiles (Serena policy, prefs + hooks, statusline, convention)
RUN mkdir -p /home/dev/.claude /home/dev/dev
COPY --chown=dev:dev claude/CLAUDE.md     /home/dev/.claude/CLAUDE.md
COPY --chown=dev:dev claude/CLAUDE.md     /home/dev/dev/AGENTS.md
COPY --chown=dev:dev claude/settings.json /home/dev/.claude/settings.json
COPY --chown=dev:dev claude/statusline.sh /home/dev/.claude/statusline.sh
COPY --chown=dev:dev dev/CLAUDE.md        /home/dev/dev/CLAUDE.md

# Optional Claude UI language baked into the image (install.sh passes the resolved value).
ARG WS_LANG=
RUN [ -z "$WS_LANG" ] || { tmp="$(mktemp)"; jq --arg l "$WS_LANG" '.language=$l' \
      /home/dev/.claude/settings.json > "$tmp" && mv "$tmp" /home/dev/.claude/settings.json; }

# 5. Register Serena (MCP), create RTK.md/@RTK.md WITHOUT touching settings.json (hooks are
#    already declared in settings.json), and let git push via the gh token at run time.
RUN serena setup claude-code && rtk init -g --no-patch \
 && git config --global credential.https://github.com.helper '!gh auth git-credential'

# 6. Optional opt-in plugins (install.sh --plug-ins). WS_PLUGINS = space/comma-separated keys;
#    each is installed conditionally so the default image (empty list) is unchanged.
#    install-plugin.sh knows how to install + enable each key (see plugins/).
ARG WS_PLUGINS=
COPY --chown=dev:dev plugins/ /home/dev/.workstation-plugins/
USER root
RUN for k in $(printf '%s' "$WS_PLUGINS" | tr ',' ' '); do \
      bash /home/dev/.workstation-plugins/install-plugin.sh sysdeps "$k" || echo "plugin sysdeps '$k' skipped"; \
    done
USER dev
RUN for k in $(printf '%s' "$WS_PLUGINS" | tr ',' ' '); do \
      bash /home/dev/.workstation-plugins/install-plugin.sh user "$k" || echo "plugin '$k' skipped"; \
    done

# The task's code is mounted here at run time; auth arrives via env vars / mount.
WORKDIR /work
CMD ["bash"]
