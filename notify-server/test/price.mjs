/**
 * اختبار تغيّر سعر صنف داخل طلب ⇒ يصل الحدث kind=price_changed
 * مع السعر القديم والجديد وشعار المتجر. ينظّف دائماً.
 *
 * node test/price.mjs <notifyApiKey> <supabaseKey> [baseUrl]
 */
const KEY = process.argv[2];
const SB = process.argv[3];
const BASE = process.argv[4] || 'http://127.0.0.1:3002';
const SBU = 'https://rwuldrktcghnmhvepbzg.supabase.co';
const H = { apikey: SB, Authorization: `Bearer ${SB}`, 'Content-Type': 'application/json' };
const J = (t) => t?.toString().trim() ?? '';
const PHONE = '9647000000001';

let orderId = null, itemId = null;
async function cleanup() {
  if (itemId) { await fetch(`${SBU}/rest/v1/order_items?id=eq.${itemId}`, { method: 'DELETE', headers: H }); itemId = null; }
  if (orderId) { await fetch(`${SBU}/rest/v1/orders?id=eq.${orderId}`, { method: 'DELETE', headers: H }); orderId = null; }
}
process.on('SIGINT', async () => { await cleanup(); process.exit(1); });
process.on('SIGTERM', async () => { await cleanup(); process.exit(1); });

try {
  const shops = await (await fetch(`${SBU}/rest/v1/shops?select=id,name,image_path&limit=1`, { headers: H })).json();
  if (!shops?.length) { console.log('لا يوجد متجر'); process.exit(2); }
  const shop = shops[0];

  const events = [];
  const res = await fetch(`${BASE}/api/realtime?phone=${PHONE}&roles=customer`, { headers: { 'x-api-key': KEY } });
  console.log('SSE HTTP', res.status);
  const rd = res.body.getReader(); const dec = new TextDecoder(); let buf = '';
  (async () => {
    while (true) {
      const { value, done } = await rd.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const fr = buf.slice(0, i); buf = buf.slice(i + 2);
        const e = fr.split('\n').find((l) => l.startsWith('event:'));
        const d = fr.split('\n').find((l) => l.startsWith('data:'));
        const t = e ? e.slice(6).trim() : '';
        if (e && t !== 'hello') events.push({ topic: t, data: d?.slice(5) ?? '' });
      }
    }
  })();

  await new Promise((r) => setTimeout(r, 3000));

  const NAME = 'ZZ_سعر_اختبار_' + Date.now();
  const ord = await (await fetch(`${SBU}/rest/v1/orders`, {
    method: 'POST', headers: { ...H, Prefer: 'return=representation' },
    body: JSON.stringify({
      user_phone: PHONE, user_name: 'اختبار', status: 'pending',
      order_number: 'ZZ-TEST-' + Date.now(), serial_number: Date.now() % 2000000000,
      total_amount: 5000,
    }),
  })).json();
  orderId = Array.isArray(ord) ? ord[0]?.id : ord?.id;
  if (!orderId) { console.log(JSON.stringify(ord).slice(0, 300)); process.exit(3); }
  console.log('الطلب: نعم');

  const it = await (await fetch(`${SBU}/rest/v1/order_items`, {
    method: 'POST', headers: { ...H, Prefer: 'return=representation' },
    body: JSON.stringify({
      order_id: orderId, product_name: NAME, shop_name: shop.name,
      shop_id: shop.id, quantity: 2, price: 2500, total: 5000,
    }),
  })).json();
  itemId = Array.isArray(it) ? it[0]?.id : it?.id;
  if (!itemId) { console.log(JSON.stringify(it).slice(0, 300)); process.exit(4); }
  console.log('الصنف: نعم');

  await new Promise((r) => setTimeout(r, 6000));

  // ★ المندوب يغيّر السعر 2500 ⇒ 3000 (والإجمالي 5000 ⇒ 6000)
  const up = await fetch(`${SBU}/rest/v1/order_items?id=eq.${itemId}`, {
    method: 'PATCH', headers: { ...H, Prefer: 'return=representation' },
    body: JSON.stringify({ price: 3000, total: 6000 }),
  });
  console.log('تغيّر السعر:', up.status, '2500 ⇒ 3000');
  if (!up.ok) console.log('  ', (await up.text()).slice(0, 200));

  const deadline = Date.now() + 22000;
  while (Date.now() < deadline && !events.some((e) => e.topic === 'order.item_removed')) {
    await new Promise((r) => setTimeout(r, 300));
  }

  console.log('--- الأحداث ---');
  for (const e of events) console.log(`  ${e.topic}  ${e.data.slice(0, 170)}`);

  const hit = events.find((e) => e.topic === 'order.item_removed');
  if (!hit) { console.log('\n✗ لم يصل أي حدث'); process.exit(5); }
  const d = JSON.parse(hit.data);
  const checks = [
    ['kind=price_changed', d.kind === 'price_changed'],
    ['productName', d.productName === NAME],
    ['from=2500', d.from === 2500],
    ['to=3000', d.to === 3000],
    ['shopImage', J(d.shopImage) === J(shop.image_path)],
  ];
  console.log('---');
  for (const [k, ok] of checks) console.log(`  ${ok ? '✓' : '✗'} ${k}`);
  process.exit(checks.every(([, ok]) => ok) ? 0 : 6);
} finally { await cleanup(); }
