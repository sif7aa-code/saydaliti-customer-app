import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { AuthKeys } from '../src/auth.js';
import { CodeStore, maskPhone, normalizePhone } from '../src/codes.js';

const tmp = () =>
  fs.mkdtempSync(path.join(os.tmpdir(), 'wa-test-'));

const makeStore = (over = {}) => {
  const dir = tmp();
  return new CodeStore(path.join(dir, 'codes.json'), {
    ttlMs: 60000,
    cooldownMs: 60000,
    ...over,
  });
};

test('يولّد كوداً ويقبله مرة واحدة فقط', () => {
  const store = makeStore();
  const created = store.create('9647700000000');
  assert.equal(created.ok, true);
  assert.match(created.code, /^\d{4}$/);

  assert.equal(store.verify('9647700000000', '000000').reason, 'wrong_code');
  const ok = store.verify('9647700000000', created.code);
  assert.equal(ok.ok, true);
  assert.equal(store.verify('9647700000000', created.code).reason, 'no_code');
});

test('يحترم مدة الانتظار بين كودين لنفس الرقم', () => {
  const store = makeStore();
  assert.equal(store.create('9647700000001').ok, true);
  const again = store.create('9647700000001');
  assert.equal(again.ok, false);
  assert.equal(again.reason, 'cooldown');
  assert.ok(again.retryAfter > 0);
});

test('الافتراضي: رقمان فقط لكل رقم بالساعة', () => {
  const store = makeStore({ cooldownMs: 0 });
  assert.equal(store.maxPerPhonePerHour, 2);
  assert.equal(store.create('9647000000009').ok, true);
  assert.equal(store.create('9647000000009').ok, true);
  assert.equal(store.create('9647000000009').reason, 'phone_limit');
});

test('يلغي الكود بعد محاولات خاطئة', () => {
  const store = makeStore({ maxAttempts: 3 });
  const created = store.create('9647700000002');
  for (let i = 0; i < 3; i += 1) {
    assert.equal(store.verify('9647700000002', '111111').reason, 'wrong_code');
  }
  assert.equal(store.verify('9647700000002', created.code).reason, 'too_many_attempts');
  assert.equal(store.entries.has('9647700000002'), false);
});

test('يطبّق حد الإرسال لكل رقم وللسيرفر', () => {
  const perPhone = makeStore({
    cooldownMs: 0,
    maxPerPhonePerHour: 2,
    maxTotalPerHour: 100,
  });
  perPhone.create('9647000000000');
  perPhone.create('9647000000000');
  assert.equal(perPhone.create('9647000000000').reason, 'phone_limit');

  const total = makeStore({ cooldownMs: 0, maxTotalPerHour: 2 });
  total.create('9647000000001');
  total.create('9647000000002');
  assert.equal(total.create('9647000000003').reason, 'server_limit');
});

test('يحفظ الأكواد في ملف ويعيد تحميلها', () => {
  const dir = tmp();
  const file = path.join(dir, 'codes.json');
  const store = new CodeStore(file, { cooldownMs: 0 });
  const created = store.create('9647000000004');
  return new Promise((resolve) => {
    store.saveTimer = null;
    setTimeout(() => {
      const reloaded = new CodeStore(file, { cooldownMs: 0 });
      assert.equal(reloaded.verify('9647000000004', created.code).ok, true);
      resolve();
    }, 400);
  });
});

test('يتجاهل الأكواد المنتهية عند التحميل', () => {
  const dir = tmp();
  const file = path.join(dir, 'codes.json');
  fs.writeFileSync(
    file,
    JSON.stringify({
      entries: [
        { phone: '1', salt: 'a', hash: 'b', expiresAt: Date.now() - 1000, attempts: 0, sentAt: 0 },
      ],
    }),
  );
  const store = new CodeStore(file, {});
  assert.equal(store.entries.size, 0);
});

test('يحوّل الرقم المحلي إلى دولي', () => {
  assert.equal(normalizePhone('0770 000 0000', '964'), '9647700000000');
  assert.equal(normalizePhone('+964 770 000 0000', '964'), '9647700000000');
  assert.equal(normalizePhone('9647700000000', '964'), '9647700000000');
  assert.equal(normalizePhone('123', '964'), null);
  assert.equal(normalizePhone('', '964'), null);
  assert.equal(maskPhone('9647700000000'), '964****000');
});

test('يوقّع توكن الجلسة ويتحقق منه', () => {
  const keys = new AuthKeys({ dataDir: tmp() }).init();
  const token = keys.issueToken('9647000000005');
  const data = keys.readToken(token);
  assert.equal(data.phone, '9647000000005');
  assert.equal(keys.readToken(`${token}x`), null);
  assert.equal(keys.readToken('garbage'), null);

  const fake = `eyJwaG9uZSI6IjkiLCJleHAiOjk5OTk5OTk5OTk5OX0.aaaa`;
  assert.equal(keys.readToken(fake), null);
});

test('يتولّد مفتاح API مرة واحدة ويبقى ثابتاً', () => {
  const dir = tmp();
  const a = new AuthKeys({ dataDir: dir }).init();
  const b = new AuthKeys({ dataDir: dir }).init();
  assert.equal(a.apiKey, b.apiKey);
  assert.ok(a.apiKey.length >= 32);
  assert.equal(a.checkApiKey({ get: () => null, query: {} }), false);
});
