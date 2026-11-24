/**
 * يفكّ تشفير creds.json ويعرض حالته: هل الربط باقٍ؟ وهل القيم
 * كائنات أم Buffers؟ (الكائنات = طبقتنا لا تستعيد Buffers ⇒ خطأ)
 *
 * node test/inspect-creds.mjs
 */
import 'dotenv/config';

import { BufferJSON } from '@whiskeysockets/baileys';
import fs from 'node:fs';
import path from 'node:path';

import { open, looksLikePlainJson, loadSessionKey } from '../src/session-crypto.js';

const dir = process.env.SESSION_DIR || './data/session';
const file = path.join(dir, 'creds.json');
const raw = fs.readFileSync(file);

console.log('file        =', file);
console.log('size        =', raw.length);
console.log('encrypted   =', !looksLikePlainJson(raw));

if (looksLikePlainJson(raw)) {
  console.log('نص صريح — لا حاجة لفك');
  process.exit(0);
}

let creds;
let viaReviver = true;
try {
  creds = open(loadSessionKey(), raw, 'creds.json', BufferJSON.reviver);
} catch (e) {
  console.log('فشل الفك مع reviver =', e.message);
  try {
    creds = open(loadSessionKey(), raw, 'creds.json');
    viaReviver = false;
  } catch (e2) {
    console.log('فشل الفك   =', e2.message);
    console.log('⇒ المفتاح لا يطابق، أو الملف تالف.');
    process.exit(1);
  }
}

const kind = (v) =>
  v === null || v === undefined ? 'null' : Array.isArray(v) ? `Array(${v.length})` : typeof v;

console.log('---');
console.log('me          =', creds.me?.id ?? '(null)');
console.log('registered  =', creds.registered);
console.log('deviceId    =', String(creds.deviceId ?? '').slice(0, 12));
console.log('registeredTimestamp =', creds.registeredTimestamp);
console.log('--- أنواع القيم ---');
for (const k of ['advSecretKey', 'advAccountSignatureKey', 'noiseKey', 'signedIdentityKey', 'signedPreKey']) {
  const v = creds[k];
  if (v === undefined) { console.log(`${k.padEnd(24)}= (مفقود)`); continue; }
  if (v && typeof v === 'object') {
    const parts = Object.entries(v).map(([kk, vv]) => `${kk}:${kind(vv)}`).join(' ');
    console.log(`${k.padEnd(24)}= ${parts}`);
  } else {
    console.log(`${k.padEnd(24)}= ${kind(v)}`);
  }
}
console.log('---');
console.log('viaReviver       =', viaReviver);
const noisePriv = creds.noiseKey?.private;
console.log('noiseKey.private is Buffer =', Buffer.isBuffer(noisePriv));
console.log('noiseKey.private bytes     =', Buffer.isBuffer(noisePriv) ? noisePriv.length : 'n/a');
console.log('identityKey.private is Buffer =', Buffer.isBuffer(creds.signedIdentityKey?.private));
console.log('preKey.keyPair.private is Buffer =', Buffer.isBuffer(creds.signedPreKey?.keyPair?.private));
