/**
 * عامل إشعارات الطلبات — يرسل FCM Push لكل حدث في الطلب.
 *
 * الأحداث التي يراقبها:
 *   1) طلب جديد (pending)  → إشعار لكل المندوبين: «لديك طلب جديد رقم #N»
 *   2) قبول الطلب          → الزبون: «تم قبول طلبك #N بواسطة <اسم المندوب>»
 *   3) بدء التوصيل         → الزبون: «المندوب <الاسم> في طريقه إليك»
 *   4) توصيل               → الزبون: «تم التوصيل + أكّد الاستلام للحصول على كود»
 *   5) رفض/إلغاء           → الزبون: «تم رفض الطلب — السبب: <السبب>»
 *   6) تعديل/استبدال/حذف منتج → الزبون: «تم استبدال منتج في طلبك»
 *
 * كل إشعار Contains الشعار + الصوت (حتى والتطبيق مغلق).
 *
 * التشغيل:
 *   1) Firebase Console ← Project Settings ← Service Accounts
 *      ← Generate new private key ← ضعه باسم service-account.json
 *   2) npm install firebase-admin
 *   3) node push_worker.js          (يعمل للأبد كل 4 ثوانٍ)
 *      node push_worker.js --once   (دورة واحدة)
 *      node push_worker.js --reset  (نسيان الحالة = إعادة تنبيه الكل)
 */

// firebase-admin v13+ يستخدم وحدات فرعية (modular).
const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const path = require('path');
const fs = require('fs');

const KEY_FILE = path.join(__dirname, 'service-account.json');
const STATE_FILE = path.join(__dirname, '.push_state.json');
const ITEMS_STATE_FILE = path.join(__dirname, '.push_items_state.json');

if (!fs.existsSync(KEY_FILE)) {
  console.error('❌ ملف service-account.json غير موجود بجوار السكربت.');
  process.exit(1);
}
initializeApp({ credential: cert(require(KEY_FILE)) });

const SUPA_URL = 'https://rwuldrktcghnmhvepbzg.supabase.co/rest/v1/';
const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3dWxkcmt0Y2dobm1odmVwYnpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMTEwMzYsImV4cCI6MjEwNTc4NzAzNn0.ynLvUf16ii_nm52oUCcC1Xt01arthhANPs1GA0DIX-I';
const HEADERS = { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` };

const args = process.argv.slice(2);
const ONCE = args.includes('--once');
const RESET = args.includes('--reset');
// ★ ١٠٠٠ مللي = ثانية واحدة بين الدورات ⇒ أقصى تأخير للإشعار ~١ ثانية.
//   كان ٤٠٠٠ (٤ ثوانٍ) ⇒ أقصر إشعار يمكن للمستخدم هو ٤ ثوانٍ.
//   الثمن: استعلامات أكثر على Supabase. الاستعلامات كلها صغيرة ومفهرسة
//   (orders ترتيباً بالتحديث، order_items حتى ١٠٠٠ صف)، والخادم المتبقي
//   عنده رصيد سعة كبير — والفرق هنا بين ٤ ثوانٍ وثانية واحدة هو
//   ٤ أضعاف استعلام واحد، لا ٤ أضعاف الحمل.
const INTERVAL_MS = 1000;

/**
 * ★ سرعة الاستطلاع عندما لا توجد أي طلبات نشطة.
 *
 *   المشروع هدأ ⇒ لا داعي لدورة كل ثانية. نكتفي بفحص كل ٢٠ ثانية:
 *   أبطأ ٢٠×، والاستهلاك ينخفض بالمقدار نفسه. وفضلك فوري بمجرد
 *   ظهور طلب جديد (حالة `pending` تُعدّ نشطة ⇒ ترجع السرعة).
 */
const IDLE_INTERVAL_MS = 20000;

/**
 * ★ لا شعار مشترك.
 *
 * كان `DEFAULT_BIG_IMAGE` (شعار التطبيق) يُرسل لكل حساب بلا
 * `avatar_url`، فتصير صورة واحدة على كل الحسابات وتُقرأ كأنها
 * شعار ذلك الحساب. الآن: لا صورة إلا إن كان للحساب شعاره وحده.
 */
const NO_BIG_IMAGE = '';

/**
 * قنوات الأندرويد: لكل حدث نغمة خاصة (تُنشأ في MainActivity.kt
 * ← NotifyChannels، ومعرّفاتها مطابقة تماماً لهذه الثوابت).
 * إن لم تُرسل channelId/sound يختار النظام الصوت الافتراضي.
 */
const CH = {
  new_order: 'strasopa_v2_new_order',
  accepted: 'strasopa_v2_accepted',
  delivering: 'strasopa_v2_delivering',
  rejected: 'strasopa_v2_rejected',
  replaced: 'strasopa_v2_replaced',
  price_changed: 'strasopa_v2_price_changed',
  delivered: 'strasopa_v2_delivered',
  alert: 'strasopa_v2_alert',
};

/**
 * هل الفحص نجح؟ (للتشخيص فقط)
 *
 * ملاحظة مهمة: لا نتخطّى الإرسال أبداً لأن صف الإشعار موجود — هذا الصف
 * هو ما يقرأه التطبيق، أما الإشعار على جهاز **مغلق** فلا يصل إلا من هنا.
 * بعد الإرسال نضع علامة `pushed_at` على الصف، والتطبيق يتركه بعد ذلك.
 */
const APP_ROW_WINDOW_MS = 60 * 1000;

/** يضع علامة "تم الإرسال" على صف إشعار الطلب/event داخل التطبيق. */
async function markPushed(orderId, type) {
  if (!orderId || !type) return;
  try {
    await fetch(
      `${SUPA_URL}notifications?order_id=eq.${encodeURIComponent(orderId)}` +
        `&type=eq.${encodeURIComponent(type)}&pushed_at=is.null`,
      {
        method: 'PATCH',
        headers: { ...HEADERS, 'Content-Type': 'application/json' },
        body: JSON.stringify({ pushed_at: new Date().toISOString() }),
      },
    );
  } catch (_) {}
}

/** يحوّل نوع الحدث إلى (قناة، نغمة). */
function soundFor(kind) {
  switch (kind) {
    case 'pending':
    case 'new_order':
    case 'driver_request':
      return { channelId: CH.new_order, sound: 'new_order' };
    case 'accepted':
      return { channelId: CH.accepted, sound: 'accepted' };
    case 'delivering':
      // «جاري التوصيل» لها نغمة مستقلة تماماً عن «تم القبول».
      return { channelId: CH.delivering, sound: 'delivering' };
    case 'rejected':
    case 'cancelled':
      return { channelId: CH.rejected, sound: 'rejected' };
    // ★ ثلاثة أحداث مختلفة داخل الطلب، لكل واحد قناة/نغمة وصوت
    //   مميّز: الاستبدال والحذف يبدوان متشابهين بلا ذلك.
    case 'item_changed':
    case 'item_replaced':
    case 'item_deleted':
      return { channelId: CH.replaced, sound: 'replaced' };
    case 'price_changed':
      return { channelId: CH.price_changed, sound: 'price_changed' };
    case 'delivered':
      return { channelId: CH.delivered, sound: 'delivered' };
    default:
      return { channelId: CH.alert, sound: 'alert' };
  }
}

/** شعور المتاجر (نادرة التغيّر ⇒ كاش دائم). */
const _shopLogo = new Map();

/** شعار خاص بالحساب — لكل زبون شعاره لحاله.
 *
 *   1) notification_image  ← الشعار المخصّص للإشعارات (يدوية)
 *   2) avatar_url          ← صورة البروفايل
 *   3) shops.logo_image    ← لو الحساب تاجر وما رفع صورة
 *   4) شعار التطبيق الافتراضي
 *
 * ★ يقرأ من كاش المستخدمين ([userSnapshot]) لا من القاعدة مباشرة:
 *   كانت كل نداء = استعلام واحد، وهي تُستدعى لكل مندوب عند كل
 *   إشعار ⇒ عشرات الاستعلامات بلا داعٍ.
 */
async function imageFor(phone) {
  if (!phone) return NO_BIG_IMAGE;
  try {
    const u = await userSnapshot(phone);
    if (!u) return NO_BIG_IMAGE;
    const clean = (v) => {
      const s = (v || '').toString().trim();
      return s && s !== 'null' ? s : '';
    };
    // ★★ `avatar_url` فقط — ولا `notification_image`.
    //   كان `notification_image` يسبق الصورة الشخصية، فقد كان حساب
    //   واحد يحمل شعار غيره فيظهر له كأنه شعاره. صورة الحساب
    //   (شعار المتجر لأصحاب المتاجر) مصدرها الوحيد.
    const avatar = clean(u.avatar_url);
    if (avatar) return avatar;
    if (u.is_shop_owner === true) {
      // شعور المتجر نادر التغيّر ⇒ نخزّنه=kاش منفصل طويل.
      const logo = clean(_shopLogo.get(phone));
      if (logo) return logo;
      const shops = await supaGet(
        `shops?select=logo_image&owner_phone=eq.${encodeURIComponent(phone)}&limit=1`,
      );
      const l = clean(shops[0]?.logo_image);
      if (l) {
        _shopLogo.set(phone, l);
        if (_shopLogo.size > 200) _shopLogo.clear();
      }
      if (l) return l;
    }
  } catch (_) {}
  // ★ لا صورة مشتركة: كل حساب بلا شعار يُرسَل إشعاره بلا صورة
  //   كبيرة بدل أن نضع شعار التطبيق على كل الحسابات.
  return NO_BIG_IMAGE;
}

/** أقصى عدد إرسال متوازٍ واحد. */
const SEND_BATCH = 60;

/**
 * أقصى بنود طلبات نقرأها في الدورة الواحدة.
 *
 * ★ يُستخدم كحاجز أمان لإشعار «تم حذف منتج»: إن بلغنا هذا الحد
 *   فالصفحة مختصرة، ولا نعرف أي البنود اختفت لأنّها خارج الصفحة
 *   ⇒ نُجّهض إشعارات الحذف لتلك الدورة. proyecto فيه أقل من هذا
 *   العدد فالرسالة تظهر بشكل طبيعي.
 */
const ITEMS_LIMIT = 5000;

/**
 * إرسال متوازٍ *محدود* — والجميع في آنٍ واحد بقدر المتاح.
 *
 * ★ لماذا لا Promise.all على كل المندوبين دفعة واحدة؟
 *  Node يفتح اتصالاً واحداً لـ Firebase بـ HTTP agent بلا حد، فـ ١٠٠٠
 *   طلب في اللحظة نفسها = طابور داخلي + احتمال ECONNRESET. الكمية
 *   `SEND_BATCH` تُبقي الفرق بين المندوبين بضع ملي ثانية حتى مع
 *     ١٠٠٠ مندوب، بلا ما نُغرق الاتصال.
 */
async function sendAllBatched(tasks) {
  const out = [];
  for (let i = 0; i < tasks.length; i += SEND_BATCH) {
    const slice = tasks.slice(i, i + SEND_BATCH);
    // push يرجع عددxications الناجحة، نجمعها.
    const counts = await Promise.all(slice.map((t) => t()));
    for (const c of counts) out.push(c);
  }
  return out;
}

/** تسجيل الإرسال في push_log (منع التكرار + تاريخ لكل حساب). */
async function logPush(phone, order, kind, title, body, status, sentOk, err) {
  try {
    await fetch(`${SUPA_URL}push_log`, {
      method: 'POST',
      headers: { ...HEADERS, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({
        user_phone: phone,
        order_id: order?.id || null,
        serial: order?.serial_number ? String(order.serial_number) : null,
        kind,
        title,
        body,
        status: status || null,
        sent_ok: !!sentOk,
        error_text: err || null,
      }),
    });
  } catch (_) {}
}

/** نصوص الإشعار لكل حالة. */
function noticeFor(status, order, driverName) {
  const serial = order.serial_number ? `#${order.serial_number}` : '';
  const who = driverName || 'المندوب';
  const isFree = order.is_free_driver_request === true;
  switch (status) {
    case 'pending':
      return {
        toDrivers: isFree ? 'لديك طلب مندوب' : 'لديك طلب جديد',
        toCustomer: 'تم استلام طلبك',
        body: serial ? `طلبك ${serial} بانتظار مندوب` : 'طلبك بانتظار مندوب',
        driverBody: serial
          ? isFree
            ? `لديك طلب مندوب رقم ${serial}`
            : `لديك طلب جديد رقم ${serial}`
          : isFree
            ? 'لديك طلب مندوب'
            : 'لديك طلب جديد',
      };
    case 'accepted':
      return {
        toCustomer: 'تم قبول طلبك',
        body: serial
          ? `تم قبول طلبك ${serial} بواسطة ${who}`
          : `تم قبول طلبك بواسطة ${who}`,
      };
    case 'delivering':
      return {
        toCustomer: 'طلبك في الطريق',
        body: serial
          ? `${who} في طريقه إليك — الطلب ${serial}`
          : `${who} في طريقه إليك الآن`,
      };
    case 'delivered':
      return {
        toCustomer: 'تم توصيل طلبك',
        // النقاط تُمنح بتأكيد الاستلام — وعند التأكيد يُحذف إشعار الطلب.
        body: serial
          ? `تم توصيل الطلب ${serial} بنجاح. أكّد الاستلام للحصول على كود توصيل مجاني.`
          : 'تم التوصيل بنجاح. أكّد الاستلام للحصول على كود توصيل مجاني.',
      };
    case 'rejected':
      return {
        toCustomer: 'تم رفض طلبك',
        body: `تم رفض الطلب ${serial} — السبب: ${
          order.rejection_reason || 'غير محدد'
        }`,
      };
    case 'cancelled':
      return {
        toCustomer: 'تم إلغاء الطلب',
        body: `تم إلغاء الطلب ${serial}.`,
      };
    default:
      return null;
  }
}

async function supaGet(pathAndQuery) {
  const res = await fetch(`${SUPA_URL}${pathAndQuery}`, { headers: HEADERS });
  if (!res.ok) throw new Error(`Supabase ${res.status}: ${await res.text()}`);
  return res.json();
}

// =====================================================================
//  كاش المستخدمين
//
//  ★ لماذا؟ كل استعلام يُسجَّل سطراً في *Log ingestion* الخاص بـ
//    Supabase، والميزانية المجانية محدودة.-cycle كان يسأل عن
//    المندوبين مرتين، والتوكن لكل مندوب عند كل إشعار ⇒ عشرات
//    الاستعلامات في الدقيقة بلا داع.
//
//    البيانات هنا (توكن، اسم، شعار) لا تتغير إلا نادراً: عند تسجيل
//    دخول جديد أو تغيير صورة. تكفي قراءة واحدة كل ٦٠ ثانية، ونخدم
//    الباقي من الكاش.
// =====================================================================

const USERS_TTL_MS = 60 * 1000;
const _usersCache = new Map();
let _driversCache = { at: 0, rows: [] };

/** كل بيانات المندوبين النشطين (تجمع أعمدة كثيرة ⇒ استعلام واحد). */
async function driversSnapshot() {
  const now = Date.now();
  if (now - _driversCache.at < USERS_TTL_MS) return _driversCache.rows;
  const rows = await supaGet(
    'users?select=phone,name,fcm_token,is_active,is_driver,' +
      'notification_image,avatar_url,is_shop_owner' +
      '&is_driver=eq.true&is_active=eq.true&limit=500',
  );
  _driversCache = { at: now, rows: rows || [] };
  return rows || [];
}

/** يملأ الكاش ببيانات مستخدم واحد (اسم/توكن/شعار). */
async function userSnapshot(phone) {
  const p = (phone || '').toString().trim();
  if (!p) return null;
  const now = Date.now();
  const hit = _usersCache.get(p);
  if (hit && now - hit.at < USERS_TTL_MS) return hit.row;

  const rows = await supaGet(
    `users?select=phone,name,fcm_token,notification_image,avatar_url,is_shop_owner` +
      `&phone=eq.${encodeURIComponent(p)}&limit=1`,
  );
  const row = (rows && rows[0]) || null;
  _usersCache.set(p, { at: now, row });
  // نموّ محدود: نمسح الأقدم عند التجاوز.
  if (_usersCache.size > 300) {
    const oldest = [..._usersCache.entries()].sort((a, b) => a[1].at - b[1].at);
    for (const [k] of oldest.slice(0, 100)) _usersCache.delete(k);
  }
  return row;
}

async function tokenFor(phone) {
  const u = await userSnapshot(phone);
  const t = (u?.fcm_token || '').toString().trim();
  return t && t !== 'null' ? t : null;
}

/** اسم المندوب من رقم هاتفه. */
async function driverNameFor(phone) {
  const u = await userSnapshot(phone);
  const name = (u?.name || '').toString().trim();
  return name && name !== 'null' ? name : 'المندوب';
}

/**
 * أرقام كل المندوبين النشِطين.
 *
 * ★ كان استعلاماً منفصلاً كل دورة. الآن من نفس الكاش المستعمل في
 *   [driversSnapshot] ⇒ صفر استعلام إضافي.
 */
async function allDriverPhones() {
  const rows = await driversSnapshot();
  return rows
    .map((r) => (r.phone || '').toString().trim())
    .filter((p) => p && p !== 'null');
}

/**
 * إرسال إشعار: صوت القناة الخاصة بالحدث + شعار الحساب كصورة كبيرة.
 *
 * بنية الرسالة: `notification` + `data` معاً
 *  - notification ⇒ يعرضها النظام تلقائياً حتى لو التطبيق مغلق/مُقتل
 *  - data        ⇒ ما يقرأه التطبيق عند الضغط (orderId / status / link)
 *  - priority:'high' ⇒ النظام يوقظ الجهاز ويعرض الإشعار فوراً
 */
/**
 * FCM يرفض أي قيمة غير نصية داخل `data` بـ
 * "data must only contain string values" — والـ count كان عدداً ⇒
 * كل إشعار طلب كان يفشل. نحوّل كل القيم لنصوص هنا مرة واحدة.
 */
function strData(d) {
  const out = {};
  for (const [k, v] of Object.entries(d)) {
    if (v === null || v === undefined) continue;
    out[k] = typeof v === 'string' ? v : String(v);
  }
  return out;
}

async function send(tokens, title, body, data) {
  const list = [...new Set(tokens.filter(Boolean))];
  if (!list.length) return 0;
  const { channelId, sound } = soundFor(data.kind);
  const res = await getMessaging().sendEachForMulticast({
    tokens: list,
    notification: { title, body },
    // status مكرّراً خارج data ⇒ نفس القيمة داخل كائن message.data
    data: { ...strData(data), status: String(data.kind), title, body },
    android: {
      priority: 'high',
      // استبدال الإشعار السابق لنفس الطلب بدل تكدّس الإشعارات
      collapseKey: data.orderId ? `o_${data.orderId}` : undefined,
      ttl: 60 * 60 * 24 * 14 * 1000,
      notification: {
        channelId,
        // اسم ملف res/raw الذي يطابق نغمة القناة.
        sound,
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
        icon: 'ic_stat_notification',
        color: '#1E51D3',
        // صورة الشعار داخل الإشعار (شعار خاص بكل حساب).
        ...(data.bigImage ? { image: data.bigImage } : {}),
        notificationCount: Number(data.count || 1),
        sticky: false,
        visibility: 'public',
      },
    },
  });
  // sendEachForMulticast لا يرمي استثناءً عند رفض توكن — يرجع
  // success:false. بدون هذا السطر كان كل إشعار يفشل بصمت ويظهر
  // في السجل وكأنه نجح.
  res.responses.forEach((r, i) => {
    if (!r.success) {
      console.error(
        `   ⛔ فشل إرسال ${list[i].slice(-12)}: ${r.error?.code} ${String(
          r.error?.message || '',
        ).slice(0, 120)}`,
      );
    }
  });
  if (res.successCount < list.length) {
    console.warn(`   ⚠️ نجح ${res.successCount} من ${list.length}`);
  }
  return res.successCount;
}

function readJson(file) {
  if (RESET || !fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return {};
  }
}

function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
}

const loadState = () => readJson(STATE_FILE);
const saveState = (s) => writeJson(STATE_FILE, s);
const loadItemsState = () => readJson(ITEMS_STATE_FILE);
const saveItemsState = (s) => writeJson(ITEMS_STATE_FILE, s);

/** بصمة محتوى البند: الاسم والسعر والكمية والإجمالي. */
function fingerprint(it) {
  return [it.product_name || '', it.price ?? '', it.quantity ?? '', it.total ?? '']
    .join('|');
}

/**
 * بصمة البند المخزَّنة في الحالة: `order_id@بصمة`.
 *
 * ★ لماذا نضيف order_id؟ الحذف لا يظهر في القائمة (البند يختفي)،
 *   فلو لم نحفظ رقم الطلب في الحالة ما عرفنا لمن كان الطلب عند
 *   إشعار «تم حذف منتج». الحالة القديمة بلا `@` تُقرأ كـ بصمة فقط،
 *   فيتجاهلها `stripFP` ولا يُطلق إشعار حذف خاطئاً عند أول تشغيل.
 */
const stateFP = (it) => `${it.order_id || ''}@${fingerprint(it)}`;
const stripFP = (stored) => {
  const s = (stored || '').toString();
  const i = s.indexOf('@');
  return i >= 0 ? s.slice(i + 1) : '';
};
const orderIdOf = (stored) => {
  const s = (stored || '').toString();
  const i = s.indexOf('@');
  return i > 0 ? s.slice(0, i) : '';
};

let seeded = false;

async function cycle() {
  const orders = await supaGet(
    'orders?select=id,serial_number,status,user_phone,user_name,rejection_reason,' +
      'assigned_driver_phone,is_free_driver_request,updated_at,created_at' +
      '&order=updated_at.desc&limit=500',
  );
  // ★ هل المشروع فيه طلبات لم تُنجَز بعد؟ هذا يقرر سرعة الدورة التالية:
  //   نعم ⇒ ثانية واحدة (إشعار فوري)، لا ⇒ نهدأ.
  activeOrders = (orders || []).filter((o) =>
    ['pending', 'accepted', 'delivering'].includes(o.status),
  ).length;
  // بنود الطلبات: لا يوجد بها updated_at، فنقارن بصمة المحتوى بأنفسنا.
  //
  // ★ الحد كان ٨٠٠ وهو أقل من عدد بنود المشروع، فكانت الطلبات الأقدم
  //   تظهر «بلا بنود» ويُفسَّر ذلك حذفاً كاذباً. نرفعه، ونضيف الترتيب
  //   لتكون النتيجة ثابتة بين الدورات، ونستخدم نفس الرقم للتحقق:
  //   إن بلغنا الحد ⇒ الصفحة مختصرة ⇒ نُجّهض إشعارات الحذف.
  const items = await supaGet(
    'order_items?select=id,order_id,product_name,price,quantity,total' +
      `&order=id.desc&limit=${ITEMS_LIMIT}`,
  );
  const state = loadState();
  const itemsState = loadItemsState();

  // ★ ترقية الحالة القديمة (بصمة بلا order_id) إلى الصيغة الجديدة.
  //   بدون هذا التحويل يقرأ كل بند قديم على أنه «تغيّر» ⇒ دفعة
  //   إشعارات كاذبة لكل الطلبات عند أول تشغيل بعد النشر.
  //   نعيد كتابة البصمة الحالية كما هي، بلا أي إشعار.
  // ★ تهيئة حالة بنود الطلبات (بلا أي إشعار).
  //   هدفها: كل سطر يحمل `order_id@بصمة`. سطر بلا order_id لا يُربط
  //   بطلب، فلا يُعرف صاحبه ⇒ تغيير السعر/الاستبدال عليه يمرّ بصمت.
  //   سطر بلا بصمة ⇒ نأخذ الحالي كبداية.
  //   ★ البصمة نفسها لا تُلمس أبداً هنا: لو غيّرناها لقرأ كل بند
  //   على أنه "تغيّر" ⇒ دفعة إشعارات كاذبة لكل الطلبات.
  let migrated = 0;
  for (const it of items) {
    const stored = (itemsState[it.id] || '').toString();
    const fp = stripFP(stored);
    const oid = orderIdOf(stored);

    if (fp) {
      if (!oid && it.order_id) {
        itemsState[it.id] = `${it.order_id}@${fp}`;
        migrated++;
      }
    } else {
      itemsState[it.id] = stateFP(it);
      migrated++;
    }
  }
  if (migrated) {
    saveItemsState(itemsState);
    console.log(`ℹ️ تهيئة حالة بنود الطلبات (${migrated} بند).`);
  }

  if (!seeded) {
    orders.forEach((o) => {
      state[o.id] = `${o.status}@${o.updated_at || o.created_at}`;
    });
    items.forEach((it) => {
      itemsState[it.id] = stateFP(it);
    });
    saveState(state);
    saveItemsState(itemsState);
    seeded = true;
    console.log(
      `ℹ️ تم تسجيل ${orders.length} طلباً و ${items.length} بنداً سابقاً بدون إشعار (أول تشغيل).`,
    );
    return;
  }

  // 1) تغيّر حالة الطلب.
  for (const o of orders) {
    const stamp = `${o.status}@${o.updated_at || o.created_at}`;
    if (state[o.id] === stamp) continue;
    const previous = (state[o.id] || '').split('@')[0];
    state[o.id] = stamp;
    if (previous === o.status) continue;

    const driverName = await driverNameFor(o.assigned_driver_phone);
    const n = noticeFor(o.status, o, driverName);
    if (!n) continue;

    const serial = o.serial_number ? `#${o.serial_number}` : '';
    // 'pending' تصبح 'new_order' (أو 'driver_request' لطلب المندوب الحر)
    // لتتطابق مع type المخزَّن في جدول الإشعارات، فلا يتكرر العرض ولا الصوت.
    const kind =
      o.status === 'pending'
        ? o.is_free_driver_request
          ? 'driver_request'
          : 'new_order'
        : o.status;
    const data = {
      title: n.toCustomer,
      body: n.body,
      status: kind,
      kind,
      orderId: o.id,
      serial: o.serial_number ? String(o.serial_number) : '',
      // ⇐ مسار داخلي لتوجيه التطبيق عند الضغط على الإشعار
      link: `strasopa://order/${o.id}`,
      count: 1,
    };

    try {
      let pushed = 0;
      if (o.status === 'pending' && n.driverBody) {
        // ★ إرسال متوازٍ لكل المندوبين ⇒ الجميع في اللحظة نفسها.
        //   كان `for … await` متسلسل: كل مندوب ينتظر سابقه، ومع ١٠
        //   مندوبين يتأخر العاشر ~ثانية كاملة. مع ١٠٠٠ مندوب minutes.
        //   هنا نجهّز التوكنات والشعارات بالتوازي، ثم نطلق الرسائل
        //   معاً بـ Promise.all — الفارق يصير ~٠ مهما صار العدد.
        const driverPhones = await allDriverPhones();

        // التجهيز: قراءة التوكن + الشعار لكل مندوب (كلها طلبات شبكة
        //   تُنفَّذ معاً حتى لا تضيف تأخيراً).
        const targets = (
          await Promise.all(
            driverPhones.map(async (p) => ({
              phone: p,
              token: await tokenFor(p),
              bigImage: await imageFor(p),
            })),
          )
        ).filter((t) => t.token);

        // الإرسال: كل المندوبين في آنٍ واحد (على دفعات).
        const results = await sendAllBatched(
          targets.map((t) => () =>
            send(
              [t.token],
              n.toDrivers,
              n.driverBody,
              {
                ...data,
                title: n.toDrivers,
                body: n.driverBody,
                bigImage: t.bigImage,
              },
            ),
          ),
        );
        pushed += results.filter(Boolean).length;
        console.log(
          `🔔 ${n.driverBody} → ${pushed}/${targets.length} مندوب (متوازٍ)`,
        );
      }
      const t = await tokenFor(o.user_phone);
      if (t) {
        pushed += await send([t], n.toCustomer, n.body, {
          ...data,
          bigImage: await imageFor(o.user_phone),
        });
        console.log(`🔔 ${serial} ${o.status} → زبون | ${n.body}`);
      } else {
        console.log(`⚠️ ${serial} لا يوجد توكن للزبون ${o.user_phone}`);
      }
      // وصل الإشعار ⇒ نعلّم الصف، والتطبيق لا يكرره محلياً.
      if (pushed > 0) await markPushed(o.id, kind);
    } catch (e) {
      console.error('خطأ في الإرسال:', e.message);
    }
  }

  // 2) استبدال / تغيير سعر / حذف منتج داخل طلب.
  //
  //    ★ الحذف لا يظهر في هذه الحلقة لأن البند المحذوف يختفي من القائمة،
  //      فكان لا يُنشر عنه إشعار إطلاقاً. نعالج الحذف في 2ب بمقارنة
  //      بنود الحالة السابقة بالقائمة الحالية.
  for (const it of items) {
    const fp = stateFP(it);
    const stored = itemsState[it.id];
    if (stored === fp) continue;
    const before = stripFP(stored);
    itemsState[it.id] = fp;
    if (!before) continue; // بند جديد فقط: لا نُشعر

    const order = orders.find((o) => o.id === it.order_id);
    if (!order) continue;

    const serial = order.serial_number ? `#${order.serial_number}` : '';
    const oldName = before.split('|')[0];
    const newName = it.product_name || 'منتج';
    const oldPrice = before.split('|')[1];

    // ★ تمييز الحدث: تغيّر الاسم ⇒ استبدال، وإلا تغيّر السعر ⇒ تغيير سعر.
    const isReplace = oldName !== newName;
    const isPrice = !isReplace && oldPrice !== String(it.price ?? '');

    let title;
    let body;
    let kind;
    if (isReplace) {
      title = 'تم استبدال المنتج';
      body = `الطلب ${serial}: استُبدل «${oldName}» بـ «${newName}».`;
      kind = 'item_replaced';
    } else if (isPrice) {
      title = 'تم تغيير السعر';
      body = `الطلب ${serial}: سعر «${newName}» صار ${it.price}.`;
      kind = 'price_changed';
    } else {
      title = 'تم تعديل منتج في طلبك';
      body = `الطلب ${serial}: ${newName} صار ${it.total} (الكمية ${it.quantity}).`;
      kind = 'item_changed';
    }

    try {
      const t = await tokenFor(order.user_phone);
      if (!t) {
        console.log(`⚠️ ${serial} ${title} — لا يوجد توكن للزبون`);
        continue;
      }
      const c = await send([t], title, body, {
        title,
        body,
        status: 'item_changed',
        kind,
        orderId: order.id,
        serial: order.serial_number ? String(order.serial_number) : '',
        count: 1,
        bigImage: await imageFor(order.user_phone),
      });
      console.log(`🔔 ${serial} ${title} → ${c} زبون | ${body}`);
    } catch (e) {
      console.error('خطأ في الإرسال:', e.message);
    }
  }

  // 2ب) بنود كانت في الحالة السابقة واختفت من القائمة ⇒ حُذفت.
  //
  //    ★ «اختفاء من القائمة» لا يعني دائماً «حُذف». причиان آخران
  //      يولّدان نفس العلامة (وكلاهما كان يُصدر إشعار «تم حذف منتج»
  //      كاذباً لطلبات لم يُمسّ شيء فيها):
  //        أ) القائمة مقطوعة بـ limit ⇒ بنود الطلبات الأقدم اختفت.
  //        ب) الطلب نفسه ليس في قائمة الطلبات (مقصوص/قديم).
  //      لذلك نشترط: الطلب موجود في هذه الدورة، **و** عدد بنوده
  //      كما استلمناه = عدد بنوده كما في الحالة (أي لم تُقتطع).
  const liveIds = new Set(items.map((it) => it.id));
  const liveOrderIds = new Set(orders.map((o) => o.id));
  // عدد البنود لكل طلب في هذه الدورة.
  const liveItemCount = new Map();
  for (const it of items) {
    liveItemCount.set(it.order_id, (liveItemCount.get(it.order_id) || 0) + 1);
  }

  const goneByOrder = new Map();
  for (const id of Object.keys(itemsState)) {
    if (liveIds.has(id)) continue;
    const orderId = orderIdOf(itemsState[id]);
    if (!orderId) {
      delete itemsState[id];
      continue;
    }
    if (!goneByOrder.has(orderId)) goneByOrder.set(orderId, []);
    goneByOrder.get(orderId).push(id);
  }

  // ★ شرط (أ): نتأكد أن القائمة **لم تُقتطع**.
  //   المقارنة `عدد المحفوظ > عدد المستلم` كانتخرب الحالة الأهم:
  //   عند حذف بند، المستلم **ينقص** بنفس المقدار ⇒ الشرط يبقى
  //   محقّاً إلى الأبد ⇒ لا إشعار حذف أبداً.
  //   الطريقة الصحيحة: نقيس الاقتطاع من **حدّ الصفحة** فقط — إن
  //   استلمنا العدد الأقصى المطلوب، فالنتائج مختصرة ونجهل الباقي.
  if (items.length >= ITEMS_LIMIT) {
    console.log(
      `⚠️ استلمنا ${items.length} بنداً (= الحدّ ${ITEMS_LIMIT}) — ` +
        'قد تكون القائمة مقتطعة، نُجّهض إشعارات الحذف هذه الدورة.',
    );
  } else {
    for (const [orderId, goneIds] of goneByOrder) {
      // شرط (ب): الطلب لازم يكون في هذه الدورة.
      if (!liveOrderIds.has(orderId)) continue;
      const order = orders.find((o) => o.id === orderId);
      if (!order) continue;

      for (const id of goneIds) {
        delete itemsState[id]; // ننسخه ⇒ لا نعيد الإشعار في الدورة القادمة
        const serial = order.serial_number ? `#${order.serial_number}` : '';
        const title = 'تم حذف منتج';
        const body = `تم حذف منتج من طلبك ${serial}.`;
        try {
          const t = await tokenFor(order.user_phone);
          if (!t) {
            console.log(`⚠️ ${serial} ${title} — لا يوجد توكن للزبون`);
            continue;
          }
          const c = await send([t], title, body, {
            title,
            body,
            status: 'item_changed',
            kind: 'item_deleted',
            orderId: order.id,
            serial: order.serial_number ? String(order.serial_number) : '',
            count: 1,
            bigImage: await imageFor(order.user_phone),
          });
          console.log(`🔔 ${serial} ${title} → ${c} زبون`);
        } catch (e) {
          console.error('خطأ في الإرسال:', e.message);
        }
      }
    }
  }

  saveState(state);
  saveItemsState(itemsState);
}

// ★ حالة النشاط التي ترجعها cycle (لتحديد سرعة الدورة القادمة).
let activeOrders = 0;

async function main() {
  console.log(
    ONCE ? '▶ دورة واحدة...' : `▶ مراقبة كل ${INTERVAL_MS / 1000} ثانية...`,
  );
  await cycle();
  if (ONCE) return;

  // ★ استطلاع تكيّفي بدل المؤقّت الثابت.
  //   كان setInterval كل ثانية ⇒ استعلامات بلا توقف حتى بلا أي
  //   طلب في المشروع (= ٧.٧ مليون استعلام/شهر من لا شيء).
  //   الآن: سرعة كاملة حين توجد طلبات نشطة (الإشعار خلال ثانية)،
  //   ونهدأ تلقائياً كلما هدأ المشروع — فالاستهلاك ينخفض معركود.
  const loop = async () => {
    try {
      await cycle();
    } catch (e) {
      console.error('خطأ:', e.message);
    }
    const wait = activeOrders > 0 ? INTERVAL_MS : IDLE_INTERVAL_MS;
    setTimeout(loop, wait);
  };
  loop();
}

main().catch((e) => {
  console.error('خطأ:', e.message);
  process.exit(1);
});
