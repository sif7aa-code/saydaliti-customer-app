/**
 * مقارنة: هل خطأ WebSocket موجود مع useMultiFileAuthState الأصلي،
 * أمIntroducedه طبقة التشفير؟
 *
 * node test/wa-baseline.mjs [مجلد الجلسة] [ثوانٍ]
 */
import makeWASocket, {
  DisconnectReason,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';

const dir = process.argv[2] || './data/session';
const secs = Number(process.argv[3] || 12);
const label = process.argv[4] || 'Baileys الأصلي';

const silent = {
  level: 'silent',
  child() { return silent; },
  trace() {}, fatal() {}, error() {}, warn() {}, info() {}, debug() {},
};

const errors = [];
const events = [];

console.log(`\n=== ${label} — المجلد: ${dir} ===`);

const { state, saveCreds } = await useMultiFileAuthState(dir);
console.log('registered =', state.creds.registered);
console.log('me         =', state.creds.me?.id ?? '(null)');
console.log('advSecret  =', typeof state.creds.advSecretKey, state.creds.advSecretKey?.constructor?.name);
const noise = state.creds.noiseKey?.private;
console.log('noiseKey.private =', noise?.constructor?.name, Array.isArray(noise) ? `array(${noise.length})` : typeof noise);

const sock = makeWASocket({
  auth: state,
  printQRInTerminal: false,
  browser: ['WhatsApp', 'Chrome', '120.0'],
  logger: silent,
});

sock.ev.on('creds.update', saveCreds);
sock.ev.on('connection.update', (u) => {
  if (u.connection) events.push(`conn=${u.connection}`);
  if (u.lastDisconnect?.error) errors.push(u.lastDisconnect.error.message);
  if (u.qr) events.push('qr');
});

await new Promise((r) => setTimeout(r, secs * 1000));

console.log('events  =', events.join(' ') || '(none)');
console.log('errors  =', errors.length ? errors[0].slice(0, 200) : '(none)');
try { sock.end(undefined); } catch {}
process.exit(0);
