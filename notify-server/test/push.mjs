/**
 * اختبار مُرسِل FCM: إرسال إشعار حقيقي لجهاز رقم محدّد.
 *
 *   node test/push.mjs 07xxxxxxxxx
 *
 * ★ هذا هو الاختبار الذي يثبت أن الإشعار يصل **والتطبيق مغلق**
 *   (أغلق التطبيق تماماً قبل التشغيل، ثم افتحه فقط بالضغط على
 *   الإشعار). كل اختبار آخر داخل المشروع يمرّ عبر SSE، أي عبر
 *   التطبيق المفتوح — فلا يثبت شيئاً عن المغلق.
 *
 * ★ يحتاج: notify-server/fcm-service-account.json أو FCM_SERVICE_ACCOUNT_FILE.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// نفس قارئ .env في server.js (بلا dotenv ⇒ صفر اعتماديات).
try {
  for (const raw of fs.readFileSync(path.join(__dirname, '..', '.env'), 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    if (process.env[k] === undefined) process.env[k] = line.slice(eq + 1).trim();
  }
} catch {}

const { FcmSender } = await import('../src/fcm.js');

const PHONE = String(process.argv[2] || '').trim();
const SBU = process.env.SUPABASE_URL || 'https://rwuldrktcghnmhvepbzg.supabase.co';
const KEY = process.env.SUPABASE_KEY || '';

if (!PHONE) {
  console.error('الاستعمال: node test/push.mjs <رقم الهاتف>');
  process.exit(2);
}

const fcm = new FcmSender({ onLog: (m) => console.log(m) });
if (!fcm.enabled) {
  console.error('FCM معطّل — لا يوجد مفتاح خدمة صالح.');
  console.error('ضع notify-server/fcm-service-account.json ثم أعد المحاولة.');
  process.exit(3);
}

const headers = { apikey: KEY, Authorization: `Bearer ${KEY}` };
const res = await fetch(
  `${SBU}/rest/v1/push_tokens?select=token,is_active&user_phone=eq.${PHONE}&is_active=eq.true`,
  { headers },
);
if (!res.ok) {
  console.error(`تعذّرت قراءة التوكنات: ${res.status} ${(await res.text()).slice(0, 200)}`);
  process.exit(4);
}
const rows = await res.json();
if (!rows.length) {
  console.error(`لا يوجد توكن نشط للرقم ${PHONE}.`);
  console.error('افتح التطبيق مرة واحدة (يُسجَّل التوكن تلقائياً) ثم أعد المحاولة.');
  process.exit(5);
}

console.log(`أجهزة ${PHONE}: ${rows.length}`);
let ok = 0;
for (const r of rows) {
  const sent = await fcm.send(r.token, {
    title: 'اختبار إشعار',
    body: 'هذا إشعار تجريبي — أغلق التطبيق أولاً ثم استقبله.',
    data: { status: 'test', sound: 'test', serial: 'TEST-1' },
  });
  console.log(`  ${sent ? 'أُرسل ✓' : 'فشل ✗'} …${r.token.slice(-12)}`);
  if (sent) ok += 1;
}
console.log(`\nنجح ${ok}/${rows.length}.`);
process.exit(ok ? 0 : 6);