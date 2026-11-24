import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { hub } from './src/hub.js';
import { isValidRole, parseRoles } from './src/events.js';
import { FcmSender } from './src/fcm.js';
import { SupabaseWatcher } from './src/watcher.js';

// ---------------------------------------------------------------------
//  .env بسيط (لا dotenv — صفر اعتماديات ⇒ لا npm install على السيرفر)
// ---------------------------------------------------------------------
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envPath = process.env.ENV_FILE || path.join(__dirname, '.env');
try {
  for (const raw of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    if (process.env[k] === undefined) process.env[k] = line.slice(eq + 1).trim();
  }
} catch {
  // ملف .env اختياري؛ المتغيرات قد تأتي من systemd
}

const int = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d);
const PORT = int(process.env.PORT, 3002);
const HOST = process.env.HOST || '127.0.0.1';
const API_KEY = String(process.env.NOTIFY_API_KEY || '');

const log = (m) => console.log(`[${new Date().toISOString()}] ${m}`);

if (!API_KEY) {
  console.error(
    'NOTIFY_API_KEY غير مضبوط — لا يُشغَّل الخادم. ضعه في .env أو في systemd.',
  );
  process.exit(1);
}

// ★ مُرسِل FCM: هو ما يجعل الإشعار يصل والتطبيق **مغلق**. بدون
//   ملف مفتاح الخدمة يعمل الخادم في الوضع القديم (SSE فقط) —
//   أي أن الإشعارات ستمرّ بلا ظهور بعد إغلاق التطبيق.
const fcm = new FcmSender({ onLog: (m) => log(m) });

const watcher = new SupabaseWatcher({
  url: process.env.SUPABASE_URL || '',
  key: process.env.SUPABASE_KEY || '',
  pollMs: int(process.env.WATCH_POLL_MS, 2000),
  // ★ فاصل السكون — خُفّض لأجل سرعة وصول الطلب (٢٠٢٦-١٠-١٠).
  idleMs: int(process.env.WATCH_IDLE_MS, 5000),
  idleMaxMs: int(process.env.WATCH_IDLE_MAX_MS, 10000),
  limit: int(process.env.WATCH_LIMIT, 60),
  // ★ المسح الإلزامي للنافذة الكاملة (بوابة الجولة) — مضبوط من
  //   systemd بلا لمس الكود: `WATCH_SWEEP_MS`. Default دقيقة.
  sweepMs: int(process.env.WATCH_SWEEP_MS, 60000),
  // ★ تنظيف صفحة «التنبيهات والإشعارات»: حذف صفوف `notifications`
  //   الأقدم من هذه المدة، كل هذه المدة — على السيرفر وحده بلا
  //   اعتماد على فتح التطبيق (طلب ٢٠٢٦-١١-٠٦). Default ٥ دقائق.
  purgeMs: int(process.env.WATCH_PURGE_MS, 300000),
  fcm,
  // ★ أرقام الأدمن من الإعدادات — تُضاف لقائمة القاعدة، فيصل طلب
  //   جديد لهاتف الأدمن والتطبيق مغلق حتى قبل تنفيذ ملف الأرقام.
  adminPhones: process.env.NOTIFY_ADMIN_PHONES || '',
  onError: (m) => log(`المراقب: ${m}`),
  onLog: (m) => log(m),
});

// ---------------------------------------------------------------------
const json = (res, code, obj) => {
  const b = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(b),
  });
  res.end(b);
};

const requireKey = (req, res) => {
  const given = req.headers['x-api-key'] || '';
  const a = Buffer.from(String(given));
  const b = Buffer.from(API_KEY);
  // timingSafeEqual لا يقبل أطوالاً مختلفة
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    json(res, 401, { ok: false, error: 'invalid_api_key' });
    return false;
  }
  return true;
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (url.pathname === '/api/health') {
    return json(res, 200, {
      ok: true,
      service: 'notify',
      watcher: watcher.enabled,
      pollMs: watcher.pollMs,
      // ★ سرعة الاستطلاع الفعلية الآن (تكيّفية حسب النشاط).
      idleMs: watcher.idleMs,
      // ★ هل تعمل بوابة الجولة؟ كم جولة اكتفت بالقياس الخفيف؟
      sweepMs: watcher.sweepMs,
      activeOrders: watcher.activeOrders ?? 0,
      subscribers: hub.size,
      ...watcher.stats,
      ...fcm.stats,
    });
  }

  if (url.pathname === '/api/poke') {
    if (!requireKey(req, res)) return;
    // ★ نبضة من الجهاز الذي كتب التغيير للتو ⇒ فحص فوري وإرسال،
    //   بلا انتظار الدورة. تُقبل من أي وسيلة (POST/GET) لأن أرخص
    //   شيء أن يُنسى طلبٌ ما: الاستطلاع يبقى شبكة الأمان.
    const reason = String(url.searchParams.get('why') || 'client').slice(0, 40);
    const done = watcher.poke(reason);
    return json(res, done ? 200 : 503, {
      ok: done,
      pollMs: watcher.pollMs,
      busy: watcher.busy === true,
    });
  }

  if (url.pathname === '/api/realtime') {
    if (!requireKey(req, res)) return;

    const phone = String(url.searchParams.get('phone') || '').trim();
    const roles = parseRoles(url.searchParams.get('roles')).filter(isValidRole);
    const effRoles = roles.length ? roles : ['customer'];

    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      // ★ بدون هذا يجمع nginx الأحداث ولا تصل إلا عند إغلاق الاتصال
      'X-Accel-Buffering': 'no',
    });
    res.write('retry: 3000\n\n');
    res.write(
      `event: hello\ndata: ${JSON.stringify({
        ok: true,
        watcher: watcher.enabled,
        pollMs: watcher.pollMs,
        serverTime: Date.now(),
      })}\n\n`,
    );

    hub.add(res, { phone, roles: effRoles });
    log(`اشتراك: ${phone || '؟'} [${effRoles.join('/')}] — الإجمالي ${hub.size}`);
    res.on('close', () => log(`انقطاع — الإجمالي ${hub.size}`));
    return;
  }

  return json(res, 404, { ok: false, error: 'not_found' });
});

server.keepAliveTimeout = 65000;
server.headersTimeout = 70000;
server.requestTimeout = 0; // SSE اتصال طويل

server.listen(PORT, HOST, () => {
  log('خدمة بثّ الإشعارات — Strasopa notify');
  log(`  الاستماع     : ${HOST}:${PORT}`);
  log(`  SSE          : /api/realtime`);
  log(`  الصحة        : /api/health`);
  if (watcher.start()) {
    log('  المراقب      : يعمل (إشعارات فورية)');
  } else {
    log('  ⚠ المراقب معطّل: اضبط SUPABASE_URL و SUPABASE_KEY');
  }
  if (fcm.enabled) {
    log(`  FCM          : مفعّل — ${fcm.webProjectId} (كل المنصات، يصل والتطبيق مغلق)`);
  } else {
    log('  ⚠ FCM معطّل: لا يظهر إشعار والتطبيق مغلق. الناقص:');
    for (const m of fcm.webMissing) log(`      · ${m}`);
    log('    المصدر: Firebase Console (مشروع diqarapp) → Project settings →');
    log('    Service accounts → Generate new private key،');
    log('    ثم ضعه في notify-server/fcm-diqarapp.json');
  }
});

const shutdown = () => {
  log('إيقاف…');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('unhandledRejection', (e) => log(`unhandled: ${e?.message || e}`));
