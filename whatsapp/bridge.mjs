// ws-whatsapp-bridge — a single self-contained process that links your personal WhatsApp account
// (WhatsApp Web multidevice, via Baileys) and relays task notifications to a dedicated group.
//
// It NEVER talks to the task containers over the network: task containers DROP small JSON files into a
// shared /outbox directory (bind-mounted from the host), and this process — running in the host-side
// singleton container `ws-whatsapp-bridge` — picks each one up and sends it. The WhatsApp session lives
// in /data (mounted from <ws>/.auth/whatsapp), so credentials never enter a task container.
//
// Modes (argv[2]):
//   login   show a QR (scan once with your phone), persist the session, then dump the group list, exit.
//   groups  (already linked) re-dump the joined groups to /data/groups.tsv, exit.
//   status  connect briefly; print "connected" + exit 0 if the session is live, else exit non-zero.
//   run     (default) connect and watch /outbox forever, reconnecting on transient drops.
//
// On a hard logout (the ~20-day re-link, or you removed the device), it writes /data/needs-relink so the
// host can re-run `login` at the next task launch. Exit codes: 0 ok, 1 transient/connect failure, 2 logged out.

import B, { useMultiFileAuthState, fetchLatestBaileysVersion, DisconnectReason, Browsers } from '@whiskeysockets/baileys'
import qrcode from 'qrcode-terminal'
import pino from 'pino'
import { readdir, readFile, writeFile, unlink, mkdir } from 'node:fs/promises'

// Baileys ships as CommonJS: under Node ESM, the default import is module.exports (an object whose
// `.default` is the makeWASocket function). Normalize so we always get the callable.
const makeWASocket = B.default || B

const AUTH = '/data/auth'
const OUTBOX = '/outbox'
const CONFIG = '/data/config.json'
const GROUPS = '/data/groups.tsv'
const RELINK = '/data/needs-relink'
const MODE = process.argv[2] || 'run'

const logger = pino({ level: 'silent' })
const log = (...a) => console.error('[wa-bridge]', ...a)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rm = (p) => unlink(p).catch(() => {})

let currentSock = null      // always points at the live socket (swapped on reconnect)
let watcherStarted = false  // the single outbox poller — references currentSock, survives reconnects
const lastSent = new Map()  // session_id -> last-send epoch ms, for a per-session cooldown (anti-flood)

async function readGroupJid() {
  if (process.env.WA_GROUP_JID) return process.env.WA_GROUP_JID
  try { return JSON.parse(await readFile(CONFIG, 'utf8')).group || null } catch { return null }
}

// Joined groups → /data/groups.tsv as "<jid>\t<subject>" lines, so the host can show a picker. Right
// after a first link the group list can lag; retry briefly until it populates.
async function dumpGroups(sock) {
  let groups = {}
  for (let i = 0; i < 12; i++) {
    try { groups = await sock.groupFetchAllParticipating() } catch {}
    if (groups && Object.keys(groups).length) break
    await sleep(1000)
  }
  const lines = Object.values(groups || {}).map(
    (g) => `${g.id}\t${String(g.subject || '').replace(/[\t\n\r]/g, ' ')}`,
  )
  await writeFile(GROUPS, lines.length ? lines.join('\n') + '\n' : '')
  log(`found ${lines.length} group(s)`)
}

function formatMessage(m) {
  const title = m && m.title ? String(m.title) : 'Task'
  const body = m && m.message ? String(m.message) : 'a besoin de toi.'
  return `🔔 *${title}*\n${body}`
}

// One poll of the outbox: send each pending notification (oldest first), honoring a per-session
// cooldown so a task that fires many prompts while you're away doesn't spam the chat. Files are
// removed once sent (or dropped if unparseable / no group configured). A send failure stops this
// tick and leaves the file for the next one (so a transient WhatsApp hiccup doesn't lose messages).
async function tick(sock) {
  let files
  try { files = (await readdir(OUTBOX)).filter((f) => f.endsWith('.json')).sort() } catch { return }
  if (!files.length) return
  const jid = await readGroupJid()
  const cooldown = Number(process.env.WA_SESSION_COOLDOWN || 120) * 1000
  for (const f of files) {
    const p = `${OUTBOX}/${f}`
    let m
    try { m = JSON.parse(await readFile(p, 'utf8')) } catch { await rm(p); continue }
    if (!jid) { await rm(p); continue } // no group chosen yet → drop, don't pile up
    const sid = m.session_id || ''
    const now = Date.now()
    if (sid && lastSent.has(sid) && now - lastSent.get(sid) < cooldown) { await rm(p); continue }
    try {
      await sock.sendMessage(jid, { text: formatMessage(m) })
      if (sid) lastSent.set(sid, now)
      await rm(p)
      log('sent for session', sid || '(none)')
    } catch (e) {
      log('send failed:', (e && e.message) || e)
      break // keep the file, retry next tick
    }
  }
}

function startWatcher() {
  if (watcherStarted) return
  watcherStarted = true
  log('watching outbox')
  setInterval(() => { if (currentSock) tick(currentSock).catch((e) => log('tick error:', (e && e.message) || e)) }, 1000)
}

async function connect() {
  await mkdir(AUTH, { recursive: true }).catch(() => {})
  const { state, saveCreds } = await useMultiFileAuthState(AUTH)
  let version
  try { ({ version } = await fetchLatestBaileysVersion()) } catch {}
  const sock = makeWASocket({
    ...(version ? { version } : {}),
    auth: state,
    logger,
    browser: Browsers.ubuntu('Claude Tasks'),
    printQRInTerminal: false,
    syncFullHistory: false,
    markOnlineOnConnect: false,
  })
  currentSock = sock
  sock.ev.on('creds.update', saveCreds)
  sock.ev.on('connection.update', async (u) => {
    const { connection, lastDisconnect, qr } = u
    if (qr && MODE === 'login') {
      console.error('\nScanne ce QR avec WhatsApp (Réglages → Appareils connectés → Lier un appareil) :\n')
      qrcode.generate(qr, { small: true })
    }
    if (connection === 'open') {
      await rm(RELINK)
      if (MODE === 'login') { log('linked ✓'); await dumpGroups(sock); await sleep(800); process.exit(0) }
      if (MODE === 'groups') { await dumpGroups(sock); await sleep(300); process.exit(0) }
      if (MODE === 'status') { console.log('connected'); process.exit(0) }
      startWatcher() // run mode
    } else if (connection === 'close') {
      const code = lastDisconnect && lastDisconnect.error && lastDisconnect.error.output && lastDisconnect.error.output.statusCode
      if (code === DisconnectReason.loggedOut) {
        await writeFile(RELINK, String(Date.now())).catch(() => {})
        log('logged out — re-link needed (run `login` again)')
        process.exit(2)
      }
      if (MODE === 'run') { log('connection closed, reconnecting…'); await sleep(2000); connect().catch((e) => { log('reconnect failed:', (e && e.message) || e); process.exit(1) }) }
      else { log('connection closed before ready'); process.exit(1) }
    }
  })
}

connect().catch((e) => { console.error('[wa-bridge] fatal:', (e && e.message) || e); process.exit(1) })
