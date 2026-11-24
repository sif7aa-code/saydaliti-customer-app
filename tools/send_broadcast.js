/**
 * إرسال «شعار» (إشعار عام) لكل المستخدمين.
 *
 *   node tools/send_broadcast.js "عنوان الشعار" "نص الشعار" [رابط]
 *
 * ما يفعله:
 *   1) يكتب صف إشعار عام (user_phone = '*') في جدول notifications
 *      ⇒ يظهر لكل حساب داخل التطبيق خلال ٣-٥ ثوانٍ مع النطق العربي.
 *   2) يرسل FCM Push لكل جهاز له توكن ⇒ يصلك والتطبيق مغلق
 *      (يتطلب وجود push_worker أو هذا السكربت نفسه).
 */

const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const path = require('path');

const KEY_FILE = path.join(__dirname, 'service-account.json');
initializeApp({ credential: cert(require(KEY_FILE)) });

const SUPA_URL = 'https://rwuldrktcghnmhvepbzg.supabase.co/rest/v1/';
const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3dWxkcmt0Y2dobm1odmVwYnpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMTEwMzYsImV4cCI6MjEwNTc4NzAzNn0.ynLvUf16ii_nm52oUCcC1Xt01arthhANPs1GA0DIX-I';
const KEYS = { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` };
// للقراءة: بلا Prefer وإلا رجّع PostgREST جسماً فارغاً
const HEADERS = { ...KEYS, 'Content-Type': 'application/json' };
// للكتابة
const WRITE_HEADERS = {
  ...KEYS,
  'Content-Type': 'application/json',
  Prefer: 'return=minimal',
};

const DEFAULT_BIG_IMAGE =
  'https://rwuldrktcghnmhvepbzg.supabase.co/storage/v1/object/public/images/branding/app_icon.png';

const supaGet = async (q) => {
  const res = await fetch(`${SUPA_URL}${q}`, { headers: KEYS });
  if (!res.ok) throw new Error(`Supabase ${res.status}: ${await res.text()}`);
  return res.json();
};

const supaPost = async (table, row) => {
  const res = await fetch(`${SUPA_URL}${table}`, {
    method: 'POST',
    headers: WRITE_HEADERS,
    body: JSON.stringify(row),
  });
  if (!res.ok) throw new Error(`POST ${table} ${res.status}: ${await res.text()}`);
};

async function main() {
  const title = (process.argv[2] || '').trim();
  const body = (process.argv[3] || '').trim();
  const link = (process.argv[4] || '').trim();
  if (!title || !body) {
    console.error(
      'الاستعمال: node tools/send_broadcast.js "عنوان" "نص" [رابط]',
    );
    process.exit(1);
  }

  // ── 1) صف إشعار لكل حساب على حدة ──
  //    سبب: التطبيق يحذف الصف فور عرضه، فصف واحد مشترك (user_phone='*')
  //    سيستهلكه أول حساب يفتح التطبيق فقط والباقي لن يراه.
  // supaGet يُعيد المصفوفة مباشرة (لا كائن { data })
  const users = await supaGet(
    'users?select=phone,name,is_active&is_active=eq.true&limit=500',
  );
  const targets = (Array.isArray(users) ? users : []).filter((u) => u.phone);
  if (!targets.length) {
    console.log('لا يوجد حسابات نشطة.');
    return;
  }

  let rows = 0;
  for (const u of targets) {
    try {
      await supaPost('notifications', {
        user_phone: u.phone,
        title,
        body,
        type: 'broadcast',
        sound: 'alert',
        is_global: false,
        is_read: false,
        link_url: link || null,
      });
      rows += 1;
    } catch (e) {
      console.log(`   ⚠️  ${u.phone}: ${e.message.split('\n')[0]}`);
    }
  }
  console.log(
    `✅ ${rows} صف إشعار (صف لكل حساب) — يظهر خلال ٣-٥ ثوانٍ ثم يُحذف`,
  );

  // ── 2) FCM Push لكل جهاز له توكن (حتى والتطبيق مغلق) ──
  const withTok = await supaGet(
    'users?select=phone,name,fcm_token,avatar_url,is_active' +
      '&is_active=eq.true&fcm_token=not.is.null&limit=500',
  );
  const pushable = Array.isArray(withTok) ? withTok : [];

  let sent = 0;
  let failed = 0;
  for (const u of pushable) {
    const image = (u.avatar_url || '').toString().trim();
    try {
      await getMessaging().send({
        token: u.fcm_token,
        notification: { title, body },
        data: Object.fromEntries(
          Object.entries({
            title,
            body,
            status: 'broadcast',
            kind: 'alert',
            sound: 'alert',
            link,
            count: '1',
            bigImage: image || DEFAULT_BIG_IMAGE,
          })
            // FCM يقبل نصوصاً فقط: نحذف null/undefined ونحوّل الباقي.
            .filter(([, v]) => v !== null && v !== undefined)
            .map(([k, v]) => [k, String(v)]),
        ),
        android: {
          priority: 'high',
          notification: {
            channelId: 'strasopa_v2_alert',
            sound: 'alert',
            clickAction: 'FLUTTER_NOTIFICATION_CLICK',
            icon: 'ic_stat_notification',
            color: '#0E9AA8',
            image: image || DEFAULT_BIG_IMAGE,
            notificationCount: 1,
          },
        },
      });
      sent += 1;
      console.log(`   📲 ${u.phone} (${u.name || 'بلا اسم'})`);
    } catch (e) {
      failed += 1;
      console.log(`   ❌ ${u.phone}: ${e.message.split('\n')[0]}`);
    }
  }

  console.log(
    `\nالإجمالي: ${rows} حساب (داخل التطبيق) · ${sent} جهاز استقبل Push` +
      ` · ${failed} فشل Push · ${rows - sent} بلا توكن.`,
  );
}

main().catch((e) => {
  console.error('خطأ:', e.message);
  process.exit(1);
});
