# workstation — config + opt-in plugins on top of the toolchain image (workstation-base).
# Thin and FAST to rebuild: changing plugins / language / dotfiles does NOT re-download the
# toolchain. Build the base first (install.sh does this):
#   docker build -f Dockerfile.base -t workstation-base .
# Claude runs INSIDE the container; tokens/credentials arrive at `run` (env / mount).
FROM workstation-base

# Hand-made dotfiles (Serena policy, prefs + hooks, statusline, convention)
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

# Register Serena (MCP), create RTK.md/@RTK.md WITHOUT touching settings.json (hooks are already
# declared there), and let in-container git push use the gh token at run time.
RUN serena setup claude-code && rtk init -g --no-patch \
 && git config --global credential.https://github.com.helper '!gh auth git-credential'

# Optional opt-in plugins (install.sh --plug-ins). WS_PLUGINS = space/comma-separated keys;
# each is installed conditionally so the default image (empty list) is unchanged.
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
