import 'dotenv/config';

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import express from 'express';

import { AuthKeys } from './src/auth.js';
import { CodeStore, maskPhone, normalizePhone } from './src/codes.js';
import { hub } from './src/realtime-hub.js';
import { SupabaseWatcher } from './src/supabase-watcher.js';
import { WhatsAppClient } from './src/whatsapp.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const int = (v, def) => (Number.isFinite(Number(v)) ? Number(v) : def);

const PORT = int(process.env.PORT, 3000);
const HOST = process.env.HOST || '0.0.0.0';
const DATA_DIR = path.resolve(process.env.DATA_DIR || path.join(__dirname, 'data'));
const SESSION_DIR = path.resolve(
  process.env.SESSION_DIR || path.join(DATA_DIR, 'session'),
);
const BRAND_NAME = process.env.BRAND_NAME || 'Strasopa';
const COUNTRY_CODE = String(process.env.COUNTRY_CODE || '').replace(/\D/g, '');
const CODE_TTL_MIN = int(process.env.CODE_TTL_MINUTES, 5);
const DRY_RUN = process.env.WHATSAPP_DRY_RUN === '1';

const keys = new AuthKeys({ dataDir: DATA_DIR }).init();

const store = new CodeStore(path.join(DATA_DIR, 'codes.json'), {
  ttlMs: CODE_TTL_MIN * 60 * 1000,
  cooldownMs: int(process.env.RESEND_COOLDOWN_SECONDS, 60) * 1000,
  maxPerPhonePerHour: int(process.env.MAX_CODES_PER_PHONE_PER_HOUR, 5),
  maxTotalPerHour: int(process.env.MAX_CODES_TOTAL_PER_HOUR, 60),
  maxAttempts: int(process.env.MAX_VERIFY_ATTEMPTS, 5),
  codeLength: int(process.env.CODE_LENGTH, 6),
});

const logLines = [];
const log = (message) => {
  const line = { at: Date.now(), message };
  logLines.push(line);
  if (logLines.length > 200) logLines.shift();
  console.log(`[${new Date().toISOString()}] ${message}`);
};

const wa = new WhatsAppClient({ sessionDir: SESSION_DIR, log });

const watcher = new SupabaseWatcher({
  url: process.env.SUPABASE_URL || '',
  serviceKey: process.env.SUPABASE_SERVICE_KEY || '',
  pollMs: int(process.env.WATCH_POLL_MS, 2000),
  limit: int(process.env.WATCH_LIMIT, 60),
  onError: (m) => log(`المراقب: ${m}`),
  onLog: (m) => log(m),
});

if (!DRY_RUN) {
  wa.start().catch((err) => log(`فشل تشغيل واتساب: ${err.message}`));
}

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', true);
app.use(express.json({ limit: '16kb' }));

app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, x-api-key, Authorization');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

const ipHits = new Map();
const rateLimit = (limit, windowMs) => (req, res, next) => {
  const key = `${req.path}:${req.ip}`;
  const now = Date.now();
  const hits = (ipHits.get(key) ?? []).filter((t) => t > now - windowMs);
  hits.push(now);
  ipHits.set(key, hits);
  if (hits.length > limit) {
    return res.status(429).json({ ok: false, error: 'too_many_requests' });
  }
  next();
};

const requireApiKey = (req, res, next) => {
  if (!keys.checkApiKey(req)) {
    return res.status(401).json({
      ok: false,
      error: 'invalid_api_key',
      hint: 'أرسل الترويسة x-api-key',
    });
  }
  next();
};

const ADMIN_KEY = process.env.ADMIN_KEY || '';

const requireAdmin = (req, res, next) => {
  if (!ADMIN_KEY) return next();
  if (req.get('x-admin-key') !== ADMIN_KEY) {
    return res.status(401).json({ ok: false, error: 'admin_key_required' });
  }
  next();
};

const isLoopback = (req) => {
  const ip = String(req.ip || req.socket?.remoteAddress || '');
  return (
    ip === '::1' ||
    ip === '127.0.0.1' ||
    ip.startsWith('127.') ||
    ip.startsWith('::ffff:127.')
  );
};

app.get('/api/panel-key', requireAdmin, (req, res) => {
  if (!isLoopback(req)) {
    return res.status(403).json({ ok: false, error: 'local_only' });
  }
  res.json({ ok: true, apiKey: keys.apiKey });
});

app.get('/', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});
app.use(
  express.static(path.join(__dirname, 'public'), {
    index: false,
    setHeaders: (res) => res.set('Cache-Control', 'no-store'),
  }),
);

app.get('/api/status', (req, res) => {
  res.json({
    ok: true,
    ...wa.status(),
    stats: store.stats(),
    ttlMinutes: CODE_TTL_MIN,
    dryRun: DRY_RUN,
    realtime: { enabled: watcher.enabled, subscribers: hub.size, pollMs: watcher.pollMs },
  });
});

app.get('/api/logs', requireAdmin, (req, res) => {
  res.json({ ok: true, logs: logLines.slice(-40) });
});

app.post('/api/qr/refresh', requireAdmin, rateLimit(10, 60000), async (req, res) => {
  try {
    await wa.restartFresh();
    res.json({ ok: true, state: wa.status().state });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/logout', requireAdmin, rateLimit(10, 60000), async (req, res) => {
  try {
    await wa.logout();
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/api/auth/code', requireApiKey, rateLimit(20, 60000), async (req, res) => {
  const phone = normalizePhone(req.body?.phone, COUNTRY_CODE);
  if (!phone) {
    return res.status(400).json({ ok: false, error: 'invalid_phone' });
  }

  const result = store.create(phone);
  if (!result.ok) {
    return res.status(429).json({ ok: false, error: result.reason, retryAfter: result.retryAfter });
  }

  const text = `كود التحقق الخاص بك هو (${result.code})`;

  // ★★ الردّ **فوري**، والإرسال في الخلفية.
  //
  //   كان السطر: `await wa.sendText(...)` قبل `res.json` — أي أن
  //   التطبيق ينتظر أربع جولات إلى واتساب بالترتيب:
  //     1) انتظار الاتصال  (حتى 30 ثانية)
  //     2) التحقق من وجود الرقم  (حتى 15 ثانية)
  //     3) الإرسال  (حتى 20 ثانية)
  //     4) انتظار إشعار الوصول
  //   ⇒ المستخدم يضغط «إرسال كود» وينتظر شاشة فارغة ثوانٍ طويلة،
  //   ويظنّ أن التطبيق علِق.
  //
  //   والكود **صالح لحظة توليده** (`store.create` حُفظ قبل السطر
  //   تماماً)، فلا داعي لتأخير الردّ على واتساب. نردّ الآن ونُرسل بعده.
  res.json({
    ok: true,
    phone: maskPhone(phone),
    expiresIn: Math.round((result.entry.expiresAt - Date.now()) / 1000),
    delivery: 'queued',
    queued: true,
    dryRun: DRY_RUN,
  });

  if (DRY_RUN) {
    log(`[وضع التجربة] كود ${result.code} إلى ${maskPhone(phone)}`);
    return;
  }

  // ★ الخلفية: لا نُمسك الردّ، والخطأ يُسجَّل ولا يُسقط شيئاً.
  //   الفشل يُحرّر الكود فوراً حتى لا ينتظر المستخدم مهلة التهدئة
  //   (`cooldown`) ليُعيد المحاولة برقم صحيح.
  setImmediate(() => {
    wa.sendText(phone, text)
      .then((sent) => {
        log(
          `تم إرسال كود دخول إلى ${maskPhone(phone)} (${sent.status ?? 'unknown'})`,
        );
      })
      .catch((err) => {
        log(`فشل إرسال الكود إلى ${maskPhone(phone)}: ${err.message}`);
        if (
          err.message === 'number_not_on_whatsapp' ||
          err.message === 'send_failed' ||
          err.message.endsWith('_timeout')
        ) {
          store.release(phone);
        }
      });
  });
});

app.post('/api/auth/verify', requireApiKey, rateLimit(30, 60000), (req, res) => {
  const phone = normalizePhone(req.body?.phone, COUNTRY_CODE);
  const code = String(req.body?.code ?? '').trim();
  if (!phone || !code) {
    return res.status(400).json({ ok: false, error: 'missing_fields' });
  }

  const result = store.verify(phone, code);
  if (!result.ok) {
    return res.status(400).json({ ok: false, error: result.reason, attemptsLeft: result.attemptsLeft });
  }

  const token = keys.issueToken(phone);
  log(`تسجيل دخول ناجح: ${maskPhone(phone)}`);
  res.json({ ok: true, phone, token, tokenType: 'Bearer' });
});

app.get('/api/auth/session', requireApiKey, (req, res) => {
  const data = keys.checkToken(req);
  if (!data) return res.status(401).json({ ok: false, error: 'invalid_token' });
  res.json({ ok: true, phone: data.phone, expiresAt: data.exp });
});

// ---------------------------------------------------------------------
//  بث فوري (SSE) — البديل عن استolysis كل جهاز على حدة.
//
//  ★ يستبدل الاستطلاع: كل جهاز كان يسأل Supabase كل 3 ثوانٍ.
//    الآن استطلاع واحد على السيرفر كل ثانيتين + بثّ لكل من يشترك.
//    زمن الوصول: ≤2ث كشف + ~100ملي بث، بدل 0..3ث لكل جهاز على حدة.
//
//  ★ نطلب phone وrole لأننا نحتاج توجيه الحدث (طلب زبون معيّن
//    إلى هاتفه فقط). لا نضع بيانات شخصية في الحمولة — معرّف ونوع.
// ---------------------------------------------------------------------
app.get('/api/realtime', requireApiKey, (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    // يضغط nginx buffering، وإلا جُمعت الأحداث ودُفعت دفعة واحدة.
    'X-Accel-Buffering': 'no',
  });
  res.write(`retry: 3000\n\n`);
  res.write(
    `event: hello\ndata: ${JSON.stringify({
      ok: true,
      watcher: watcher.enabled,
      pollMs: watcher.pollMs,
    })}\n\n`,
  );

  const phone = String(req.query.phone || '').trim();
  const roles = String(req.query.roles || 'customer')
    .split(',')
    .map((r) => r.trim())
    .filter((r) => ['customer', 'driver', 'admin', 'shop_owner'].includes(r));

  const client = hub.add(res, { phone, roles });
  log(`اشتراك SSE: ${maskPhone(phone) || '؟'} [${roles.join('/')}] — ${hub.size} مشترك`);
  res.on('close', () => log(`انقطع SSE — ${hub.size} مشترك`));
  void client;
});

app.get('/api/watcher', requireApiKey, (req, res) => {
  res.json({
    ok: true,
    enabled: watcher.enabled,
    ...watcher.stats,
    subscribers: hub.size,
  });
});

app.use((req, res) => res.status(404).json({ ok: false, error: 'not_found' }));

app.use((err, req, res, next) => {
  const status = err.status || err.statusCode || 500;
  if (status >= 500) console.error(err);
  res.status(status).json({
    ok: false,
    error: status >= 500 ? 'server_error' : err.type || 'bad_request',
  });
});

fs.mkdirSync(DATA_DIR, { recursive: true });

if (watcher.start()) {
  log('المراقب يعمل — الإشعارات تُبثّ فوراً بدل استطلاع كل جهاز.');
} else {
  log('⚠ المراقب معطّل: اضبط SUPABASE_URL وSUPABASE_SERVICE_KEY في .env');
  log('  بدونه تعود الشاشات إلى الاستطلاع القديم (كل 3 ثوانٍ).');
}

const server = app.listen(PORT, HOST, () => {
  console.log('');
  console.log('  WhatsApp QR Login');
  console.log('  -----------------');
  console.log(`  لوحة التحكم : http://localhost:${PORT}`);
  console.log(`  x-api-key   : ${keys.apiKey}`);
  console.log(`  البيانات    : ${DATA_DIR}`);
  if (DRY_RUN) console.log('  ⚠ وضع التجربة مفعّل: لن تُرسل رسائل، الكود يظهر في السجل.');
  console.log('');
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\n  المنفذ ${PORT} مشغول. غيّر PORT في .env أو أوقف العملية الأخرى.\n`);
  } else {
    console.error('\n  فشل تشغيل السيرفر:', err.message, '\n');
  }
  process.exit(1);
});

const shutdown = async () => {
  console.log('\nإيقاف السيرفر...');
  server.close();
  await wa.stop();
  process.exit(0);
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('unhandledRejection', (err) => console.error('unhandled:', err));
