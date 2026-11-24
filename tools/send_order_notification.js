/**
 * إرسال شعار حقيقي (إشعار) لطلب محدَّد إلى المندوبين — للاختبار الفوري.
 *
 *   node tools/send_order_notification.js 71
 *   node tools/send_order_notification.js 71 07830675022   (مندوب واحد)
 *
 * ما يفعله:
 *   1) يكتب صف إشعار في جدول notifications لكل مندوب (فيظهر في جرس التطبيق
 *      مع نغمة «طلب جديد» خلال ٨ ثوانٍ).
 *   2) يرسل FCMPush لكل مندوب له توكن — بصوت قناة strasopa_v2_new_order
 *      وبصورة الشعار ⇒ يصدر الصوت حتى والتطبيق مغلق.
 */

const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const path = require('path');

const KEY_FILE = path.join(__dirname, 'service-account.json');
initializeApp({ credential: cert(require(KEY_FILE)) });

const SUPA_URL = 'https://rwuldrktcghnmhvepbzg.supabase.co/rest/v1/';
const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3dWxkcmt0Y2dobm1odmVwYnpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMTEwMzYsImV4cCI6MjEwNTc4NzAzNn0.ynLvUf16ii_nm52oUCcC1Xt01arthhANPs1GA0DIX-I';
const HEADERS = {
  apikey: ANON_KEY,
  Authorization: `Bearer ${ANON_KEY}`,
  'Content-Type': 'application/json',
  Prefer: 'return=minimal',
};

const DEFAULT_BIG_IMAGE =
  'https://rwuldrktcghnmhvepbzg.supabase.co/storage/v1/object/public/images/branding/app_icon.png';

const CH = {
  new_order: 'strasopa_v2_new_order',
  accepted: 'strasopa_v2_accepted',
  rejected: 'strasopa_v2_rejected',
  replaced: 'strasopa_v2_replaced',
  delivered: 'strasopa_v2_delivered',
  alert: 'strasopa_v2_alert',
};

const supaGet = async (q) => {
  const res = await fetch(`${SUPA_URL}${q}`, { headers: HEADERS });
  if (!res.ok) throw new Error(`Supabase ${res.status}: ${await res.text()}`);
  return res.json();
};

const supaPost = async (table, row) => {
  const res = await fetch(`${SUPA_URL}${table}`, {
    method: 'POST',
    headers: HEADERS,
    body: JSON.stringify(row),
  });
  if (!res.ok) throw new Error(`POST ${table} ${res.status}: ${await res.text()}`);
};

async function brandFor(phone) {
  try {
    const u = (
      await supaGet(
        'users?select=avatar_url,is_shop_owner' +
          `&phone=eq.${encodeURIComponent(phone)}&limit=1`,
      )
    )[0];
    if (!u) return null;
        const avatar = (u.avatar_url || '').toString().trim();
    if (avatar && avatar !== 'null') return avatar;
    if (u.is_shop_owner === true) {
      const s = (
        await supaGet(
          `shops?select=logo_image&owner_phone=eq.${encodeURIComponent(phone)}&limit=1`,
        )
      )[0];
      const logo = (s?.logo_image || '').toString().trim();
      if (logo && logo !== 'null') return logo;
    }
  } catch (_) {}
  return null;
}

async function main() {
  const serial = process.argv[2];
  const onlyPhone = process.argv[3];
  if (!serial) {
    console.error('الاستعمال: node tools/send_order_notification.js <serial#> [phone]');
    process.exit(1);
  }

  const orders = await supaGet(
    `orders?select=id,serial_number,user_name,user_phone,address,is_free_driver_request` +
      `&serial_number=eq.${encodeURIComponent(serial)}&limit=1`,
  );
  if (!orders.length) {
    console.error(`لا يوجد طلب برقم #${serial}`);
    process.exit(1);
  }
  const order = orders[0];
  const who = order.user_name || 'زبون';
  const isFree = order.is_free_driver_request === true;

  // ★ نصوص موحّدة مع التطبيق والخادم (طلب المندوب بلا «جديد»).
  const title = isFree ? 'لديك طلب مندوب' : 'لديك طلب جديد';
  const body = isFree
    ? `طلب مندوب رقم #${order.serial_number} — ${who} (مهمة توصيل)`
    : `لديك طلب جديد رقم #${order.serial_number} — ${who}`;
  const type = isFree ? 'driver_request' : 'new_order';

  const drivers = (
    await supaGet(
      'users?select=phone,name,fcm_token&is_driver=eq.true&is_active=eq.true&limit=500',
    )
  )
    .filter((u) => !!u.phone)
    .filter((u) => (onlyPhone ? u.phone === onlyPhone : true))
    .filter((u) => u.phone !== order.user_phone);

  console.log(`📦 الطلب #${order.serial_number} — ${who}${isFree ? ' (طلب مندوب حر)' : ''}`);
  console.log(`👥 المندوبون: ${drivers.length}\n`);

  for (const d of drivers) {
    const image = await brandFor(d.phone);

    // 1) صف في جدول الإشعارات ⇒ يظهر في جرس التطبيق + نغمة داخله.
    // 1) صف في جدول الإشعارات ⇒ يظهر في جرس التطبيق + نطق داخله.
    const row = {
      user_phone: d.phone,
      title,
      body,
      type,
      sound: 'new_order',
      image_url: image,
      order_id: order.id,
      serial: `#${order.serial_number}`,
      is_global: false,
      is_read: false,
    };
    // إن لم يُشغَّل سكربت الإشعارات بعد (عمود serial ناقص) نتراجع
    // بالإرسال بدونه بدل أن يفشل الإشعار كله.
    try {
      try {
        await supaPost('notifications', row);
      } catch (e) {
        if (!/serial/i.test(e.message)) throw e;
        const { serial, ...lean } = row;
        await supaPost('notifications', lean);
        console.log('  ⚠️  عمود serial غير موجود — شغّل سكربت الإشعارات');
      }
      console.log(`  ✅ صف إشعار  → ${d.phone} (${d.name || 'بلا اسم'})`);
    } catch (e) {
      console.log(`  ❌ فشل الصف  → ${d.phone}: ${e.message}`);
    }

    // 2) FCM Push ⇒ صوت وشعار حتى والتطبيق مغلق.
    if (!d.fcm_token) {
      console.log(`     ⏭️  لا يوجد توكن (سيصل عند فتح التطبيق فقط)`);
      continue;
    }
    try {
      const res = await getMessaging().send({
        token: d.fcm_token,
        notification: { title, body },
        data: {
          title,
          body,
          status: type,
          kind: type,
          sound: 'new_order',
          orderId: order.id,
          serial: `#${order.serial_number}`,
          count: '1',
          bigImage: image || DEFAULT_BIG_IMAGE,
        },
        android: {
          priority: 'high',
          notification: {
            channelId: CH.new_order,
            sound: 'new_order',
            clickAction: 'FLUTTER_NOTIFICATION_CLICK',
            icon: 'ic_stat_notification',
            color: '#E7A23D',
            image: image || DEFAULT_BIG_IMAGE,
            notificationCount: 1,
          },
        },
      });
      console.log(`     📲 Push     → ${d.phone}  (${res})`);
    } catch (e) {
      console.log(`     ❌ فشل Push  → ${d.phone}: ${e.message}`);
    }
  }
  console.log('\n✅ تم. الإشعار يظهر في التطبيق خلال ٨ ثوانٍ.');
}

main().catch((e) => {
  console.error('خطأ:', e.message);
  process.exit(1);
});
