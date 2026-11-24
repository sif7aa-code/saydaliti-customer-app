// التحقق من أن إطفاء/تشغيل المنتج يُحدث «بصمة» يلتقطها المراقب.
// البصمة في watcher.js هي: updated_at|price|old_price|name
import { SupabaseWatcher } from '../src/watcher.js';

const K =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3dWxkcmt0Y2dobm1odmVwYnpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAyMTEwMzYsImV4cCI6MjEwNTc4NzAzNn0.ynLvUf16ii_nm52oUCcC1Xt01arthhANPs1GA0DIX-I';
const w = new SupabaseWatcher({ url: 'https://rwuldrktcghnmhvepbzg.supabase.co', key: K });

// نفس ما في watcher.js سطر 526
const fp = (p) => `${p.updated_at}|${p.price}|${p.old_price}|${p.name}`;

const before = {
  id: 'x', name: 'منتج', price: 2500, old_price: null,
  shop_id: 's', updated_at: '2026-10-03T09:26:27Z',
};
const after = { ...before, updated_at: '2026-10-03T10:13:25Z' };

console.log('البصمة تتغير عند الإطفاء:', fp(before) !== fp(after));

// فيزيائياً من القاعدة: هل updated_at يتحرك فعلاً عند PATCH is_active؟
const H = { apikey: K, Authorization: `Bearer ${K}`, 'Content-Type': 'application/json' };
const id = 'b3a55446-8aaa-4af1-a076-d7045caa6c29';
const base = 'https://rwuldrktcghnmhvepbzg.supabase.co/rest/v1/products';
const read = async () => {
  const r = await fetch(`${base}?id=eq.${id}&select=is_active,updated_at`, { headers: H });
  return (await r.json())[0];
};
const t0 = await read();
await fetch(`${base}?id=eq.${id}`, {
  method: 'PATCH', headers: H, body: JSON.stringify({ is_active: false }),
});
const t1 = await read();
await fetch(`${base}?id=eq.${id}`, {
  method: 'PATCH', headers: H, body: JSON.stringify({ is_active: true }),
});
const t2 = await read();

console.log('قبل  :', t0.is_active, t0.updated_at);
console.log('مطفأ :', t1.is_active, t1.updated_at);
console.log('مستعاد:', t2.is_active, t2.updated_at);
console.log('updated_at تحرّك عند الإطفاء:', t0.updated_at !== t1.updated_at);
console.log('المنتج مستعاد لنشط:', t2.is_active === true);