import crypto from 'node:crypto';

const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;

/**
 * مفتاح تشفير جلسات واتساب — 32 بايت من `WA_SESSION_KEY` في .env.
 *
 * ★ لماذا لا يُولَّد تلقائياً ويُحفظ في مجلد البيانات:
 *   لو كان المفتاح بجوار النصوص المشفّرة على القرص نفسه، فمن يقرأ
 *   المجلد يقرأ الاثنين ويفكّ كل شيء — فيصبح التشفير زينة لا حماية.
 *   لذلك: لا مفتاح = لا تشغيل (fail closed)، والمفتاح يُعطى من البيئة
 *   أو من مدير أسرار (systemd EnvironmentFile, ~/.env بصلاحيات 600).
 */
export function loadSessionKey() {
  const raw = String(process.env.WA_SESSION_KEY || '').trim();
  if (!raw) {
    throw new Error(
      'WA_SESSION_KEY غير مضبوط. شغّل:  node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64\'))"  ' +
        'ثم ضع الناتج في .env كـ WA_SESSION_KEY=... (بصلاحيات 600). ' +
        'التطبيق يرفض العمل بدونه عمداً حتى لا تُكتب الجلسات بلا تشفير.',
    );
  }

  const key = Buffer.from(raw, 'base64');
  if (key.length !== KEY_BYTES) {
    throw new Error(
      `WA_SESSION_KEY يجب أن يكون ${KEY_BYTES} بايت (base64 بطول 44). الطول الحالي: ${key.length}.`,
    );
  }
  return key;
}

/** مولّد المفتاح — يُطبع مرة واحدة ويُحفظ في .env. */
export function generateSessionKey() {
  return crypto.randomBytes(KEY_BYTES).toString('base64');
}

/**
 * ختم كائن AES-256-GCM. AAD = اسم الملف ⇒ الملف لا يُنقل من مكانه:
 * نسخ `pre-key-3.json` إلى `creds.json` يُفشل المصادقة.
 */
export function seal(key, value, aad, reviver) {
  const iv = crypto.randomBytes(IV_BYTES);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  if (aad) cipher.setAAD(Buffer.from(String(aad), 'utf8'));
  const json = reviver ? JSON.stringify(value, reviver) : JSON.stringify(value);
  const body = cipher.update(json, 'utf8');
  // ★ final() قبل getAuthTag() إلزامي: بدونه يرمي Node
  //   ERR_CRYPTO_INVALID_STATE ولا يُنتج وسماً أبداً.
  const tail = cipher.final();
  const tag = cipher.getAuthTag();
  // iv(12) + tag(16) + ciphertext ⇒ يبان الطول من الملف بلا ترويسة.
  return Buffer.concat([iv, tag, body, tail]);
}

/** فكّ الختم. يرمي Error إن كان المفتار خاطئاً أو الملف معدَّلاً. */
export function open(key, buffer, aad, replacer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < IV_BYTES + TAG_BYTES) {
    throw new Error('ملف مشفَّر تالف أو قصير');
  }
  const iv = buffer.subarray(0, IV_BYTES);
  const tag = buffer.subarray(IV_BYTES, IV_BYTES + TAG_BYTES);
  const body = buffer.subarray(IV_BYTES + TAG_BYTES);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  if (aad) decipher.setAAD(Buffer.from(String(aad), 'utf8'));
  decipher.setAuthTag(tag);
  const json = decipher.update(body, 'utf8') + decipher.final('utf8');
  return replacer ? JSON.parse(json, replacer) : JSON.parse(json);
}

/** هل هذه البايتات نص JSON؟ (تمييز ملفات النسخة القديمة قبل الترحيل) */
export function looksLikePlainJson(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) return false;
  const first = buffer[0];
  // JSON يبدأ بـ { أو [ أو مسافة/سطر جديد — وOur base64 يبدأ بحرف أو رقم.
  if (first !== 0x7b && first !== 0x5b) return false;
  try {
    JSON.parse(buffer.toString('utf8'));
    return true;
  } catch {
    return false;
  }
}
