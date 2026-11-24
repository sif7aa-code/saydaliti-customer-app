/**
 * إرسال إشعار Firebase (FCM) إلى جهاز واحد أو لكل الأجهزة.
 *
 * الاستخدام:
 *   1) من Firebase Console ← Project Settings ← Service Accounts
 *      ← "Generate new private key" ← ضع الملف باسم service-account.json
 *     ضعه بجانب هذا السكربت.
 *   2) npm install firebase-admin
 *   3) node send_fcm.js <رقم الهاتف> "عنوان الإشعار" "نص الإشعار"
 *      مثال: node send_fcm.js 07830675022 "طلب جديد" "وصل طلبك للتوصيل"
 *      node send_fcm.js ALL "تجربة" "هذا إشعار لكل الأجهزة"
 *
 * ملاحظة: الإشعار يحتوي على notification + data معاً، لذلك يظهر النظام
 * بصوت حتى لو كان التطبيق مغلقاً، ويستطيع التطبيق قراءته أثناء فتحه.
 */
// firebase-admin v13+ يستخدم وحدات فرعية (modular).
const { initializeApp, cert } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const path = require('path');
const fs = require('fs');

const KEY_FILE = path.join(__dirname, 'service-account.json');

if (!fs.existsSync(KEY_FILE)) {
  console.error('ملف service-account.json غير موجود بجوار السكربت.');
  process.exit(1);
}

initializeApp({ credential: cert(require(KEY_FILE)) });

const SUPA_URL = 'https://rwuldrktcghnmhvepbzg.supabase.co/rest/v1/';
const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3dWxkcmt0Y2dobm1odmVwYnpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMTEwMzYsImV4cCI6MjEwNTc4NzAzNn0.ynLvUf16ii_nm52oUCcC1Xt01arthhANPs1GA0DIX-I';

async function tokensFor(phone) {
  const headers = {
    apikey: ANON_KEY,
    Authorization: `Bearer ${ANON_KEY}`,
  };
  const url =
    phone === 'ALL'
      ? `${SUPA_URL}users?select=fcm_token&fcm_token=not.is.null&limit=500`
      : `${SUPA_URL}users?select=fcm_token&phone=eq.${encodeURIComponent(phone)}`;
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`Supabase ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.map((r) => r.fcm_token).filter(Boolean);
}

async function main() {
  const [phone, title, body] = process.argv.slice(2);
  if (!phone || !title || !body) {
    console.error(
      'الاستخدام: node send_fcm.js <رقم الهاتف|ALL> "العنوان" "النص"',
    );
    process.exit(1);
  }

  const tokens = await tokensFor(phone);
  if (tokens.length === 0) {
    console.error(
      'لا يوجد توكن لهذا الجهاز. افتح التطبيق مرة واحدة وسجّل الدخول ' +
        'حتى يُرسل توكن الجهاز (عمود fcm_token).',
    );
    process.exit(1);
  }
  console.log(`عدد الأجهزة المستهدفة: ${tokens.length}`);

  const res = await getMessaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data: { title, body },
    android: {
      priority: 'high',
      notification: {
        channelId: 'strasopa_notifications',
        icon: 'ic_stat_notification',
        color: '#1E51D3',
        notificationCount: 1,
        sound: 'default',
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
      },
    },
  });

  console.log(`نجح: ${res.successCount}  فشل: ${res.failureCount}`);
  for (let i = 0; i < res.responses.length; i++) {
    const r = res.responses[i];
    const short = tokens[i].slice(-14);
    if (r.success) {
      console.log(`  [OK]    device ...${short}`);
    } else {
      const code = r.error?.code || '?';
      const msg = r.error?.message || '';
      console.log(`  [FAIL]  device ...${short}  ->  ${code}: ${msg}`);
      // توكن ميت (التطبيق أُحذف أو أُعيد تثبيته): ننظّفه من قاعدة البيانات.
      if (String(code).includes('UNREGISTERED') || msg.includes('not-registered')) {
        const res2 = await fetch(
          `${SUPA_URL}users?fcm_token=eq.${encodeURIComponent(tokens[i])}`,
          {
            method: 'PATCH',
            headers: {
              ...headers,
              'Content-Type': 'application/json',
              Prefer: 'return=minimal',
            },
            body: JSON.stringify({ fcm_token: null }),
          },
        );
        console.log(
          `          -> توكن ميت، حُذف من القاعدة (${res2.status})`,
        );
      }
    }
  }
}

main().catch((e) => {
  console.error('خطأ:', e.message);
  process.exit(1);
});
