#!/usr/bin/env bash
# Runs INSIDE the workstation image at build time (invoked from the Dockerfile).
# Installs/enables ONE opt-in plugin selected via install.sh --plug-ins.
#
#   install-plugin.sh sysdeps <key>   # as root: system packages the plugin needs (apk)
#   install-plugin.sh user   <key>    # as dev:  install + enable in ~/.claude
#
# To add a plugin: add a line to ./available AND a case below. Keep it non-fatal-friendly
# (the Dockerfile guards each call with `|| echo …`) so one plugin can't break the image.
set -e
phase="${1:?phase (sysdeps|user)}"; key="${2:?plugin key}"

case "$phase:$key" in

  # ---- peon-ping: Warcraft notification sounds — hooks + audio (mp3) -------------------
  sysdeps:peon-ping)
    apk add --no-cache ffmpeg            # ffplay plays peon-ping's .mp3 sounds
    ;;
  user:peon-ping)
    # keep OUR Serena/rtk hooks: snapshot before peon-ping touches settings.json
    cp -f "$HOME/.claude/settings.json" /tmp/ws-hooks.json
    # peon-ping's official installer: downloads only the DEFAULT packs (light, not the whole
    # 105 MB repo), registers its Claude hooks, copies sounds + config into ~/.claude/hooks/peon-ping
    curl -fsSL https://raw.githubusercontent.com/PeonPing/peon-ping/main/install.sh | bash || true
    if [ -d "$HOME/.claude/hooks/peon-ping" ]; then
      # union the hooks per event so peon-ping AND Serena/rtk coexist (dedup identical entries)
      jq -s '
        .[0] as $cur | .[1] as $ours |
        $cur + { hooks: (
          reduce ((($cur.hooks//{})|keys[]) + (($ours.hooks//{})|keys[]) | unique[]) as $k
            ({}; .[$k] = ((($cur.hooks//{})[$k] // []) + (($ours.hooks//{})[$k] // []) | unique)) ) }
      ' "$HOME/.claude/settings.json" /tmp/ws-hooks.json > /tmp/ws-merged.json \
        && mv /tmp/ws-merged.json "$HOME/.claude/settings.json"
      : > "$HOME/.claude/.audio-needed"   # tells the host (task.sh) to pass the audio socket
      echo "peon-ping installed + hooks merged"
    else
      # installer failed (e.g. non-apk distro assumptions): restore our settings, no breakage
      mv -f /tmp/ws-hooks.json "$HOME/.claude/settings.json"
      echo "peon-ping install failed — left the image unchanged" >&2; exit 1
    fi
    ;;

  # ---- unknown -------------------------------------------------------------------------
  sysdeps:*) : ;;                         # nothing to do at the system level
  user:*) echo "no installer defined for plugin '$key'" >&2; exit 1 ;;

esac
