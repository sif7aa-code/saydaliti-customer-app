import fs from 'node:fs/promises';
import path from 'node:path';

import { BufferJSON, initAuthCreds, proto } from '@whiskeysockets/baileys';

import { looksLikePlainJson, open, seal } from './session-crypto.js';

const fixFileName = (file) => file?.replace(/\//g, '__')?.replace(/:/g, '-');

/** 0700 للمجلد و0600 للملف: لا يقرأه إلا صاحب العملية. */
async function tighten(file) {
  try {
    await fs.chmod(file, 0o600);
  } catch {}
}

/**
 * نفس واجهة Baileys تماماً، لكن كل ملف يُكتب مشفَّراً AES-256-GCM.
 *
 * ★ لماذا لم نستخدم useMultiFileAuthState من Baileys:
 *   في 6.7.24 هي `(folder) => …` بلا أي خيار تشفير، وتكتب
 *   `JSON.stringify(data)` نصاً صريحاً. أي نسخ احتياطية أو رفع للمجلد
 *   تسحب جلسة واتساب قابلة للاستخدام فوراً.
 *
 * ★ الترحيل: ملفات النسخة القديمة JSON صريحة. عند القراءة تُفتح،
 *   وتُعاد كتابتها مشفّرة، ثم تُحذف الأصلية — فلا يضيع الربط ولا
 *   تبقى نسخة نصية على القرص.
 */
export async function useEncryptedAuthState(folder, { key, log = () => {} }) {
  await fs.mkdir(folder, { recursive: true });
  try {
    await fs.chmod(folder, 0o700);
  } catch {}

  const cache = new Map();
  let migrated = 0;

  const pathOf = (file) => path.join(folder, fixFileName(file));

  const writeData = async (data, file) => {
    const filePath = pathOf(file);
    const tmp = `${filePath}.tmp`;
    // نكتب .tmp ثم نُعيد التسمية: الكتابة المباشرة تترك ملفاً
    // نصف مكتوب لو انقطعت الكهرباء، وهو ما يعني فقدان الجلسة.
    // ★ BufferJSON.replacer: يحوّل Buffer إلى {type:'Buffer',data:[]}
    //   قبل التشفير. فبدونه يخرج المفاتيح كـJSON غير متوافق
    //   وتُفقد بايتاتها ⇒ رفض libsignal.
    await fs.writeFile(tmp, seal(key, data, file, BufferJSON.replacer), { mode: 0o600 });
    await fs.rename(tmp, filePath);
    await tighten(filePath);
  };

  const readData = async (file) => {
    const filePath = pathOf(file);
    let raw;
    try {
      raw = await fs.readFile(filePath);
    } catch {
      return null;
    }

    if (looksLikePlainJson(raw)) {
      let value;
      try {
        // ★ reviver هنا أيضاً: نفس سبب الفك أعلاه. الترقيم يقرأ
        //   الملفات القديمة، وهي التي تحمل مفاتيح Buffer.
        value = JSON.parse(raw.toString('utf8'), BufferJSON.reviver);
      } catch {
        return null;
      }
      // ★ لا unlink بعد writeData: الكتابة تتم عبر .tmp ثم rename
      //   فوق النصية، فـ unlink هنا كان يحذف المشفَّر نفسه
      //   ويمحو creds.json ⇒ ضياع الجلسة كلياً.
      await writeData(value, file);
      migrated += 1;
      log(`شُفِّرت جلسة قديمة: ${file}`);
      return value;
    }

    try {
      // ★ BufferJSON.reviver يعيد بناء الـBuffers. بدونه تخرج
      //   كائنات عادية فيرفض libsignal المفتاح:
      //   "list[1] must be Buffer or Uint8Array. Received Object".
      return open(key, raw, file, BufferJSON.reviver);
    } catch {
      // مفتاح خاطئ أو ملف معدَّل — نُبطله بدل تمرير بيانات فاسدة.
      log(`تعذّر فكّ ${file} — يُعتبر تالفاً`);
      return null;
    }
  };

  const removeData = async (file) => {
    cache.delete(file);
    await fs.unlink(pathOf(file)).catch(() => {});
  };

  let corrupt = null;

  const credsFromDisk = await readData('creds.json');
  // ★ لو وُجدت creds.json على القرص ولم تُفكّ ⇒ الجلسة موجودة لكن
  //   المفتاح خاطئ. الرجوع إلى initAuthCreds() هنا يربط الجهاز من
  //   جديد بصمت ويلغي الجلسة الأصلية على واتساب — خسارة صامتة.
  //   نفشل صريحاً بدل ذلك.
  if (credsFromDisk === null) {
    try {
      await fs.access(pathOf('creds.json'));
      corrupt = 'creds.json';
    } catch {}
  }
  if (corrupt) {
    throw new Error(
      `تعذّر فكّ ${corrupt}: المفتاح الحالي لا يطابق أو الملف معدَّل. ` +
        'الرجوع إلى initAuthCreds هنا كان سيعيد ربط الجهاز من جديد ويلغي ' +
        'الجلسة الأصلية على واتساب بصمت. تحقّق من WA_SESSION_KEY — ' +
        'وإن أردت إعادة الربط من الصفر فاحذف مجلد SESSION_DIR صراحةً.',
    );
  }

  const creds = credsFromDisk || initAuthCreds();

  /**
   * ★ الجولة الكاملة: readData كسول، فمفاتيح pre-key وsender-key تبقى
   *   نصّية على القرص حتى لو لم يقرأها Baileys بعد. نلتفّ على المجلد
   *   عند كل إقلاع ونشفّر ما وجد، فلا تبقى أي نسخة صريحة تُسخَّب.
   */
  const migrateAll = async () => {
    let files;
    try {
      files = await fs.readdir(folder);
    } catch {
      return 0;
    }
    const before = migrated;
    for (const f of files) {
      if (f.endsWith('.tmp')) {
        await fs.unlink(path.join(folder, f)).catch(() => {});
        continue;
      }
      if (!f.endsWith('.json')) continue;
      const filePath = path.join(folder, f);
      let raw;
      try {
        raw = await fs.readFile(filePath);
      } catch {
        continue;
      }
      if (!looksLikePlainJson(raw)) continue;
      const value = await readData(f);
      if (value === null) {
        await fs.unlink(filePath).catch(() => {});
      }
    }
    return migrated - before;
  };

  return {
    get migratedFiles() {
      return migrated;
    },
    migrateAll,
    state: {
      creds,
      keys: {
        get: async (type, ids) => {
          const data = {};
          await Promise.all(
            ids.map(async (id) => {
              // ★ Baileys يمرّر اسم الملف مع الامتداد
              //   (`${type}-${id}.json`). حذفنا الامتداد ⇒ كل مفتاح يُكتب
              //   في `pre-key-1` بينما get يطلب `pre-key-1.json` ⇒ مفاتيح
              //   مفقودة وAAD لا يطابق ⇒ فكّ يفشل.
              const file = `${type}-${id}.json`;
              let value;
              if (cache.has(file)) {
                value = cache.get(file);
              } else {
                value = await readData(file);
                cache.set(file, value);
              }
              // نفس ما يفعله Baileys: مفتاح مزامنة الحالة يحتاج
              // تحويل proto وإلا رفضه libsignal.
              if (type === 'app-state-sync-key' && value) {
                value = proto.Message.AppStateSyncKeyData.fromObject(value);
              }
              data[id] = value;
            }),
          );
          return data;
        },
        set: async (data) => {
          const tasks = [];
          for (const category in data) {
            for (const id in data[category]) {
              const value = data[category][id];
              const file = `${category}-${id}.json`;
              if (value) {
                cache.set(file, value);
                tasks.push(writeData(value, file));
              } else {
                tasks.push(removeData(file));
              }
            }
          }
          await Promise.all(tasks);
        },
      },
    },
    saveCreds: async () => writeData(creds, 'creds.json'),
  };
}
