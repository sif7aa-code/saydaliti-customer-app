// =====================================================================
//  مُرسِل إشعارات سنتر الشطرة — Supabase Edge Function
//
//  لماذا هذا موجود؟
//    إشعار الجهاز المغلق لا يصل إلا من خادم عبر FCM. التطبيق وحده
//    عاجز عن ذلك. هذا الملف هو «الخادم»: يعمل داخل Supabase ٢٤/٧
//    بلا جهازك، فيستيقظ التطبيق المغلق ويصدر الصوت (عبر قناة Android).
//
//  ما يفعله في كل استدعاء:
//    1) يقرأ الطلبات التي تغيّرت حالتها (من العلامة المائية).
//    2) يبني النص: «لديك طلب جديد رقم #N» / «تم قبول طلبك #N بواسطة …»
//    3) يرسل FCM لكل جهاز: القناة + النغمة + شعار الحساب كصورة كبيرة.
//    4) يضع pushed_at على صف الإشعار ⇒ التطبيق لا يكرّره محلياً.
//    5) يتفقّد تغيير المنتجات (استبدال/سعر/حذف) بنفس الطريقة.
//
//  التشغيل التلقائي: مُشغِّل على جدول orders (فوري) + cron كل دقيقة
//  (خطّ أمان). راجع supabase_notifications_server.sql.
// =====================================================================

import { serve } from 'https://deno.land/std@0.177.1/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SECRET = Deno.env.get('PUSH_SECRET') ?? '';

// مفاتيح نفس ملف tools/push_worker.js (المشروع rwuldrktcghnmhvepbzg).
const FIREBASE_PROJECT = 'shtra-af201';
// لازم يطابق client_email داخل tools/service-account.json بالضبط، وإلا
// Google ترفض الـ JWT (iss != subject) ويفشل كل إشعار.
const CLIENT_EMAIL =
  'firebase-adminsdk-fbsvc@' + FIREBASE_PROJECT + '.iam.gserviceaccount.com';

// ── القنوات: لكل حدث نغمة (مطابقة لـ MainActivity.kt) ────────────────────
const CH = {
  new_order: 'strasopa_v2_new_order',
  driver_request: 'strasopa_v2_new_order',
  accepted: 'strasopa_v2_accepted',
  delivering: 'strasopa_v2_delivering',
  rejected: 'strasopa_v2_rejected',
  replaced: 'strasopa_v2_replaced',
  delivered: 'strasopa_v2_delivered',
  alert: 'strasopa_v2_alert',
} as const;

// ملفات res/raw الموجودة فعلياً في التطبيق.
// 'driver_request' و'item_changed' بلا ملف صوتي، فترث نغمة قناتها.
const SOUND: Record<string, string> = {
  new_order: 'new_order',
  driver_request: 'new_order',
  accepted: 'accepted',
  delivering: 'delivering',
  rejected: 'rejected',
  replaced: 'replaced',
  delivered: 'delivered',
  item_changed: 'alert',
  alert: 'alert',
};

// ★★ لا توجد صورة عامة على الإطلاق.
//   كان كل حساب بلا `avatar_url` يحصل على `app_icon.png` ⇒ صورة
//   واحدة **مشتركة** على كل الحسابات، فيُظنّ أن الشعار خاص به.
//   الآن: `logoOf` ترجع سلسلة فارغة عند غياب الشعار، فنرسل
//   الإشعار بلا صورة كبيرة ويعرض أندرويد أيقونة التطبيق فقط
//   (أيقونة التطبيق هوية التطبيق، لا شعار حساب آخر).
const NO_IMAGE = '';

const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
});

// =====================================================================
//  JWT (توقيع الطلب إلى Google) — base64url بلا حشو
// =====================================================================
function base64Url(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const b64uJson = (o: unknown) =>
  base64Url(new TextEncoder().encode(JSON.stringify(o)));

async function googleAccessToken(privateKey: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64uJson({ alg: 'RS256', typ: 'JWT' });
  const claim = b64uJson({
    iss: CLIENT_EMAIL,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  });
  const body = `${header}.${claim}`;

  const pem = privateKey.replace(/\\n/g, '\n');
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(pem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(body),
  );
  const jwt = `${body}.${base64Url(sig)}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  const json = await res.json();
  if (!json.access_token) throw new Error('token: ' + JSON.stringify(json));
  return json.access_token as string;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

let cachedToken: { t: number; v: string } | null = null;
async function accessToken(): Promise<string> {
  if (cachedToken && Date.now() - cachedToken.t < 50 * 60 * 1000) {
    return cachedToken.v;
  }
  const v = await googleAccessToken(Deno.env.get('FIREBASE_PRIVATE_KEY')!);
  cachedToken = { t: Date.now(), v };
  return v;
}

// =====================================================================
//  إرسال FCM
// =====================================================================
async function push(
  token: string,
  title: string,
  body: string,
  kind: string,
  data: Record<string, string>,
  image: string,
): Promise<boolean> {
  try {
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${await accessToken()}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          // ── بنية الرسالة: notification + data معاً ──
          //  notification ⇒ يعرضها النظام تلقائياً (بصوت قناتها وصورتها)
          //                حتى لو كان التطبيق مغلقاً/مُقتلاً.
          //  data        ⇒ ما يقرأه التطبيق عند الفتح/الضغط (orderId …
          //                link) — ضروري لأن notification لا يحمل بيانات.
          message: {
            token,
            notification: {
              title,
              body,
            },
            data: {
              title,
              body,
              kind,
              status: kind, // ⇐ يفتحه التطبيق الصحيح عند الضغط
              ...data,
            },
            android: {
              priority: 'high', // ⇐ high: النظام يوقظ الجهاز ويعرض فوراً
              // REST v1 يطلب ttl **بالميلي ثانية** (رقم صحيح).
              // إرسال "1209600s" يرفضه بـ invalid-payload.
              ttl: 14 * 24 * 60 * 60 * 1000,
              // يستبدل الإشعار السابق لنفس الطلب بدل تكدّس الإشعارات
              collapseKey: (data.orderId ? `o_${data.orderId}` : undefined),
              notification: {
                // ⚠️ REST v1 يستعمل أسماء proto: channel_id لا channelId،
                // وclick_action لا clickAction، وnotification_count لا
                // notificationCount. الاسم Kurz (camelCase) يرفضه الخادم
                // بـ "Unknown name". (firebase-admin يحوّلها تلقائياً،
                // لكن هنا نكلّم REST مباشرة.)
                channel_id: CH[kind as keyof typeof CH] ?? CH.alert,
                sound: SOUND[kind] ?? 'default',
                icon: 'ic_stat_notification',
                color: kind === 'new_order' ? '#E7A23D' : '#1E51D3',
                image: image || NO_IMAGE,
                // يجب أن يطابق <intent-filter> في AndroidManifest
                click_action: 'FLUTTER_NOTIFICATION_CLICK',
                notification_count: 1,
                sticky: false,
                visibility: 'public',
              },
            },
            // iOS: نفس المعطيات
            apns: {
              headers: { 'apns-priority': '10' },
              payload: {
                aps: {
                  alert: { title, body },
                  sound: `${SOUND[kind] ?? 'alert'}.wav`,
                  'mutable-content': 1,
                  category: kind,
                },
                ...data,
              },
            },
          },
        }),
      },
    );
    if (!res.ok) {
      const t = await res.text();
      console.warn('fcm:', res.status, t.slice(0, 200));
      return false;
    }
    return true;
  } catch (e) {
    console.warn('fcm error:', (e as Error).message);
    return false;
  }
}

// =====================================================================
//  نصوص الإشعارات
// =====================================================================
function noticeFor(status: string, order: any, who: string) {
  const serial = order.serial_number ? `#${order.serial_number}` : '';
  const free = order.is_free_driver_request === true;
  const kind =
    status === 'pending' ? (free ? 'driver_request' : 'new_order') : status;

  if (status === 'pending') {
    const t = free ? 'لديك طلب مندوب' : 'لديك طلب جديد';
    return {
      kind,
      toDrivers: t,
      driverBody: serial ? `${t} رقم ${serial}` : t,
      toCustomer: 'تم استلام طلبك',
      body: serial ? `طلبك ${serial} بانتظار مندوب` : 'طلبك بانتظار مندوب',
    };
  }
  switch (status) {
    case 'accepted':
      return {
        kind, toDrivers: '', driverBody: '',
        toCustomer: 'تم قبول طلبك',
        body: serial ? `تم قبول طلبك ${serial} بواسطة ${who}` : `تم قبول طلبك بواسطة ${who}`,
      };
    case 'delivering':
      return {
        kind, toDrivers: '', driverBody: '',
        toCustomer: 'طلبك في الطريق',
        body: serial ? `${who} في طريقه إليك — الطلب ${serial}` : `${who} في طريقه إليك`,
      };
    case 'delivered':
      return {
        kind, toDrivers: '', driverBody: '',
        toCustomer: 'تم توصيل طلبك',
        body: serial
          ? `تم توصيل الطلب ${serial} بنجاح. أكّد الاستلام للحصول على كود توصيل مجاني.`
          : 'تم التوصيل بنجاح. أكّد الاستلام للحصول على كود توصيل مجاني.',
      };
    case 'rejected':
      return {
        kind, toDrivers: '', driverBody: '',
        toCustomer: 'تم رفض طلبك',
        body: `تم رفض الطلب ${serial} — السبب: ${order.rejection_reason || 'غير محدد'}`,
      };
    case 'cancelled':
      return {
        kind, toDrivers: '', driverBody: '',
        toCustomer: 'تم إلغاء الطلب',
        body: `تم إلغاء الطلب ${serial}.`,
      };
    default:
      return null;
  }
}

function fingerprint(it: any) {
  return [it.product_name || '', it.price ?? '', it.quantity ?? '', it.total ?? ''].join('|');
}

// =====================================================================
//  الدورة
// =====================================================================
const KEY_ORDER = 'server_push_state';

async function getState(): Promise<Record<string, string>> {
  const { data } = await db.from('app_settings').select('value').eq('key', KEY_ORDER).maybeSingle();
  if (!data?.value) return {};
  try { return JSON.parse(data.value) as Record<string, string>; } catch { return {}; }
}
async function setState(s: Record<string, string>) {
  await db.from('app_settings')
    .upsert({ key: KEY_ORDER, value: JSON.stringify(s) }, { onConflict: 'key' });
}

async function cycle() {
  const state = await getState();
  const firstRun = Object.keys(state).length === 0;

  const { data: orders } = await db
    .from('orders')
    .select('id,serial_number,status,user_phone,user_name,rejection_reason,assigned_driver_phone,is_free_driver_request,updated_at,created_at')
    .order('updated_at', { ascending: false })
    .limit(120);

  const { data: items } = await db
    .from('order_items')
    .select('id,order_id,product_name,price,quantity,total')
    .limit(1000);

  if (!orders?.length) return { sent: 0, skipped: 0, firstRun };

  if (firstRun) {
    for (const o of orders) state[o.id] = `${o.status}@${o.updated_at || o.created_at}`;
    for (const it of items ?? []) state['i' + it.id] = fingerprint(it);
    await setState(state);
    return { sent: 0, skipped: 0, firstRun: true };
  }

  let sent = 0;
  let skipped = 0;

  // ── 1) تغيّر حالة الطلب ──
  for (const o of orders) {
    const stamp = `${o.status}@${o.updated_at || o.created_at}`;
    if (state[o.id] === stamp) continue;
    const prev = (state[o.id] || '').split('@')[0];
    state[o.id] = stamp;
    if (prev === o.status) continue;

    const { data: drv } = await db
      .from('users').select('name').eq('phone', o.assigned_driver_phone).maybeSingle();
    const who = (drv?.name || '').toString().trim() || 'المندوب';
    const n = noticeFor(o.status, o, who);
    if (!n) continue;

    // التطبيق قد كتب الصف مسبقاً ⇒ نُعلمه فقط بعد الإرسال.
    const base = {
      orderId: o.id,
      serial: o.serial_number ? String(o.serial_number) : '',
      // ⇐ حقل status: التطبيق يقرأه ليعرف أي شاشة يفتح بعد الضغط.
      status: n.kind,
      // ⇐ حقل link: مسار داخلي لتوجيه التطبيق (اختياري).
      link: `strasopa://order/${o.id}`,
      count: '1',
    };

    // المندوبون — إرسال متوازٍ لكل الأجهزة ⇒ نفس اللحظة للجميع.
    if (o.status === 'pending' && n.driverBody) {
      const { data: drivers } = await db
        .from('users').select('phone,avatar_url')
        .eq('is_driver', true).eq('is_active', true);
      const jobs: Promise<number>[] = [];
      for (const d of drivers ?? []) {
        if (d.phone === o.user_phone) continue;
        const toks = await tokensFor(d.phone);
        if (!toks.length) { skipped++; continue; }
        jobs.push(pushAll(toks, n.toDrivers, n.driverBody, n.kind, base, logoOf(d)));
      }
      for (const r of await Promise.all(jobs)) sent += r;
    }

    // الزبون — كل أجهزته دفعة واحدة.
    const custToks = await tokensFor(o.user_phone);
    if (custToks.length) {
      const { data: c } = await db
        .from('users').select('avatar_url').eq('phone', o.user_phone).maybeSingle();
      sent += await pushAll(
        custToks, n.toCustomer, n.body, n.kind, base, logoOf(c),
      );
    } else skipped++;

    await markPushed(o.id, n.kind);
  }

  // ── 2) تغيير بنود الطلب (استبدال / سعر / حذف) ──
  for (const it of items ?? []) {
    const fp = fingerprint(it);
    const k = 'i' + it.id;
    if (state[k] === fp) continue;
    const before = state[k];
    state[k] = fp;
    if (!before) continue; // بند جديد فقط: بلا إشعار

    const order = orders.find((o) => o.id === it.order_id);
    if (!order) continue;
    const oldName = before.split('|')[0];
    const newName = it.product_name || 'منتج';
    const serial = order.serial_number ? `#${order.serial_number}` : '';
    const title = oldName !== newName ? 'تم استبدال منتج في طلبك' : 'تم تعديل منتج في طلبك';
    const body = oldName !== newName
      ? `الطلب ${serial}: استُبدل «${oldName}» بـ «${newName}».`
      : `الطلب ${serial}: ${newName} صار ${it.total} (الكمية ${it.quantity}).`;

    const toks = await tokensFor(order.user_phone);
    if (toks.length) {
      const { data: c } = await db
        .from('users').select('avatar_url').eq('phone', order.user_phone).maybeSingle();
      sent += await pushAll(toks, title, body, 'item_changed', {
        orderId: order.id, serial: String(order.serial_number ?? ''), count: '1',
      }, logoOf(c));
    } else skipped++;

    await markPushed(order.id, 'item_changed');
  }

  // نُبقي آخر 400 مفتاح فقط حتى لا تنمو الحالة بلا حد.
  const keys = Object.keys(state);
  if (keys.length > 400) for (const k of keys.slice(0, keys.length - 400)) delete state[k];
  await setState(state);

  return { sent, skipped, firstRun: false };
}

/// ★ شعار الحساب وحده — ولا بديل مشترك.
///
/// كان يرجع `app_icon.png` لكل حساب بلا صورة، فتصير الصورة نفسها
/// على كل الحسابات (وتُقرأ كأنها شعار ذلك الحساب). الآن سلسلة
/// فارغة: الإشعار بلا صورة كبيرة، و`image || NO_IMAGE` لا يُنتج
/// `image` أصلاً فيستعمل أندرويد أيقونة التطبيق وحدها.
function logoOf(u: any) {
  const b = (u?.avatar_url || '').toString().trim();
  return b && b !== 'null' ? b : NO_IMAGE;
}

/**
 * كل توكنات FCM belonging لرقم واحد.
 *
 * ★ لماذا لم تعد `tokenFor` (توكن واحد)؟
 *   `users.fcm_token` يخزّن جهازاً واحداً فقط، فكان الحساب الذي له
 *   هاتفان لا يستقبل الإشعار على الثاني ⇒ "الإشعارات غير موحّدة بين
 *   الأجهزة". الآن نجمع:
 *     1) `users.fcm_token`   (الجهاز الذي استُعمل أخيراً)
 *     2) `push_tokens`       (كل الأجهزة التي سجّلت توكناً)
 *   بدون تكرار ⇒ كل أجهزة الحساب ترى الإشعار في اللحظة نفسها.
 */
async function tokensFor(phone: string): Promise<string[]> {
  if (!phone) return [];
  const out = new Set<string>();

  const { data: u } = await db
    .from('users').select('fcm_token').eq('phone', phone).maybeSingle();
  const a = (u?.fcm_token || '').toString().trim();
  if (a && a !== 'null') out.add(a);

  try {
    const { data: list } = await db
      .from('push_tokens').select('token').eq('user_phone', phone);
    for (const r of list ?? []) {
      const t = (r?.token || '').toString().trim();
      if (t && t !== 'null') out.add(t);
    }
  } catch {
    // جدول push_tokens قد لا يكون موجوداً — نكمل بـ fcm_token وحده.
  }

  return [...out];
}

/** يرسل نفس الإشعار لكل التوكنات **بالتوازي** ⇒ زمن واحد للجميع. */
async function pushAll(
  tokens: string[],
  title: string,
  body: string,
  kind: string,
  data: Record<string, string>,
  image: string,
): Promise<number> {
  if (!tokens.length) return 0;
  // `Promise.all` = إرسال متزامن: المندوب على شبكات مختلفة يستلم
  // الإشعار في اللحظة نفسها تقريباً (قبل: حلقة `await` متسلسلة
  // كانت تُمطّ الفارق مع عدد المندوبين).
  const results = await Promise.all(
    tokens.map((t) => push(t, title, body, kind, data, image)),
  );
  return results.filter(Boolean).length;
}

async function markPushed(orderId: string, type: string) {
  await db.from('notifications')
    .update({ pushed_at: new Date().toISOString() })
    .eq('order_id', orderId).eq('type', type).is('pushed_at', null);
}

// =====================================================================
//  بثّ عام: من.notify_broadcast يستدعي /?broadcast=1&title=<hex>&body=<hex>
//  ⇒ إشعار لكل مستخدم نشط، بلا كتابة أي صف في قاعدة البيانات.
// =====================================================================
function hexToUtf8(hex: string | null): string {
  if (!hex) return '';
  const clean = hex.replace(/[^0-9a-fA-F]/g, '');
  if (clean.length === 0 || clean.length % 2 !== 0) return '';
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(clean.substr(i * 2, 2), 16);
  }
  return new TextDecoder('utf-8').decode(bytes);
}

async function broadcast(title: string, body: string) {
  const { data: users } = await db
    .from('users')
    .select('phone,fcm_token,avatar_url')
    .eq('is_active', true);
  // ★ إرسال متوازٍ لكل الأجهزة ⇒ الجميع يستلم في اللحظة نفسها.
  const jobs: Promise<number>[] = [];
  for (const u of users ?? []) {
    // كل توكنات الحساب (users.fcm_token + push_tokens).
    const toks = await tokensFor(u.phone);
    const t = (u.fcm_token || '').toString().trim();
    if (t && t !== 'null' && !toks.includes(t)) toks.push(t);
    if (!toks.length) continue;
    jobs.push(
      pushAll(
        toks,
        title,
        body,
        'alert',
        '',
        { kind: 'alert', broadcast: '1' },
        logoOf(u),
      ),
    );
  }
  let sent = 0;
  for (const r of await Promise.all(jobs)) sent += r;
  return { sent, targets: (users ?? []).length };
}

// =====================================================================
//  نقطة الدخول
// =====================================================================
serve(async (req) => {
  const url = new URL(req.url);
  // لا نُبقي الباب مفتوحاً إذا ضاع المفتاح: بلا مفتاح = 503، والكلام
  // غلط أو ناقص = 403. (كان 'if (SECRET && ...)' يفتحAnyone بلا مفتاح.)
  if (!SECRET) {
    return new Response(
      JSON.stringify({ ok: false, error: 'PUSH_SECRET غير مضبوط' }),
      { status: 503, headers: { 'Content-Type': 'application/json' } },
    );
  }
  if (url.searchParams.get('secret') !== SECRET) {
    return new Response('forbidden', { status: 403 });
  }
  try {
    // ── بثّ عام: شعار الأدمن لكل المستخدمين (بلا تخزين) ──
    if (url.searchParams.get('broadcast') === '1') {
      const title = hexToUtf8(url.searchParams.get('title'));
      const body = hexToUtf8(url.searchParams.get('body'));
      if (!title) {
        return new Response(
          JSON.stringify({ ok: false, error: 'عنوان الشعار مطلوب' }),
          { status: 400, headers: { 'Content-Type': 'application/json' } },
        );
      }
      const r = await broadcast(title, body);
      return new Response(
        JSON.stringify({ ok: true, broadcast: true, ...r, at: new Date().toISOString() }),
        { headers: { 'Content-Type': 'application/json' } },
      );
    }

    const r = await cycle();
    return new Response(
      JSON.stringify({ ok: true, ...r, at: new Date().toISOString() }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, error: (e as Error).message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
