import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { generateSessionKey, looksLikePlainJson, open, seal } from '../src/session-crypto.js';

const SECRET_LIKE = { noiseKey: 'privkey-looking-material', me: { id: '82540715106362:12@s.whatsapp.net' } };

test('seal/open round-trip مع AAD', () => {
  const key = Buffer.alloc(32, 7);
  const packed = seal(key, SECRET_LIKE, 'creds.json');
  assert.deepEqual(open(key, packed, 'creds.json'), SECRET_LIKE);
});

test('الناتج ليس JSON ولا يحتوي القيمة نصاً', () => {
  const key = Buffer.alloc(32, 7);
  const packed = seal(key, SECRET_LIKE, 'creds.json');
  const asText = packed.toString('utf8');
  assert.equal(looksLikePlainJson(packed), false);
  assert.ok(!asText.includes('privkey-looking-material'));
  assert.ok(!asText.includes('82540715106362'));
});

test('AAD يربط الملف بمكانه: النقل إلى اسم آخر يُفشل', () => {
  const key = Buffer.alloc(32, 7);
  const packed = seal(key, SECRET_LIKE, 'creds.json');
  assert.throws(() => open(key, packed, 'pre-key-1.json'));
});

test('مفتاح خاطئ يُفشل بدل أن يُرجع بيانات فاسدة', () => {
  const a = Buffer.alloc(32, 1);
  const b = Buffer.alloc(32, 2);
  const packed = seal(a, SECRET_LIKE, 'creds.json');
  assert.throws(() => open(b, packed, 'creds.json'));
});

test('تلاعب بايت واحد يُكتشف (GCM)', () => {
  const key = Buffer.alloc(32, 7);
  const packed = seal(key, SECRET_LIKE, 'creds.json');
  packed[packed.length - 1] ^= 0x01;
  assert.throws(() => open(key, packed, 'creds.json'));
});

test('looksLikePlainJson يميّز ملفات النسخة القديمة', () => {
  assert.equal(looksLikePlainJson(Buffer.from('{"a":1}', 'utf8')), true);
  assert.equal(looksLikePlainJson(Buffer.from('[1,2]', 'utf8')), true);
  assert.equal(looksLikePlainJson(seal(Buffer.alloc(32, 7), SECRET_LIKE, 'x')), false);
  assert.equal(looksLikePlainJson(Buffer.alloc(0)), false);
});

test('مفتاح الجلسة عشوائي بطول 32', () => {
  const k = Buffer.from(generateSessionKey(), 'base64');
  assert.equal(k.length, 32);
  assert.notEqual(generateSessionKey(), generateSessionKey());
});

test('الملف المشفَّر على القرد لا يُقرأ كنص', () => {
  const key = Buffer.alloc(32, 7);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-'));
  const f = path.join(dir, 'creds.json');
  fs.writeFileSync(f, seal(key, SECRET_LIKE, 'creds.json'), { mode: 0o600 });
  const raw = fs.readFileSync(f);
  assert.equal(looksLikePlainJson(raw), false);
  assert.ok(!raw.toString('utf8').includes('privkey'));
  fs.rmSync(dir, { recursive: true, force: true });
});
