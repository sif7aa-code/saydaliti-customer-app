/**
 * خدمة بثّ الشعارات (الإشعارات الخارجية) — تعمل 24/7 على السيرفر.
 *
 * لماذا هذه الخدمة؟ جرّب التطبيق يرسل الشعار، لكن هذا يفشل إن:
 *   • التطبيق مغلق (وهذا المطلوب أصلاً: الإشعار لازم يوصل والتطبيق مقفول)
 *   • الهاتف بدون نت لحظي، أو شاشته مقفلة
 * فالبثّ لازم يطلع من السيرفر مباشرة، مو من التطبيق.
 *
 * تحتاج FCM v1 (service account) + صلاحية قراءة users/توكناتهم.
 *
 * التشغيل:
 *   PUSH_SECRET=<سر> PORT=3001 node push_server.js
 *   node push_server.js --once    # اختبار بثّ واحد بدون سيرفر
 *
 * المسارات:
 *   GET  /health                  → { ok, users, tokens }
 *   POST /broadcast               → { title, body, link? }
 *   ?secret=... أو  Authorization: Bearer <secret>
 */
const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const http = require('http');
const path = require('path');
const fs = require('fs');

const KEY_FILE =
  process.env.FIREBASE_KEY_FILE || path.join(__dirname, 'service-account.json');

// قارئ .env بسيط (بدون dotenv): PM2 لا يقرأ .env تلقائياً.
(function loadDotEnv() {
  const f = path.join(__dirname, '.env');
  if (!fs.existsSync(f)) return;
  for (const line of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
    if (!m) continue;
    const key = m[1];
    let val = m[2];
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = val;
  }
})();

if (!fs.existsSync(KEY_FILE)) {
  console.error('❌ service-account.json غير موجود:', KEY_FILE);
  process.exit(1);
}
initializeApp({ credential: cert(require(KEY_FILE)) });

const SUPA_URL = process.env.SUPA_URL || 'https://rwuldrktcghnmhvepbzg.supabase.co/rest/v1/';
const ANON_KEY = process.env.SUPA_ANON_KEY || '';
const PORT = Number(process.env.PORT || 3001);
const SECRET = process.env.PUSH_SECRET || '';
const ONCE = process.argv.includes('--once');

if (!ANON_KEY) { console.error('❌ SUPA_ANON_KEY غير مضبوط'); process.exit(1); }
if (!ONCE && !SECRET) {
  console.error('❌ PUSH_SECRET غير مضبوط — لا يمكن تشغيل البثّ بلا سر');
  process.exit(1);
}

const HEADERS = {
  apikey: ANON_KEY,
  Authorization: `Bearer ${ANON_KEY}`,
  'Content-Type': 'application/json',
};

// ★ لا شعار مشترك: كل حساب بلا `avatar_url` يستلم إشعاره بلا صورة
//   كبيرة، بدل أن نضع شعار التطبيق على كل الحسابات.
const NO_BIG_IMAGE = '';

// مطابقة MainActivity.kt ← NotifyChannels.createAll
const CH = {
  new_order: 'strasopa_v2_new_order',
  accepted: 'strasopa_v2_accepted',
  delivering: 'strasopa_v2_delivering',
  rejected: 'strasopa_v2_rejected',
  replaced: 'strasopa_v2_replaced',
  delivered: 'strasopa_v2_delivered',
  alert: 'strasopa_v2_alert',
};

async function supaGet(pathAndQuery) {
  const res = await fetch(`${SUPA_URL}${pathAndQuery}`, { headers: HEADERS });
  if (!res.ok) throw new Error(`Supabase ${res.status}`);
  return res.json();
}

/** الحسابات النشطة التي لها توكن. */
async function targets() {
  const users = await supaGet(
    'users?select=phone,name,avatar_url,is_shop_owner,is_active,fcm_token' +
      '&fcm_token=not.is.null&limit=500',
  );
  return (users || []).filter(
    (u) => u.is_active !== false && u.fcm_token && String(u.phone || '').trim(),
  );
}

/** شعار الحساب: صورته، أو شعار متجره إن كان صاحب متجر، وإلا الافتراضي. */
async function imageFor(u) {
  try {
    const avatar = String(u.avatar_url || '').trim();
    if (avatar && avatar !== 'null') return avatar;
    if (u.is_shop_owner === true) {
      const shops = await supaGet(
        `shops?select=logo_image&owner_phone=eq.${encodeURIComponent(u.phone)}&limit=1`,
      );
      const logo = String((shops[0] || {}).logo_image || '').trim();
      if (logo && logo !== 'null') return logo;
    }
  } catch (_) {}
  return NO_BIG_IMAGE;
}

/**
 * إرسال واحد عبر FCM v1.
 * notification + data معاً ⇒ يعرضه النظام تلقائياً حتى والتطبيق مقفول،
 * والـ data يحمل الروابط ليقرأها التطبيق عند الفتح.
 */
async function sendOne(token, title, body, data, image) {
  const res = await getMessaging().send({
    token,
    notification: { title, body },
    data: { title, body, kind: 'alert', status: 'alert', ...data },
    android: {
      priority: 'high',
      // FCM HTTP v1 يطلب ttl بالميلي ثانية (رقم صحيح)، لا "1209600s".
      ttl: 14 * 24 * 60 * 60 * 1000,
      notification: {
        channelId: CH.alert,
        sound: 'alert',
        icon: 'ic_stat_notification',
        color: '#E7A23D',
        image: image || NO_BIG_IMAGE,
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
        notificationCount: 1,
        sticky: false,
        visibility: 'public',
      },
    },
    apns: {
      headers: { 'apns-priority': '10' },
      payload: {
        aps: {
          alert: { title, body },
          sound: 'alert.wav',
          'mutable-content': 1,
          category: 'alert',
        },
        ...data,
      },
    },
  });
  return res;
}

/**
 * البثّ: إشعار لكل حساب، + صفّ داخل التطبيق (لما يكون مفتوح) بأمان.
 * نستخدم sendEachForMulticast (حد 500 توكن/طلب) مع تقسيم.
 */
async function broadcast(title, body, link) {
  const users = await targets();
  let sent = 0;
  const failed = [];

  for (let i = 0; i < users.length; i += 500) {
    const chunk = users.slice(i, i + 500);
    const tokens = chunk.map((u) => u.fcm_token);
    const images = await Promise.all(chunk.map(imageFor));
    try {
      const r = await getMessaging().sendEachForMulticast({
        tokens,
        notification: { title, body },
        data: { title, body, kind: 'alert', status: 'alert', ...(link ? { link } : {}) },
        android: {
          priority: 'high',
          notification: {
            channelId: CH.alert,
            sound: 'alert',
            icon: 'ic_stat_notification',
            color: '#E7A23D',
            clickAction: 'FLUTTER_NOTIFICATION_CLICK',
            notificationCount: 1,
            visibility: 'public',
          },
        },
      });
      sent += r.successCount;
      r.responses.forEach((x, j) => {
        if (!x.success) failed.push({ phone: chunk[j].phone, err: x.error?.code });
      });
    } catch (e) {
      failed.push({ phone: '*', err: e.message });
    }
    void images;
  }

  // صفّ داخل التطبيق: لازم، لأن التطبيق يعرض صفّه بنفسه محلياً
  // (BackgroundMessage لا يقرأ الجدول).
  let rows = 0;
  for (const u of users) {
    try {
      const res = await fetch(`${SUPA_URL}notifications`, {
        method: 'POST',
        headers: { ...HEADERS, Prefer: 'return=minimal' },
        body: JSON.stringify({
          user_phone: u.phone,
          title,
          body,
          type: 'broadcast',
          sound: 'alert',
          link_url: link || null,
          is_global: true,
          dedupe_key: `bc:${Date.now()}`,
        }),
      });
      if (res.ok) rows++;
    } catch (_) {}
  }

  return { targets: users.length, sent, rows, failed };
}

function json(res, code, obj) {
  const b = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': b.length });
  res.end(b);
}

if (!ONCE) {
  http
    .createServer((req, res) => {
      const u = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
      const auth = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
      const given = u.searchParams.get('secret') || auth;

      if (u.pathname === '/health') {
        targets()
          .then((t) => json(res, 200, { ok: true, users: t.length, tokens: t.length }))
          .catch((e) => json(res, 500, { ok: false, error: e.message }));
        return;
      }

      if (u.pathname === '/broadcast' && req.method === 'POST') {
        if (given !== SECRET) return json(res, 403, { ok: false, error: 'forbidden' });
        let raw = '';
        req.on('data', (c) => {
          raw += c;
          if (raw.length > 1e6) req.destroy();
        });
        req.on('end', async () => {
          try {
            const b = JSON.parse(raw || '{}');
            const title = String(b.title || '').trim();
            const body = String(b.body || '').trim();
            if (!title) return json(res, 400, { ok: false, error: 'العنوان مطلوب' });
            const r = await broadcast(title, body, b.link || null);
            console.log(
              `📢 بثّ: "${title}" → ${r.sent}/${r.targets} جهاز (صفوف: ${r.rows})`,
            );
            json(res, 200, { ok: true, ...r });
          } catch (e) {
            console.error('خطأ في البثّ:', e.message);
            json(res, 500, { ok: false, error: e.message });
          }
        });
        return;
      }

      json(res, 404, { ok: false, error: 'not found' });
    })
    .listen(PORT, '127.0.0.1', () => {
      console.log(`▶ خدمة البثّ على 127.0.0.1:${PORT}  (السر ${SECRET ? 'مضبوط' : 'ناقص'})`);
    });
} else {
  // اختبار واحد بدون سيرفر
  broadcast('سنتر الشطرة', 'تجربة البثّ من السيرفر — التطبيق مغلق', null)
    .then((r) => { console.log(JSON.stringify(r, null, 2)); process.exit(0); })
    .catch((e) => { console.error('خطأ:', e.message); process.exit(1); });
}
