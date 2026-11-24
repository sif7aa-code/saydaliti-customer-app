/**
 * اختبار بوابة الجولة (offline بالكامل): لا شبكة ولا كتابة على القاعدة.
 *
 *   node test/gate.mjs
 *
 * يُبدَّل `fetch` بذاكرة زائفة تتصرّف مثل PostgREST: القياس الخفيف
 * (عمود واحد + `Prefer: count=exact`) يردّ عدّاً في `content-range`
 * وطابعاً واحداً، و النافذة الكاملة تردّ الصفوف. يُحصي كلًّا منهما،
 * فيُقاس «هل وفّرنا فعلاً؟» و «هل ضاع حدث؟» في نفس الوقت.
 */
import assert from 'node:assert/strict';
import { SupabaseWatcher } from '../src/watcher.js';
import { hub } from '../src/hub.js';
import { EV } from '../src/events.js';

const realFetch = globalThis.fetch;
globalThis.fetch = fake;

const db = {
  orders: [row('o1', { status: 'delivered' })],
  products: [
    row('p1', { name: 'تمر', price: 2500 }),
    row('p2', { name: 'سمن', price: 4000 }),
  ],
  order_items: [],
  notifications: [],
  shops: [],
  push_tokens: [],
};
let probes = 0; // قياسات البوابة الخفيفة (1.07 KB لكل واحد)
let windows = 0; // نوافذ كاملة — هو الاستهلاك الذي نقلّله
let probesFail = false;
const streamed = [];

function row(id, extra = {}) {
  return {
    id,
    serial_number: 1,
    status: 'pending',
    user_phone: '9647000000001',
    is_free_driver_request: false,
    address: '',
    assigned_driver_phone: null,
    name: 'منتج',
    price: 1000,
    old_price: null,
    is_active: true,
    shop_id: 's1',
    shop_name: 'متجر',
    image_path: null,
    logo_image: null,
    order_id: 'o1',
    product_name: 'تمر',
    quantity: 1,
    total: 1000,
    created_at: '2026-11-01T00:00:00+00:00',
    updated_at: '2026-11-01T00:00:00+00:00',
    ...extra,
  };
}

function res(body, headers = {}) {
  return {
    ok: true,
    status: 200,
    headers: { get: (n) => headers[String(n).toLowerCase()] ?? null },
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

/**
 * هل النافذة تردّ ما طُلب منها فقط؟
 *
 *   PostgREST لا يرسل عموداً لم يُذكر في `select`. تجاهل هذا في
 *   السائل الزائف هو بالضبط ما أخفى عطل ٢٠٢٦-١١-٠٦: نافذة
 *   `order_items` تطلب ٨ أعمدة لا `created_at` بينها، فكان الزرع
 *   يقرأ العمود من ردّ الزيف و يظنّ أن الطابع موجود.
 */
function project(rows, select) {
  if (select === '' || select === '*' || select.includes('!') || select.includes('.')) {
    return rows;
  }
  const cols = select.split(',');
  return rows.map((r) => Object.fromEntries(cols.map((c) => [c, r[c]])));
}

async function fake(url, opts = {}) {
  const u = new URL(url);
  const head = Object.fromEntries(
    Object.entries(opts.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]),
  );
  const last = u.pathname.split('/').pop();
  if (last === 'rpc') return res([]); // كل الدوال: لا صفوف مدفوعة
  const table = last;
  const select = u.searchParams.get('select') ?? '';
  const singleCol = select !== '' && !select.includes(',') && select !== '*';

  if (singleCol && (head.prefer ?? '').includes('count')) {
    if (probesFail) throw new Error('بوابة مفكّكة');
    probes += 1;
    const rows = db[table] ?? [];
    const col = select;
    const latest = rows.map((r) => String(r[col] ?? '')).sort().at(-1) ?? '';
    return res(rows.length ? [{ [col]: latest }] : [], {
      'content-range': `0-0/${rows.length}`,
    });
  }

  if (['orders', 'products', 'order_items'].includes(table)) windows += 1;
  const rows = (db[table] ?? []).slice();
  const orderCol = (u.searchParams.get('order') ?? 'updated_at').split('.')[0];
  rows.sort((a, b) => String(b[orderCol]).localeCompare(String(a[orderCol])));
  const limit = Number(u.searchParams.get('limit') ?? '60');
  return res(project(rows.slice(0, limit), select), { 'content-range': `0-0/${rows.length}` });
}

// مشترك زائف يلتقط كل ما يُبثّ، فلا يبقى «هل ضاع الحدث؟» تخميناً
hub.add(
  {
    write: (frame) => {
      const m = /^event: (.+)$/m.exec(String(frame));
      if (m) streamed.push(m[1]);
    },
    on: () => {},
  },
  { phone: '9647000000001', roles: ['customer', 'driver', 'admin', 'shop_owner'] },
);

const errors = [];
const w = new SupabaseWatcher({
  url: 'https://fake.supabase.co',
  key: 'x'.repeat(40),
  fcm: null,
  onError: (m) => errors.push(String(m)),
  onLog: () => {},
});
const st = () => w.stats;
const mark = () => ({ w: windows, p: probes });
const delta = (m) => ({ نوافذ: windows - m.w, بوابة: probes - m.p });

// ── ١) أول دورة: تهيئة بالنوافذ، لا قياس قبل بصمات ──────────────
let m = mark();
await w.tick();
assert.ok(windows > m.w, 'الدورة الأولى يجب أن تفتح النوافذ (تهيئة)');
assert.equal(probes, m.p, 'التهيئة لا تدفع قياس بوابة');
assert.ok(w._marks, 'التهيئة تبني العلامات من صفوفها (بلا قياس تأسيس)');
console.log('١ تهيئة           ', delta(m), '✓');

// ── ٢) سكون مطلق: بوابة فقط ────────────────────────────────────
m = mark();
await w.tick();
assert.equal(windows, m.w, 'السكون لا يجب أن يفتح أي نافذة');
assert.equal(probes - m.p, 4, 'السكون = ٤ قياسات فقط');
assert.ok(st().gated >= 1, 'عَدّاد الجولات المكتفية يترقّى');
assert.equal(streamed.length, 0, 'السكون لا يبثّ أي حدث');
console.log('٢ سكون            ', delta(m), `مكتفية=${st().gated} ✓`);

// ── ٣) طلب جديد (إدراج ⇒ العدد والطابع يتقدّمان) ────────────────
db.orders.push(
  row('o2', {
    status: 'pending',
    created_at: '2026-11-06T10:00:00+00:00',
    updated_at: '2026-11-06T10:00:00+00:00',
  }),
);
m = mark();
await w.tick();
assert.ok(windows > m.w, 'الطلب الجديد يجب أن يفتح النوافذ');
assert.ok(streamed.includes(EV.ORDER_NEW), 'حدث new.order بُثّ');
console.log('٣ طلب جديد        ', delta(m), `أحداث=${st().orderEvents} ✓`);

// ── ٤) طلب نشط ⇒ النوافذ كاملة، و لا قياس فوقها ─────────────────
assert.ok(w.activeOrders > 0, 'الجولة السابقة حسبت الطلب نشطاً || ' + errors.join(' | '));
m = mark();
await w.tick();
assert.ok(windows > m.w, 'وبينما هناك طلب نشط تُفتح النوافذ دائماً');
assert.equal(probes, m.p, 'الجولة النشطة لا تدفع قياس بوابة إضافياً');
console.log('٤ طلب نشط         ', delta(m), '✓');

// ── ٥) إغلاق الطلب ⇒ الحالة وحدها تتقدّم (العدد ثابت) ───────────
const o2 = db.orders[1];
o2.status = 'delivered';
o2.updated_at = '2026-11-06T10:04:00+00:00';
m = mark();
await w.tick();
assert.ok(windows > m.w, 'تغيّر حالة الطلب بلا صف جديد يجب أن يُكتشف');
assert.equal(w.activeOrders, 0, 'وبإغلاق الطلب تعود الجولة إلى البوابة');
console.log('٥ إغلاق طلب       ', delta(m), '✓');

// ── ٦) تعديل سعر منتج (العدد ثابت، الطابع يتقدّم) ───────────────
m = mark();
db.products[0].price = 2750;
db.products[0].updated_at = '2026-11-06T10:05:00+00:00';
await w.tick();
assert.ok(windows > m.w, 'تغيّر السعر بلا تغيير في العدد يجب أن يُكتشف');
assert.ok(
  streamed.includes(EV.PRICE_CHANGED) || streamed.includes(EV.PRODUCT_CHANGED),
  'حدث السعر/المنتج بُثّ',
);
console.log('٦ تعديل سعر        ', delta(m), `أحداث منتج=${st().productEvents} ✓`);

// ── ٧) حذف منتج (العدد ينقص — لا تراه النوافذ وحدها) ────────────
await w.tick();
m = mark();
db.products.splice(1, 1);
await w.tick();
assert.ok(windows > m.w, 'نقص العدد يجب أن يفتح النافذة');
assert.ok(st().deletedEvents > 0, 'الحذف سُجِّل لإخفاء فوري');
assert.ok(streamed.includes(EV.PRODUCT_DELETED), 'حدث product.deleted بُثّ');
console.log('٧ حذف منتج        ', delta(m), `حذف=${st().deletedEvents} ✓`);

// ── ٨) إشعار عام (جسر الأكواد/العجلة/المحفظة/الحجوزات) ──────────
await w.tick();
m = mark();
db.notifications.push(row('n1', { created_at: '2026-11-06T10:10:00+00:00' }));
await w.tick();
assert.ok(windows > m.w, 'صف إشعار جديد يجب أن يفتح الجولة');
console.log('٨ إشعار عام        ', delta(m), '✓');

// ── ٩) المسح الإلزامي كل دقيقة وإن لم يتحرّك شيء ────────────────
m = mark();
await w.tick();
assert.equal(windows, m.w, 'وبلا تغيير: السكون يكتفي بالبوابة');
// ★ بنود فعلية في `order_items`: نافذتها لا تقرأ `created_at`، فأي
//   زرعِ طابع منها يبني علامةً فارغة تُقارن بقياس حقيقي فتصير كل
//   دورة «متغيّرة». الرصد الحيّ ٢٠٢٦-١١-٠٦: `gated:0` مع نمو `ticks`.
db.order_items.push(row('i1', { order_id: 'o2', created_at: '2026-11-06T10:12:00+00:00' }));
await w.tick(); // جولة كاملة تبتلع الصف الجديد
w._sweepAt = Date.now() - 61000;
m = mark();
await w.tick();
assert.ok(windows > m.w, 'المسح الإلزامي يفتح النوافذ ولو بلا تغيير');
const g = st().gated;
m = mark();
await w.tick(); // والدورة التي تلي المسح بلا حركة تُقفل بالبوابة وحدها
assert.equal(windows, m.w, 'بعد جولة كاملة بلا تغيير: لا تفتح نافذة');
assert.equal(probes - m.p, 4, 'ولا تُدفع فوقها إلا القياسات الأربعة');
assert.equal(st().gated, g + 1, 'عَدّاد الجولات المكتفية يترقّى بعد المسح');
console.log('٩ مسح إلزامي       ', delta(m), `مكتفية=${st().gated} ✓`);

// ── ١٠) فشل القياس ⇒ جولة كاملة (لا يُثق بـ«لا تغيير») ──────────
w._sweepAt = Date.now();
m = mark();
probesFail = true;
await w.tick();
assert.ok(windows > m.w, 'لو تعثّرت البوابة تُفتح النوافذ ولا تُتجاهل');
probesFail = false;
console.log('١٠ فشل البوابة      ', delta(m), '✓');

// ── ١١) فاتورة يومٍ ساكن ────────────────────────────────────────
const PROBE_KB = 4.29, FULL_KB = 13.13, IDLE_S = 10, SWEEP_S = 60;
const sweeps = 86400 / SWEEP_S;
const before = (86400 / IDLE_S) * FULL_KB;
const after = (86400 / IDLE_S - sweeps) * PROBE_KB + sweeps * FULL_KB;
console.log(
  `١١ يوم ساكن: كان ${(before / 1024).toFixed(1)} MB ⇒ صار ${(after / 1024).toFixed(1)} MB` +
    ` (${((1 - after / before) * 100).toFixed(0)}٪ أقل) · شهرياً ` +
    `${(before * 30 / 1024 / 1024).toFixed(2)} ⇒ ${(after * 30 / 1024 / 1024).toFixed(2)} GB`,
);

globalThis.fetch = realFetch;
console.log('\nكل فحوص البوابة نجحت — لا حدث ضاع و لا نافذة في السكون.');
