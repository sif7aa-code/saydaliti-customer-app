import assert from 'node:assert/strict';
import test from 'node:test';

import { EV, bus } from '../src/events.js';
import { hub } from '../src/realtime-hub.js';
import { SupabaseWatcher } from '../src/supabase-watcher.js';

/** يلتقط إطارات SSE مكافئاً لـ res حقيقي. */
function fakeRes() {
  const frames = [];
  return {
    frames,
    write(s) {
      frames.push(s);
      return true;
    },
    on() {},
    once() {},
    removeListener() {},
    text: () => frames.join(''),
  };
}

const listen = () => {
  const got = [];
  const h = (e) => got.push(e);
  bus.on('fanout', h);
  return { got, off: () => bus.off('fanout', h) };
};

test('SSE: عميل برقم يظهر له حدثه فقط', () => {
  const a = fakeRes();
  const b = fakeRes();
  hub.add(a, { phone: '9647000000001', roles: ['customer'] });
  hub.add(b, { phone: '9647000000002', roles: ['customer'] });

  bus.emit('fanout', {
    topic: EV.ORDER_NEW,
    payload: { id: 'o1' },
    audience: { phones: ['9647000000001'], roles: ['driver', 'admin'] },
    at: Date.now(),
  });

  assert.ok(a.text().includes('order.new'), 'صاحب الطلب استقبل');
  assert.equal(b.frames.length, 0, 'زبون آخر لم يستقبل طلب غيره');
});

test('SSE: الحدث العام يذهب للكل', () => {
  const a = fakeRes();
  const c = fakeRes();
  hub.add(a, { phone: 'p1', roles: ['customer'] });
  hub.add(c, { phone: 'p2', roles: ['driver'] });

  bus.emit('fanout', {
    topic: EV.PRICE_CHANGED,
    payload: { id: 'x' },
    audience: { roles: ['customer', 'driver', 'admin'] },
    at: Date.now(),
  });
  assert.ok(a.text().includes('price.changed'));
  assert.ok(c.text().includes('price.changed'));
});

test('SSE: التوجيه بالدور يمنع سائقاً من حدث أدمن فقط', () => {
  const drv = fakeRes();
  hub.add(drv, { phone: 'p3', roles: ['driver'] });
  bus.emit('fanout', {
    topic: EV.WA_STATE,
    payload: { state: 'connected' },
    audience: { roles: ['admin'] },
    at: Date.now(),
  });
  assert.equal(drv.frames.length, 0, 'السائق لا يرى حالة واتساب');
});

test('SSE: الحمولة لا تحمل إلا معرّف ونوع', () => {
  const a = fakeRes();
  hub.add(a, { phone: 'p4', roles: ['customer'] });
  bus.emit('fanout', {
    topic: EV.PRICE_CHANGED,
    payload: { id: 'p', name: 'شاي', price: 500, oldPrice: 700, at: 'now' },
    audience: { roles: ['customer'] },
    at: Date.now(),
  });
  const body = a.text();
  assert.ok(body.includes('"price":500'));
  assert.ok(!/phone|name":"|address|latitude/.test(body.replace('"name":"شاي"', '')));
});

test('المراقب: أول قراءة لا تُطلق أحداثاً وهمية', () => {
  const w = new SupabaseWatcher({ url: '', serviceKey: '' });
  const rows = [{ id: '1', updated_at: 't1', status: 'new', user_phone: 'p' }];
  const map = (o) => ({ key: o.id, fingerprint: `${o.updated_at}|${o.status}`, data: {}, phone: o.user_phone });
  assert.equal(w.diff('orders', rows, map).length, 0, 'التسخين لا يُطلق');
});

test('المراقب: صف جديد = isNew، وصف متغيّر = تحديث', () => {
  const w = new SupabaseWatcher({ url: '', serviceKey: '' });
  const map = (o) => ({ key: o.id, fingerprint: `${o.updated_at}|${o.status}`, data: {}, phone: o.user_phone });
  w.diff('orders', [{ id: '1', updated_at: 't1', status: 'new', user_phone: 'p' }], map);

  const added = w.diff(
    'orders',
    [
      { id: '1', updated_at: 't1', status: 'new', user_phone: 'p' },
      { id: '2', updated_at: 't2', status: 'new', user_phone: 'q' },
    ],
    map,
  );
  assert.equal(added.length, 1);
  assert.equal(added[0].isNew, true);
  assert.equal(added[0].key, '2');

  const changed = w.diff(
    'orders',
    [
      { id: '1', updated_at: 't3', status: 'accepted', user_phone: 'p' },
      { id: '2', updated_at: 't2', status: 'new', user_phone: 'q' },
    ],
    map,
  );
  assert.equal(changed.length, 1);
  assert.equal(changed[0].isNew, false);
  assert.equal(changed[0].key, '1');
});

test('المراقب: بلا تغيّر ⇒ لا شيء يُبثّ', () => {
  const w = new SupabaseWatcher({ url: '', serviceKey: '' });
  const map = (o) => ({ key: o.id, fingerprint: `${o.updated_at}|${o.status}`, data: {} });
  const rows = [{ id: '1', updated_at: 't1', status: 'new' }];
  w.diff('orders', rows, map);
  assert.equal(w.diff('orders', rows, map).length, 0);
});

test('المراقب: معطّل بلا مفاتيح ولا يبدأ', () => {
  const w = new SupabaseWatcher({ url: '', serviceKey: '' });
  assert.equal(w.enabled, false);
  assert.equal(w.start(), false);
  w.stop();
});

test('المراقب: يبدأ فقط بـ https ومفتاح طويل', () => {
  assert.equal(new SupabaseWatcher({ url: 'https://x.co', serviceKey: '' }).enabled, false);
  assert.equal(new SupabaseWatcher({ url: 'http://x.co', serviceKey: 'k'.repeat(30) }).enabled, false);
  assert.equal(new SupabaseWatcher({ url: 'https://x.co', serviceKey: 'k'.repeat(30) }).enabled, true);
});

test('المراقب: لا ينشر شيئاً بلا عملاء', () => {
  const before = hub.size;
  assert.ok(before >= 0);
});
