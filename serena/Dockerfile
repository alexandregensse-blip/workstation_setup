# Serena layer — appended by task.sh to a repo's image ONLY when 'serena' is on for that repo
# ('task settings' → serena, global or per repo). No FROM here: task.sh composes it after the repo's
# toolchain spec (or after 'FROM workstation' when the repo has none). The policy and hooks it wires in
# ship inert in the shared image at ~/.local/share/workstation/serena; task.sh merges
# ~/.claude/serena-hooks.json into the session's settings at launch when that file exists.
USER dev
RUN i=1; until uv tool install -p 3.13 serena-agent; do \
      [ "$i" -ge 5 ] && { echo "serena install failed after $i tries"; exit 1; }; \
      echo "  serena download interrupted — retry $i…"; i=$((i+1)); sleep 5; done \
 && serena init && serena setup claude-code \
 && printf '\n' >> ~/.claude/CLAUDE.md && cat ~/.local/share/workstation/serena/CLAUDE.md >> ~/.claude/CLAUDE.md \
 && cp ~/.local/share/workstation/serena/hooks.json ~/.claude/serena-hooks.json
# Pre-warm the exact pyright Serena pins (uv caches the wheel) so the Python LSP starts even with NO
# network egress in the task container. Best-effort: a download hiccup must never fail the build.
RUN uvx -p 3.13 --from pyright==1.1.403 pyright-langserver --version >/dev/null 2>&1 || true
