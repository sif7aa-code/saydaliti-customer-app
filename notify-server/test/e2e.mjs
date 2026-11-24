/**
 * اختبار حقيقي: يشترك بـSSE، ثم يعدّل سعر منتج عبر REST،
 * ويتحقق من وصول الحدث خلال المهلة.
 *
 * node test/e2e.mjs <x-api-key> <supabaseAnonKey>
 */
const KEY = process.argv[2];
const SB = process.argv[3];
const BASE = 'http://162.35.126.155';
const SBU = 'https://rwuldrktcghnmhvepbzg.supabase.co';

const H = (k) => ({ apikey: k, Authorization: `Bearer ${k}`, 'Content-Type': 'application/json' });

// نلتقط منتجاً حقيقياً لنستعيد سعره بعد الاختبار
const listRes = await fetch(`${SBU}/rest/v1/products?select=id,name,price,old_price&limit=1&price=not.is.null`, { headers: H(SB) });
const list = await listRes.json();
if (!Array.isArray(list) || list.length === 0) {
  console.log('لا يوجد منتج للاختبار — تخطّى');
  process.exit(2);
}
const p = list[0];
console.log(`منتج الاختبار: ${p.name}  price=${p.price}  old_price=${p.old_price}`);

// 1) اشترك
const t0 = Date.now();
const res = await fetch(`${BASE}/api/realtime?phone=9647000000001&roles=customer`, {
  headers: { 'x-api-key': KEY },
});
console.log('SSE HTTP', res.status);

const events = [];
const reader = res.body.getReader();
const dec = new TextDecoder();
let buf = '';
let ev = null;
let data = [];

const pump = (async () => {
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const fr = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const e = fr.split('\n').find((l) => l.startsWith('event:'));
      const d = fr.split('\n').find((l) => l.startsWith('data:'));
      if (e) {
        ev = e.slice(6).trim();
        if (ev !== 'hello') events.push({ topic: ev, at: Date.now() - t0, data: d?.slice(5) });
      }
    }
  }
})();

// 2) غيّر السعر
const newPrice = Number(p.price) + 1;
const up = await fetch(`${SBU}/rest/v1/products?id=eq.${p.id}`, {
  method: 'PATCH',
  headers: { ...H(SB), Prefer: 'return=representation' },
  body: JSON.stringify({ price: newPrice }),
});
console.log('PATCH price', up.status, '->', newPrice);
if (!up.ok) console.log('  body:', (await up.text()).slice(0, 200));

// 3) انتظر الحدث
const deadline = Date.now() + 25000;
while (Date.now() < deadline && events.length === 0) {
  await new Promise((r) => setTimeout(r, 300));
}

// 4) استعد السعر الأصلي دائماً
const back = await fetch(`${SBU}/rest/v1/products?id=eq.${p.id}`, {
  method: 'PATCH',
  headers: { ...H(SB), Prefer: 'return=representation' },
  body: JSON.stringify({ price: p.price }),
});
console.log('استعادة السعر الأصلي:', back.status, '->', p.price);

console.log('---');
if (events.length) {
  for (const e of events) console.log(`+${e.at}ms  ${e.topic}  ${e.data}`);
  const hit = events.find((e) => e.topic === 'product.changed' || e.topic === 'price.changed');
  console.log(hit ? `\nنجح: الحدث وصل خلال ${hit.at}ms` : '\nوصل الحدث لكن بنوع غير متوقع');
  process.exit(hit ? 0 : 3);
}
console.log('لم يصل أي حدث خلال 25 ثانية');
process.exit(4);
