/**
 * «شعار» (إشعار) **خارجي** لكل جهاز: يذهب مباشرة إلى شريط إشعارات
 * النظام عبر FCM، فيُسمع والتطبيق مغلق أو مُقتل — بلا أي اعتماد على
 * تشغيل الخلفية.
 *
 *   node tools/send_external_banner.js "العنوان" "النص"
 *
 * لماذا ملف مستقل؟ لأن `send_broadcast.js` يقرأ التوكنات من
 * `users.fcm_token`، والعمود اليوم فارغ لكل الحسابات (الجدول محجوز
 * بسياسة RLS) ⇒ كان يرسل إلى صفر أجهزة. السجل الحيّ هو `push_tokens`
 * (نفس الذي تسجّله النسخة المركّبة على الهاتف)، وهو نفس المصدر الذي
 * يقرأه الخادم في فانهوت المندوبين.
 *
 * لا يكتب شيئاً: `push_tokens` تُقرأ فقط، ولا تُمسّ أي جدول.
 */

const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const path = require('path');
const fs = require('fs');

initializeApp({ credential: cert(require(path.join(__dirname, 'service-account.json'))) });

// التوكنات تُقرأ بنفس مفتاح الخادم (قراءة منطقية، لا تُطبع أبداً).
const envFile = path.join(__dirname, '..', 'notify-server', '.env');
const env = {};
for (const line of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m) env[m[1]] = m[2].trim();
}
const HEADERS = {
  apikey: env.SUPABASE_KEY,
  Authorization: `Bearer ${env.SUPABASE_KEY}`,
  'Content-Type': 'application/json',
};

// ★ معرّف القناة هذا مُنشأ فعلاً: `NotifyChannels.ALERT` في الجافا
//   (وقت إقلاع العملية، قبل أي رسالة) و`chAlert` في Dart ⇒ النظام
//   يعرض الإشعار ويصدر نغمة القناة (alert.wav). لو كان المعرّف غير
//   موجود لحذفه أندرويد بصمت.
const CHANNEL_ID = 'strasopa_v2_alert';
const BIG_IMAGE =
  'https://rwuldrktcghnmhvepbzg.supabase.co/storage/v1/object/public/images/branding/app_icon.png';

async function main() {
  const title = (process.argv[2] || '').trim();
  const body = (process.argv[3] || '').trim();
  if (!title || !body) {
    console.error('الاستعمال: node tools/send_external_banner.js "عنوان" "نص"');
    process.exit(1);
  }

  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/push_tokens` +
      '?select=user_phone,token,is_active&is_active=eq.true&limit=1000',
    { headers: HEADERS },
  );
  if (!res.ok) throw new Error(`push_tokens ${res.status}: ${await res.text()}`);
  const rows = await res.json();

  // توكن واحد لكل جهاز (قد يتكرر نفس التوكن لحسابين).
  const seen = new Set();
  const targets = [];
  for (const r of rows) {
    const t = (r.token || '').trim();
    if (!t || seen.has(t)) continue;
    seen.add(t);
    targets.push({ phone: r.user_phone, token: t });
  }
  console.log(`أجهزة نشطة مسجّلة = ${targets.length}`);

  let sent = 0;
  let failed = 0;
  for (const { phone, token } of targets) {
    try {
      await getMessaging().send({
        token,
        notification: { title, body, image: BIG_IMAGE },
        data: { title, body, status: 'alert', kind: 'alert', sound: 'alert' },
        android: {
          priority: 'high',
          // ★ بالملّي ثانية هنا (firebase-admin لا يقبل نص «600s» الذي
          //   يستعمله REST payload في الخادم).
          ttl: 600000,
          notification: {
            channelId: CHANNEL_ID,
            sound: 'default',
            clickAction: 'FLATTEN_FOREGROUND',
            icon: 'ic_stat_notification',
            image: BIG_IMAGE,
            notificationCount: 1,
          },
        },
      });
      sent += 1;
      console.log(`   📲 …${String(phone || '').slice(-4)}`);
    } catch (e) {
      failed += 1;
      console.log(`   ❌ …${String(phone || '').slice(-4)}: ${e.message.split('\n')[0]}`);
    }
  }

  console.log(`\nالإجمالي: ${sent} جهاز · ${failed} فشل.`);
}

main().catch((e) => {
  console.error('خطأ:', e.message);
  process.exit(1);
});
