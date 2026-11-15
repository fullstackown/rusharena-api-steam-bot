// steam-relay: hace consultas públicas a steamcommunity.com desde la IP de este servidor, para repartir la carga
// entre varios servidores (Steam limita por IP). Solo deja pasar una lista cerrada de URLs de lectura de Steam
// (precios del mercado e inventarios públicos): no es un proxy abierto. Toda consulta exige RELAY_TOKEN.
//
// Sin dependencias: Node >= 20.12 (fetch y process.loadEnvFile nativos).
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
try {
  process.loadEnvFile(path.join(DIR, '.env'));
} catch {
  // sin .env: se usan las variables del entorno
}

const VERSION = JSON.parse(fs.readFileSync(path.join(DIR, 'package.json'), 'utf8')).version;
const PORT = Number(process.env.PORT || 4870);
const HOST = process.env.HOST || '127.0.0.1';
const TOKEN = (process.env.RELAY_TOKEN || '').trim();
const GAP_MS = Math.max(500, Number(process.env.STEAM_GAP_MS || 1500));
const PAUSE_MS = Math.max(30_000, Number(process.env.STEAM_PAUSE_MS || 120_000));
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36';
const MAX_BODY = 20 * 1024 * 1024;

if (TOKEN.length < 32) {
  console.error('[steam-relay] RELAY_TOKEN falta o es muy corto (mínimo 32 caracteres). Revisá el .env.');
  process.exit(1);
}
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest();

/** Únicas rutas de steamcommunity.com que se pueden consultar (todas de solo lectura y públicas). */
const ALLOWED = [
  /^\/market\/search\/render\/$/,
  /^\/market\/priceoverview\/$/,
  /^\/inventory\/\d{17}\/\d{1,10}\/\d{1,20}$/,
  /^\/(profiles\/\d{17}|id\/[A-Za-z0-9_-]{2,64})\/inventory\/?$/,
];

function allowedUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.hostname !== 'steamcommunity.com' || u.port || u.username || u.password) return null;
  return ALLOWED.some((re) => re.test(u.pathname)) ? u : null;
}

// ── Fila hacia Steam: de a una consulta, con pausa mínima; si Steam frena (429), no se insiste por un rato ──
let last = 0;
let pausedUntil = 0;
let chain = Promise.resolve();
let waiting = 0;
const stats = { started: new Date().toISOString(), total: 0, ok: 0, e429: 0, errors: 0, denied: 0, lastError: '', last429: null };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function turn() {
  waiting++;
  const p = chain.then(async () => {
    const wait = last + GAP_MS - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
  });
  chain = p.catch(() => {});
  return p.finally(() => waiting--);
}

async function steamFetch(u) {
  await turn();
  const r = await fetch(u, { headers: { 'User-Agent': UA, 'Accept-Language': 'es' }, redirect: 'follow', signal: AbortSignal.timeout(25_000) });
  if (new URL(r.url).hostname !== 'steamcommunity.com') throw new Error('redirección fuera de Steam');
  return r;
}

// ── Auth ──
const fails = new Map(); // ip → { n, until }
function clientIp(req) {
  return String(req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '');
}
function authorized(req) {
  const ip = clientIp(req);
  const f = fails.get(ip);
  if (f && f.until > Date.now()) return 'locked';
  const m = /^Bearer\s+(.+)$/i.exec(String(req.headers.authorization || ''));
  const sent = crypto.createHash('sha256').update(m ? m[1].trim() : '').digest();
  if (crypto.timingSafeEqual(sent, TOKEN_HASH)) {
    fails.delete(ip);
    return 'ok';
  }
  const n = (f?.n ?? 0) + 1;
  fails.set(ip, { n, until: n >= 20 ? Date.now() + 15 * 60_000 : 0 });
  return 'bad';
}

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

function statusBody() {
  let disk = null;
  try {
    const s = fs.statfsSync('/');
    disk = { total: s.blocks * s.bsize, free: s.bavail * s.bsize };
  } catch {
    // statfs no disponible
  }
  return {
    service: 'steam-relay',
    version: VERSION,
    node: process.version,
    uptimeSec: Math.round(process.uptime()),
    host: {
      hostname: os.hostname(),
      platform: `${os.type()} ${os.release()}`,
      cpus: os.cpus().length,
      loadavg: os.loadavg(),
      memTotal: os.totalmem(),
      memFree: os.freemem(),
      uptimeSec: Math.round(os.uptime()),
      disk,
    },
    steam: { gapMs: GAP_MS, pausedUntil: pausedUntil > Date.now() ? new Date(pausedUntil).toISOString() : null, queue: waiting, ...stats },
  };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://relay');
  if (req.method !== 'GET') return json(res, 405, { error: 'Solo GET' });

  if (url.pathname === '/health') return json(res, 200, { ok: true, service: 'steam-relay', version: VERSION });

  if (url.pathname === '/status' || url.pathname === '/v1/steam') {
    const a = authorized(req);
    if (a !== 'ok') {
      stats.denied++;
      return json(res, a === 'locked' ? 429 : 401, { error: a === 'locked' ? 'Demasiados intentos' : 'No autorizado' });
    }
  } else return json(res, 404, { error: 'No existe' });

  if (url.pathname === '/status') return json(res, 200, statusBody());

  const target = allowedUrl(url.searchParams.get('url') || '');
  if (!target) return json(res, 400, { error: 'URL no permitida' });
  if (Date.now() < pausedUntil) {
    res.setHeader('x-relay-paused-until', new Date(pausedUntil).toISOString());
    return json(res, 429, { error: 'Pausado: Steam limitó este servidor' });
  }
  stats.total++;
  try {
    const r = await steamFetch(target);
    const buf = Buffer.from(await r.arrayBuffer());
    if (buf.length > MAX_BODY) throw new Error('respuesta demasiado grande');
    if (r.status === 429) {
      pausedUntil = Date.now() + PAUSE_MS;
      stats.e429++;
      stats.last429 = new Date().toISOString();
      res.setHeader('x-relay-paused-until', new Date(pausedUntil).toISOString());
    } else if (r.ok) stats.ok++;
    // x-relay-steam: la respuesta (incluido el código) es de Steam, no un error del relay.
    res.writeHead(r.status, {
      'Content-Type': r.headers.get('content-type') || 'application/octet-stream',
      'Cache-Control': 'no-store',
      'x-relay-steam': '1',
      'x-relay-final-url': r.url,
    });
    res.end(buf);
  } catch (e) {
    stats.errors++;
    stats.lastError = `${new Date().toISOString()} ${e?.message || e}`;
    json(res, 502, { error: 'No se pudo consultar a Steam' });
  }
});

server.listen(PORT, HOST, () => console.log(`[steam-relay] v${VERSION} escuchando en http://${HOST}:${PORT}`));
