import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { looksLikePlainJson, open, seal } from './session-crypto.js';

const KEYS_KEY_BYTES = 32;

const b64url = (buf) =>
  Buffer.from(buf)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

const fromB64url = (str) =>
  Buffer.from(String(str).replace(/-/g, '+').replace(/_/g, '/'), 'base64');

/**
 * مفتاح تشفير `keys.json` — منفصل عن مفتاح الجلسة عمداً.
 * ضياع أحدهما لا يُفقد الاخر، وتسريب أحدهما لا يُفكّ الآخر.
 * غير مضبوط ⇒ نتابع بالنص الصريح مع تحذير (كي لا تنقطع اللوحة
 * على سيرفرٍ لم يُضبط بعد) بدل الرفض الكامل.
 */
function loadKeysKey() {
  const raw = String(process.env.WA_KEYS_KEY || '').trim();
  if (!raw) return null;
  const key = Buffer.from(raw, 'base64');
  if (key.length !== KEYS_KEY_BYTES) {
    throw new Error(
      `WA_KEYS_KEY يجب أن يكون ${KEYS_KEY_BYTES} بايت (base64 بطول 44).`,
    );
  }
  return key;
}

export class AuthKeys {
  constructor({ dataDir }) {
    this.dataDir = dataDir;
    this.apiKey = '';
    this.secret = '';
    this.ttlMs = 30 * 24 * 60 * 60 * 1000;
    this.plaintext = false;
  }

  init() {
    fs.mkdirSync(this.dataDir, { recursive: true });
    try {
      fs.chmodSync(this.dataDir, 0o700);
    } catch {}

    const file = path.join(this.dataDir, 'keys.json');
    let data = null;
    try {
      data = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {}

    if (!data?.apiKey || !data?.secret) {
      data = {
        apiKey: process.env.APP_API_KEY || crypto.randomBytes(24).toString('hex'),
        secret: crypto.randomBytes(32).toString('hex'),
        createdAt: Date.now(),
      };
      // ★ لا بد من الكتابة: حذفها كان يجعل init() يولّد مفتاحاً جديداً
      //   كل إقلاع، فيتغيّر x-api-key ويتعطّل التطبيق بعد كل إعادة تشغيل.
      fs.writeFileSync(file, JSON.stringify(data, null, 2), { mode: 0o600 });
    } else {
      // ★ نسخ قديمة كُتبت بصلاحيات 644، فتبقى مقروءة من أي مستخدم
      //   على السيرفر. نضيّقها الآن.
      try {
        fs.chmodSync(file, 0o600);
      } catch {}
    }
    this.plaintext = true;

    // ★ `secret` هو مفتاح توقيع كل رموز الدخول. لو قرأه أحد ⇒ يصنع
    //   رمزاً لأي رقم هاتف ويمرّ على /api/auth/session. لذلك نُخفيه
    //   هو أيضاً، بنفس AES-256-GCM، وبمفتاح مستقل عن مفتاح الجلسة.
    const sealKey = loadKeysKey();
    const at = path.join(this.dataDir, 'keys.enc');
    if (sealKey) {
      const recovered = this._readSealed(sealKey, at);
      if (recovered) {
        data = recovered;
        this.plaintext = false;
      } else {
        this._writeSealed(sealKey, at, data);
      }
    } else if (process.env.WA_KEYS_KEY) {
      throw new Error(
        'WA_KEYS_KEY مضبوط لكن تعذّر فكّ keys.enc. إن كان هذا أول تشغيل ' +
          'أو تغيّر المفتاح، احذف keys.enc (سيُعاد توليد المفاتيح).',
      );
    }

    if (this.plaintext) {
      console.warn(
        '\n  ⚠ keys.json يُخزَّن نصاً صريحاً: مفتاح توقيع رموز الدخول ' +
          'قابل للقراءة من أي مستخدم على السيرفر.\n' +
          '    اضبط WA_KEYS_KEY (32 بايت base64) لتشفيره.\n',
      );
    }

    this.apiKey = data.apiKey;
    this.secret = data.secret;
    return this;
  }

  _readSealed(key, file) {
    try {
      const raw = fs.readFileSync(file);
      if (!looksLikePlainJson(raw)) return open(key, raw, 'keys');
      return null;
    } catch {
      return null;
    }
  }

  _writeSealed(key, file, data) {
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, seal(key, data, 'keys'), { mode: 0o600 });
    fs.renameSync(tmp, file);
    try {
      fs.chmodSync(file, 0o600);
    } catch {}
  }

  checkApiKey(req) {
    const given = req.get('x-api-key') || req.query?.key;
    if (!given) return false;
    const a = Buffer.from(String(given));
    const b = Buffer.from(this.apiKey);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  issueToken(phone) {
    const exp = Date.now() + this.ttlMs;
    const payload = b64url(JSON.stringify({ phone, exp }));
    const sig = b64url(
      crypto.createHmac('sha256', this.secret).update(payload).digest(),
    );
    return `${payload}.${sig}`;
  }

  readToken(token) {
    if (!token || typeof token !== 'string' || !token.includes('.')) return null;
    const [payload, sig] = token.split('.');
    if (!payload || !sig) return null;
    const expected = b64url(
      crypto.createHmac('sha256', this.secret).update(payload).digest(),
    );
    const a = Buffer.from(sig);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    try {
      const data = JSON.parse(fromB64url(payload).toString('utf8'));
      if (!data?.phone || !data?.exp || data.exp < Date.now()) return null;
      return data;
    } catch {
      return null;
    }
  }

  checkToken(req) {
    const header = req.get('authorization') || '';
    const token = header.replace(/^Bearer\s+/i, '') || req.query?.token;
    return this.readToken(token);
  }
}
