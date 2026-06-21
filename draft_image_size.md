# draft — shrink the image (note from the future)

> **Status: PARKED — not done on purpose.** Captures the size analysis so we can slim later.
> The image works; this is an optimization, not a bug.
> **Update:** the plugin system (incl. peon-ping + its ffmpeg ~168 MB) was removed; the GNU userland
> (grep/coreutils/util-linux/procps/… ~+13 MB) was added. The peon-ping lever below is now moot.

## Measured (uncompressed, on-disk via `docker images`)

- `workstation-base` ≈ **829 MB** (was 816; +13 MB GNU userland)
- `workstation` (no plugins) ≈ base + thin config layer

Note: `docker images` shows the **uncompressed on-disk** size. The **compressed** size (registry /
`docker pull`) is ~2.5× smaller (~250–300 MB for the base) — that's the "~194 MB" figure quoted
earlier. Both are real; disk is what it occupies locally.

## Breakdown (base, from `docker history`)

| Layer | Size | Notes |
|---|---|---|
| Claude Code binary | **234 MB** | Claude itself — incompressible, non-negotiable |
| apk tools (bash/curl/git/ripgrep/python3/gh/jq/shadow) | 155 MB | |
| Serena + its standalone CPython 3.13 | 134 MB | possible redundancy with system python3 |
| uv | 62 MB | |
| rtk | 10 MB | |
| Wolfi base | ~24 MB | |

**peon-ping adds +168 MB** — that's `ffmpeg` (pulls cairo/glib/sdl2/x11 for mp3 playback), only when
the plugin is enabled.

## Levers (biggest → smallest)

1. **peon-ping's ffmpeg (+168 MB) for a sound feature.** Options: a light mp3 player (`mpg123`,
   ~2 MB) instead of ffmpeg *if* peon-ping can be told to use it; or transcode peon's mp3 → WAV at
   build (multi-stage, ffmpeg build-only) so the runtime uses `paplay` (no ffmpeg shipped); or just
   don't enable the plugin (default image has no ffmpeg).
2. **Python redundancy (~60–130 MB?).** We keep system `python3` (in the 155 MB apk layer) AND
   Serena's `uv tool install -p 3.13` pulled a standalone CPython 3.13 (in the 134 MB layer). If
   Wolfi's python3 isn't 3.13, uv downloaded a second one. Check: align versions / drop one.
   (Earlier "with python3 = 194 MB, without = 215 MB" measurement may no longer hold — re-measure.)
3. **apk trim.** Is `ripgrep` needed in-image now that Serena does semantic search? Marginal.
4. **Claude (234 MB)** — unavoidable.
5. General: combine RUN layers, clean caches (uv cache, apk cache already `--no-cache`), strip.

## When to do it

Worth it once the toolchain stabilizes, or if disk / a future registry pull becomes a pain. The
base/thin split already means you download the toolchain once and reuse it, so the on-disk size is
the main cost, not repeated downloads.
