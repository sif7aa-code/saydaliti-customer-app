/**
 * فحص حيّ لـ /api/realtime: يتصل بالبث، ينتظر حدثاً حقيقياً،
 * ويطبع زمن الوصول بالمللي.
 *
 * node test/live-sse.mjs <x-api-key> [ms]
 */
const key = process.argv[2];
const windowMs = Number(process.argv[3] || 25000);
if (!key) {
  console.error('الاستخدام: node test/live-sse.mjs <x-api-key> [ms]');
  process.exit(1);
}

const base = 'http://127.0.0.1:3000';
const url = `${base}/api/realtime?phone=9647000000001&roles=customer,driver,admin`;

const started = Date.now();
const seen = [];
let lastIdAt = started;

const res = await fetch(url, {
  headers: { 'x-api-key': key, Accept: 'text/event-stream' },
});

console.log('HTTP', res.status, res.headers.get('content-type'));

const reader = res.body.getReader();
const dec = new TextDecoder();
let buf = '';

const stop = setTimeout(() => {
  console.log(`\n--- انتهت النافذة (${Date.now() - started} مللي) ---`);
  console.log('أحداث مستلمة:', seen.length);
  for (const e of seen) console.log('  ', e);
  process.exit(seen.some((e) => e.topic !== 'hello') ? 0 : 2);
}, windowMs);

while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  buf += dec.decode(value, { stream: true });
  let idx;
  while ((idx = buf.indexOf('\n\n')) >= 0) {
    const frame = buf.slice(0, idx);
    buf = buf.slice(idx + 2);
    const evLine = frame.split('\n').find((l) => l.startsWith('event:'));
    const dataLine = frame.split('\n').find((l) => l.startsWith('data:'));
    if (!evLine) continue;
    const topic = evLine.slice(6).trim();
    const at = Date.now();
    lastIdAt = at;
    seen.push({ topic, at, sinceStart: at - started, data: dataLine?.slice(5) });
    console.log(`+${at - started}ms  ${topic}  ${dataLine?.slice(5) ?? ''}`);
  }
}

clearTimeout(stop);
void lastIdAt;
