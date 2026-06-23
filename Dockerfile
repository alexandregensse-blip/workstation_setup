# workstation — config (dotfiles + hooks) on top of the toolchain image (workstation-base).
# Thin and FAST to rebuild: changing dotfiles does NOT re-download the toolchain. Optional features
# (notifications, language, statusline, …) are applied at RUN time by task.sh, not baked here.
# Build the base first (install.sh does this):
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

# WhatsApp notifier hooks (referenced by claude/settings.json). They run in-container on every task but
# no-op instantly unless WhatsApp notify is enabled (WS_NOTIFY_WHATSAPP=1 + the /ws-whatsapp mount), so
# non-WhatsApp tasks are untouched. See whatsapp/ for the bridge that consumes what they drop.
COPY --chown=dev:dev claude/wa-presence.sh /home/dev/.local/bin/wa-presence
COPY --chown=dev:dev claude/wa-notify.sh   /home/dev/.local/bin/wa-notify
RUN chmod +x /home/dev/.local/bin/wa-presence /home/dev/.local/bin/wa-notify

# Register Serena (MCP), create RTK.md/@RTK.md WITHOUT touching settings.json (hooks are already
# declared there), and let in-container git push use the gh token at run time.
RUN serena setup claude-code && rtk init -g --no-patch \
 && git config --global credential.https://github.com.helper '!gh auth git-credential'

# The task's code is mounted here at run time; auth arrives via env vars / mount.
WORKDIR /work
CMD ["bash"]
