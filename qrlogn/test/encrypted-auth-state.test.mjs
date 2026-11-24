import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { useEncryptedAuthState } from '../src/encrypted-auth-state.js';
import { loadSessionKey } from '../src/session-crypto.js';

const KEY = Buffer.alloc(32, 3);
const quiet = () => {};

const seed = (dir) => {
  fs.mkdirSync(path.join(dir, 'session'), { recursive: true });
  fs.writeFileSync(
    path.join(dir, 'session', 'creds.json'),
    JSON.stringify({ noiseKey: 'x', registered: true, me: { id: '8254:1@s.whatsapp.net' } }),
  );
  fs.writeFileSync(
    path.join(dir, 'session', 'pre-key-1.json'),
    JSON.stringify({ keyId: 1, private: 'AAAABBBBCCCC' }),
  );
  fs.writeFileSync(
    path.join(dir, 'session', 'app-state-sync-key-critical_block.json'),
    JSON.stringify({ keyData: { keyId: 'crit' } }),
  );
};

test('ترحيل الجلسة القديمة: تُقرأ ثم تُشفَّر وتُحذف الأصلية', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-mig-'));
  const logs = [];
  seed(dir);

  const { state, saveCreds, migrateAll } = await useEncryptedAuthState(
    path.join(dir, 'session'),
    { key: KEY, log: (m) => logs.push(m) },
  );

  // creds.json فقط: القراءة كسولة لبقية المفاتيح
  assert.equal(state.creds.registered, true);
  assert.equal(state.creds.me.id, '8254:1@s.whatsapp.net');

  // ★ الجولة الكاملة: كل ملف نصي على القرص صار مشفَّراً
  const n = await migrateAll();
  assert.equal(n, 2, 'مفتاحان فقط (creds.json رُحِّل وقت القراءة)');

  for (const f of ['creds.json', 'pre-key-1.json', 'app-state-sync-key-critical_block.json']) {
    const raw = fs.readFileSync(path.join(dir, 'session', f));
    assert.ok(raw.length > 0, `${f} اختفى`);
    assert.ok(!raw.toString('utf8').includes('8254'), `${f} ما زال يحمل البيانات`);
    assert.notEqual(raw.toString('utf8').trimStart()[0], '{');
  }

  const all = fs.readdirSync(path.join(dir, 'session'))
    .map((f) => fs.readFileSync(path.join(dir, 'session', f)).toString('utf8'))
    .join('');
  assert.ok(!all.includes('AAAABBBBCCCC'));
  assert.ok(!all.includes('registered'));
  assert.ok(!all.includes('keyId'), 'أسماء حقول JSON ما زالت ظاهرة');
  assert.ok(logs.some((l) => l.includes('شُفِّرت')));

  await saveCreds();
  fs.rmSync(dir, { recursive: true, force: true });
});

test('الجولة الثانية لا تَعُد ترحيلاً (الجلسة مشفَّرة أصلاً)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-mig3-'));
  seed(dir);
  const a = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  await a.migrateAll();
  const b = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  assert.equal(await b.migrateAll(), 0);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('القراءة الثانية بعد الترحيل تُرجع نفس البيانات (لا ضياع)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-mig2-'));
  seed(dir);
  const first = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  await first.migrateAll();
  const second = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  assert.equal(second.state.creds.registered, true);
  assert.equal(second.state.creds.me.id, '8254:1@s.whatsapp.net');
  const keys = await second.state.keys.get('pre-key', [1]);
  assert.equal(keys[1].private, 'AAAABBBBCCCC');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('قراءة الـ keys بعد الترحيل تحتاج نفس المفتاح وتعمل', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-mig2-'));
  seed(dir);
  const first = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  const second = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  assert.equal(second.migratedFiles, 0, 'القراءة الثانية لا تُ счита هجرة');
  assert.deepEqual(second.state.creds, first.state.creds);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('مفتاح خاطئ ⇒ رفض صريح، لا جلسة جديدة صامتة', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-wrong-'));
  seed(dir);
  const first = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  await first.migrateAll();

  const other = Buffer.alloc(32, 9);
  // ★ الرجوع إلى initAuthCreds هنا كان سيعيد ربط الجهاز من جديد
  //   ويلغي الجلسة الأصلية على واتساب بصمت.
  await assert.rejects(
    () => useEncryptedAuthState(path.join(dir, 'session'), { key: other, log: quiet }),
    /تعذّر فكّ/,
  );
  fs.rmSync(dir, { recursive: true, force: true });
});

test('مجلد فارغ = ربط جديد بلا رفض (أول تشغيل)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-fresh-'));
  const { state } = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  assert.equal(state.creds.registered, false, 'بانتظار مسح رمز QR');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('keys.set/get يستخدمان نفس أسماء ملفات Baileys', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-io-'));
  const { state } = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  await state.keys.set({ 'pre-key': { 42: { keyId: 42, private: 'SECRETPRIV' } } });
  const got = await state.keys.get('pre-key', [42]);
  assert.equal(got[42].private, 'SECRETPRIV');
  const onDisk = fs.readFileSync(path.join(dir, 'session', 'pre-key-42.json')).toString('utf8');
  assert.ok(!onDisk.includes('SECRETPRIV'), 'المفتاح الخاص مكشوف على القرص');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('حذف مفتاح غير موجود لا يرمي (حالة إعادة الربط)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-del-'));
  const { state } = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  await state.keys.set({ 'pre-key': { 9: { private: 'z' } } });
  await state.keys.set({ 'pre-key': { 9: null } });
  assert.equal(fs.existsSync(path.join(dir, 'session', 'pre-key-9.json')), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('★ Buffers تبقى Buffers بعد الترحيل (وإلا رفضها libsignal)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-buf-'));
  const priv = Buffer.from([0, 1, 2, 250, 251, 255, 128, 64]);
  fs.mkdirSync(path.join(dir, 'session'), { recursive: true });
  fs.writeFileSync(
    path.join(dir, 'session', 'creds.json'),
    JSON.stringify({
      me: { id: '9647:1@s.whatsapp.net' },
      // نفس الشكل الذي ينتجه Baileys' BufferJSON.replacer
      noiseKey: {
        private: { type: 'Buffer', data: Array.from(priv) },
        public: { type: 'Buffer', data: [1, 2, 3] },
      },
    }),
  );

  const { state } = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });

  const p = state.creds.noiseKey?.private;
  assert.ok(Buffer.isBuffer(p), `private هو ${p?.constructor?.name} لا Buffer`);
  assert.ok(p.equals(priv), 'البايتات تغيّرت في الرحلة');
  assert.ok(Buffer.isBuffer(state.creds.noiseKey?.public));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('★ round-trip يكتب Buffer ذا 0xff بلا فقد', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-bytes-'));
  const { state, saveCreds } = await useEncryptedAuthState(
    path.join(dir, 'session'),
    { key: KEY, log: quiet },
  );
  state.creds.noiseKey = { private: Buffer.from([0, 127, 128, 254, 255]) };
  await saveCreds();

  const again = await useEncryptedAuthState(path.join(dir, 'session'), { key: KEY, log: quiet });
  const p = again.state.creds.noiseKey.private;
  assert.ok(Buffer.isBuffer(p), 'ليس Buffer');
  assert.ok(p.equals(Buffer.from([0, 127, 128, 254, 255])), 'بايتات مفقودة');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('loadSessionKey يرفض غياب المفتاح/nonbase64/طول خاطئ', () => {
  const prev = process.env.WA_SESSION_KEY;
  delete process.env.WA_SESSION_KEY;
  assert.throws(() => loadSessionKey(), /WA_SESSION_KEY غير مضبوط/);
  process.env.WA_SESSION_KEY = 'short';
  assert.throws(() => loadSessionKey(), /32 بايت/);
  process.env.WA_SESSION_KEY = Buffer.alloc(32, 1).toString('base64');
  assert.equal(loadSessionKey().length, 32);
  if (prev === undefined) delete process.env.WA_SESSION_KEY;
  else process.env.WA_SESSION_KEY = prev;
});
