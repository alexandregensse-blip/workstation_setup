# ws-whatsapp-bridge — headless WhatsApp Web bridge (Baileys). Built as the standalone image
# 'workstation-whatsapp' (built context = this whatsapp/ dir, so it never ships the rest of the repo).
# It watches /outbox for notification JSON dropped by task containers and relays each to a configured
# WhatsApp group; the session persists in /data (mounted from <ws>/.auth/whatsapp). Runs as uid 1000 to
# match the host user, so the session files it writes back stay host-owned (no root-owned droppings).
FROM cgr.dev/chainguard/wolfi-base
USER root
# git: Baileys pulls libsignal from a GitHub URL at install time. python3 + build-base: node-gyp builds
# the native crypto addon. shadow: useradd. (Build tools stay in the image — small price for a reliable,
# self-contained build; the bridge is a background singleton, not shipped per task.)
RUN apk add --no-cache nodejs-22 npm git python3 build-base shadow ca-certificates-bundle \
 && useradd -m -u 1000 -s /bin/sh dev
WORKDIR /app
COPY package.json /app/package.json
RUN npm install --omit=dev --no-audit --no-fund && chown -R dev:dev /app
COPY --chown=dev:dev bridge.mjs /app/bridge.mjs
RUN mkdir -p /data /outbox && chown dev:dev /data /outbox
USER dev
ENV NODE_ENV=production
# argv[2] selects the mode (login / groups / status / run). Default: the long-running watcher.
ENTRYPOINT ["node", "/app/bridge.mjs"]
CMD ["run"]
