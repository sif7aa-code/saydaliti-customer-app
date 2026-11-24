import { EV, publish } from './events.js';

const int = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d);

/**
 * مراقب Supabase: يكشف تغيّر الطلبات والأسعار/المنتجات ثم يبثّه.
 *
 * ★ لماذا REST كل ثانيتين وليس LISTEN/NOTIFY:
 *   LISTEN يحتاج DATABASE_URL (كلمة مرور قاعدة). REST يحتاج
 *   service_role فقط، وهو أسهل بكثير في الإعداد والنسخ الاحتياطي.
 *   الثمن: كشفٌ بتأخير ≤ PollMs. التوصيل للجهاز شبه فوري لأن
 *   الاستطلاع يحدث مرة واحدة على السيرفر ثم يُبثّ لكل العملاء،
 *   بدل أن يسأل كل جهاز القاعدة بنفسه (الوضع الحالي).
 *
 * ★ البصمة (fingerprint): نقرأ آخر N صفاً ونقارن (id, updated_at).
 *   لو تغيّرت ⇒ حدث. لا نحتفظ بكل الجدول ولا نقرأ آلاف الصفوف.
 */
export class SupabaseWatcher {
  constructor({
    url,
    serviceKey,
    pollMs = 2000,
    limit = 60,
    onError = () => {},
    onLog = () => {},
  }) {
    this.url = String(url || '').replace(/\/$/, '');
    this.key = String(serviceKey || '');
    this.pollMs = int(pollMs, 2000);
    this.limit = int(limit, 60);
    this.onError = onError;
    this.onLog = onLog;

    this.timer = null;
    this.busy = false;
    this.seen = { orders: new Map(), products: new Map() };
    this.stats = { ticks: 0, orderEvents: 0, productEvents: 0, errors: 0, lastAt: 0 };
  }

  get enabled() {
    return this.url.startsWith('https://') && this.key.length > 20;
  }

  start() {
    if (!this.enabled || this.timer) return false;
    if (!this.timer) this.timer = setInterval(() => this.tick(), this.pollMs);
    this.timer.unref?.();
    this.tick();
    this.onLog(`مراقب Supabase يعمل كل ${this.pollMs}ms`);
    return true;
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  async get(table, columns) {
    const res = await fetch(
      `${this.url}/rest/v1/${table}?select=${columns}&order=updated_at.desc,id.desc&limit=${this.limit}`,
      { headers: { apikey: this.key, Authorization: `Bearer ${this.key}` } },
    );
    if (!res.ok) {
      throw new Error(`${table} ${res.status}: ${(await res.text()).slice(0, 160)}`);
    }
    return res.json();
  }

  /**
   * يقارن صفوف جدول ببصمته السابقة ويريد ما تغيّر.
   * `mapFn` يحوّل الصف إلى { key, fingerprint, event, data, phone }.
   * أول قراءة تُسجّل البصمات فقط ولا تُطلق حدثاً، وإلا بُثّ 60 حدثاً
   * وهمياً عند كل إقلاع.
   */
  diff(table, rows, mapFn) {
    const prev = this.seen[table];
    const primed = prev.size > 0;
    const next = new Map();
    const changed = [];
    for (const row of rows) {
      const mapped = mapFn(row);
      if (!mapped) continue;
      next.set(mapped.key, mapped.fingerprint);
      if (!primed) continue;
      const before = prev.get(mapped.key);
      if (before === undefined) changed.push({ ...mapped, isNew: true });
      else if (before !== mapped.fingerprint) changed.push({ ...mapped, isNew: false });
    }
    this.seen[table] = next;
    return changed;
  }

  async tick() {
    if (this.busy || !this.enabled) return;
    this.busy = true;
    try {
      const [orders, products] = await Promise.all([
        this.get('orders', 'id,serial_number,status,user_phone,created_at,updated_at'),
        this.get('products', 'id,name,price,old_price,shop_id,created_at,updated_at'),
      ]);

      // الطلبات: الجديد لصاحب الطلب + كل السائقين + الأدمن.
      const orderChanges = this.diff('orders', orders, (o) => ({
        key: o.id,
        fingerprint: `${o.updated_at}|${o.status}`,
        data: { id: o.id, status: o.status, at: o.updated_at },
        phone: o.user_phone,
      }));
      for (const o of orderChanges) {
        this.stats.orderEvents += 1;
        publish(
          o.isNew ? EV.ORDER_NEW : EV.ORDER_STATUS,
          o.data,
          { phones: [o.phone], roles: ['driver', 'admin'] },
        );
      }

      // الأسعار/المنتجات: كل الزبائن + السائقون + الأدمن.
      const priceChanged = (p) =>
        p.old_price !== null && p.price !== p.old_price;
      const productChanges = this.diff('products', products, (p) => ({
        key: p.id,
        fingerprint: `${p.updated_at}|${p.price}|${p.old_price}|${p.name}`,
        data: {
          id: p.id,
          name: p.name,
          price: p.price,
          oldPrice: p.old_price,
          at: p.updated_at,
        },
      }));
      for (const c of productChanges) {
        this.stats.productEvents += 1;
        publish(priceChanged(c.data) ? EV.PRICE_CHANGED : EV.PRODUCT_CHANGED, c.data, {
          roles: ['customer', 'driver', 'admin'],
        });
      }

      this.stats.ticks += 1;
      this.stats.lastAt = Date.now();
    } catch (err) {
      this.stats.errors += 1;
      this.onError(err.message);
    } finally {
      this.busy = false;
    }
  }
}
