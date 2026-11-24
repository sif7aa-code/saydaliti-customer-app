/**
 * اختبار كشف حذف منتج. ينشئ منتجاً مؤقتاً ثم يحذفه **دائماً**،
 * حتى لو انقطع الاختبار في المنتصف.
 *
 * node test/delete.mjs <notifyApiKey> <supabaseKey> [baseUrl]
 */
const KEY = process.argv[2];
const SB = process.argv[3];
const BASE = process.argv[4] || 'http://127.0.0.1:3002';
const SBU = 'https://rwuldrktcghnmhvepbzg.supabase.co';
const H = { apikey: SB, Authorization: `Bearer ${SB}`, 'Content-Type': 'application/json' };

let createdId = null;
const NAME = 'ZZ_حذف_اختبار_' + Date.now();

async function cleanup() {
  if (!createdId) return;
  const r = await fetch(`${SBU}/rest/v1/products?id=eq.${createdId}`, { method: 'DELETE', headers: H });
  console.log(`تنظيف ${createdId}: ${r.status}`);
  createdId = null;
}

process.on('SIGINT', async () => { await cleanup(); process.exit(1); });
process.on('SIGTERM', async () => { await cleanup(); process.exit(1); });

try {
  const shops = await (await fetch(`${SBU}/rest/v1/shops?select=id&limit=1`, { headers: H })).json();
  if (!shops?.length) { console.log('لا يوجد متجر — تخطّى'); process.exit(2); }

  const events = [];
  const res = await fetch(`${BASE}/api/realtime?phone=9647000000001&roles=customer`, {
    headers: { 'x-api-key': KEY },
  });
  console.log('SSE HTTP', res.status);
  const rd = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
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
        if (e && !e.slice(6).trim().includes('hello')) {
          events.push({ topic: e.slice(6).trim(), data: d?.slice(5) ?? '' });
        }
      }
    }
  })();

  // ننتظر تسخين المراقب حتى يمتلئ سجل الأسماء
  await new Promise((r) => setTimeout(r, 3000));

  const ins = await fetch(`${SBU}/rest/v1/products`, {
    method: 'POST', headers: { ...H, Prefer: 'return=representation' },
    body: JSON.stringify({ name: NAME, price: 1234, shop_id: shops[0].id, is_active: true }),
  });
  const body = await ins.json();
  createdId = Array.isArray(body) ? body[0]?.id : body?.id;
  console.log('أُنشئ:', createdId ?? 'فشل', ins.status);
  if (!createdId) { console.log(JSON.stringify(body).slice(0, 300)); process.exit(3); }

  // ننتظر دورتين حتى يلتقطه المراقب في seen.productNames
  await new Promise((r) => setTimeout(r, 6000));

  const del = await fetch(`${SBU}/rest/v1/products?id=eq.${createdId}`, { method: 'DELETE', headers: H });
  createdId = null;
  console.log('حُذف:', del.status);

  const deadline = Date.now() + 20000;
  while (Date.now() < deadline && !events.some((e) => e.topic === 'product.deleted')) {
    await new Promise((r) => setTimeout(r, 300));
  }

  console.log('--- كل الأحداث ---');
  for (const e of events) console.log(`  ${e.topic}  ${e.data.slice(0, 100)}`);

  const hit = events.find((e) => e.topic === 'product.deleted');
  if (!hit) { console.log('\n✗ لم يصل product.deleted'); process.exit(5); }
  const d = JSON.parse(hit.data);
  console.log(`\n${d.name === NAME ? '✓ نجح' : '✗ اسم خاطئ'}: ${d.name}`);
  console.log('أنواع أخرى وصلت:', [...new Set(events.map((e) => e.topic))].join(', '));
  process.exit(d.name === NAME ? 0 : 4);
} finally {
  await cleanup();
}
