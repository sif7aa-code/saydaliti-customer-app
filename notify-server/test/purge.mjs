/**
 * اختبار التنظيف الدوري لصفحة «التنبيهات والإشعارات» (offline بالكامل):
 * لا شبكة ولا كتابة على قاعدة حقيقية.
 *
 *   node test/purge.mjs
 *
 * يُبدَّل `fetch` بذاكرة زائفة تتصرّف مثل PostgREST، ويُثبت أن:
 *   ١) الحذف يقع على `notifications` وحدها وبشرط العمر (٥ دقائق).
 *   ٢) لا يُفتح جدول آخر بطلب DELETE إطلاقاً (orders/users/…).
 *   ٣) الإشعار الجديد لا يُحذف: يعيش نافذته كاملة.
 *   ٤) الدورة الثانية قبل موعد التنظيف لا تحذف شيئاً.
 *   ٥) العدّادات في /api/health (purgeRuns / purgedRows) تترقّى.
 */
import assert from 'node:assert/strict';
import { SupabaseWatcher } from '../src/watcher.js';

const realFetch = globalThis.fetch;
globalThis.fetch = fake;

const now = () => Date.now();
const iso = (minutesAgo) =>
  new Date(now() - minutesAgo * 60000).toISOString().slice(0, 19);

const db = {
  orders: [
    { id: 'o1', serial_number: 52, status: 'pending', user_phone: '9647000000001', is_free_driver_request: false, address: '', assigned_driver_phone: null, created_at: iso(30), updated_at: iso(30) },
  ],
  products: [
    { id: 'p1', name: 'تمر', price: 2500, old_price: null, is_active: true, shop_id: 's1', image_path: null, created_at: iso(30), updated_at: iso(30) },
  ],
  order_items: [],
  notifications: [
    { id: 'n1', user_phone: '9647000000001', type: 'rejected', title: 'تم رفض الطلب #52', created_at: iso(600) },
    { id: 'n2', user_phone: '9647000000001', type: 'new_order', title: 'لديك طلب جديد #46', created_at: iso(1) },
  ],
  shops: [],
  push_tokens: [],
};
const deleteCalls = [];
const logs = [];
const errors = [];

function res(body, headers = {}) {
  return {
    ok: true,
    status: 200,
    headers: { get: (n) => headers[String(n).toLowerCase()] ?? null },
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

async function fake(url, opts = {}) {
  const u = new URL(url);
  const head = Object.fromEntries(
    Object.entries(opts.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]),
  );
  const last = u.pathname.split('/').pop();
  if (last === 'rpc') return res([]);
  const table = last;

  // ★ DELETE: مسار التنظيف وحده — يُحصى كله، وينفّذ شرط العمر.
  if ((opts.method || 'GET') === 'DELETE') {
    deleteCalls.push({ table, qs: u.searchParams.toString(), prefer: head.prefer ?? '' });
    const cutoff = (u.searchParams.get('created_at') || '').replace('lt.', '');
    const rows = db[table] ?? [];
    const kept = rows.filter((r) => String(r.created_at).slice(0, 19) > cutoff);
    const n = rows.length - kept.length;
    if (Array.isArray(db[table])) db[table] = kept;
    return res([], { 'content-range': `*/${n}` });
  }

  const select = u.searchParams.get('select') ?? '';
  const singleCol = select !== '' && !select.includes(',') && select !== '*';
  if (singleCol && (head.prefer ?? '').includes('count')) {
    const rows = db[table] ?? [];
    const latest = rows.map((r) => String(r[select] ?? '')).sort().at(-1) ?? '';
    return res(rows.length ? [{ [select]: latest }] : [], {
      'content-range': `0-0/${rows.length}`,
    });
  }
  const rows = (db[table] ?? []).slice();
  const orderCol = (u.searchParams.get('order') ?? 'updated_at').split('.')[0];
  rows.sort((a, b) => String(b[orderCol]).localeCompare(String(a[orderCol])));
  const limit = Number(u.searchParams.get('limit') ?? '60');
  const cols = select.split(',');
  return res(rows.slice(0, limit).map((r) => Object.fromEntries(cols.map((c) => [c, r[c]]))), {
    'content-range': `0-0/${rows.length}`,
  });
}

const w = new SupabaseWatcher({
  url: 'https://fake.supabase.co',
  key: 'x'.repeat(40),
  fcm: null,
  onError: (m) => errors.push(String(m)),
  onLog: (m) => logs.push(String(m)),
});

// ── ١) أول دورة: التنظيف يعمل فوراً على الجدول الصحيح ─────────────
await w.tick();
assert.equal(deleteCalls.length, 1, 'نداء DELETE واحد في الدورة الأولى');
assert.equal(deleteCalls[0].table, 'notifications', 'الحذف على notifications وحدها');
assert.ok(deleteCalls[0].qs.startsWith('created_at=lt.'), 'الحذف مقيَّد بشرط created_at');
assert.ok((deleteCalls[0].prefer || '').includes('count'), 'العدّ عبر Prefer: count=exact');
console.log('١ الجدول والشرط       ', deleteCalls[0].qs, '✓');

// ── ٢) العمر: القديم حُذف، الجديد بقي، ولا جدول آخر مُسّ ──────────
assert.ok(!db.notifications.some((r) => r.id === 'n1'), 'الصف العمره ١٠ دقائق حُذف');
assert.ok(db.notifications.some((r) => r.id === 'n2'), 'الصف الذي عمره دقيقة بقي');
assert.equal(db.orders.length, 1, 'الطلبات لم تُمسّ');
assert.equal(db.products.length, 1, 'المنتجات لم تُمسّ');
assert.ok(deleteCalls.every((c) => c.table === 'notifications'), 'لا DELETE على أي جدول آخر');
assert.equal(errors.length, 0, `لا أخطاء: ${errors.join(' | ')}`);
console.log('٢ نطاق الحذف           ', `طلبات=${db.orders.length} إشعارات=${db.notifications.length} ✓`);

// ── ٣) العدّادات في /api/health ──────────────────────────────────
assert.equal(w.stats.purgeRuns, 1, 'purgeRuns = 1');
assert.equal(w.stats.purgedRows, 1, 'purgedRows = 1 (الصف القديم وحده)');
console.log('٣ العدّادات            ', `purgeRuns=${w.stats.purgeRuns} purgedRows=${w.stats.purgedRows} ✓`);

// ── ٤) قبل موعد التنظيف: لا حذف إضافي ولو جرت دورات ──────────────
await w.tick();
await w.tick();
assert.equal(deleteCalls.length, 1, 'قبل مرور ٥ دقائق لا يُحذف شيء');
assert.equal(db.notifications.length, 1, 'الصف الحيّ لم يُمسّ قبل موعده');
console.log('٤ قبل الموعد           ', `نداءات DELETE=${deleteCalls.length} ✓`);

// ── ٥) الموعد التالي: الجديد صار قديماً يُحذف، والأحدث يصل سليماً ──
db.notifications[0].created_at = iso(600); // n2 صار عمره ١٠ دقائق
db.notifications.push({
  id: 'n3',
  user_phone: '9647000000001',
  type: 'driver_request',
  title: 'لديك طلب مندوب #47',
  created_at: iso(0), // وصل الآن — يجب أن يصل ولا يُحذف
});
w._purgeAt = now() - 301000; // حان موعد التنظيف
await w.tick();
assert.equal(deleteCalls.length, 2, 'نداء DELETE ثانٍ عند الموعد');
assert.ok(!db.notifications.some((r) => r.id === 'n2'), 'الصف الذي تجاوز عمره النافذة حُذف');
assert.ok(db.notifications.some((r) => r.id === 'n3'), 'الإشعار الواصل الآن بقي سليماً');
assert.equal(w.stats.purgeRuns, 2, 'purgeRuns = 2');
assert.equal(w.stats.purgedRows, 2, 'purgedRows = 2');
assert.equal(db.orders.length, 1, 'الطلبات ما زالت لم تُمسّ');
assert.equal(errors.length, 0, `لا أخطاء: ${errors.join(' | ')}`);
console.log('٥ الإشعار الجديد يصل   ', `بقي=${db.notifications.map((r) => r.id)} ✓`);

globalThis.fetch = realFetch;
console.log('\nكل فحوص التنظيف نجحت — الجدول وحده، والإشعار الجديد يصل سليماً.');
