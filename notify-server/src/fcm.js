// =====================================================================
//  مُرسِل FCM (Firebase Cloud Messaging) — بإرسال HTTP v1
//  صفر اعتماديات: `node:crypto` فقط.
// =====================================================================
//
//  ★ لماذا كان الإشعار لا يظهر والتطبيق مغلق؟
//    ليس لأن المُرسِل بطيء: لا يوجد مُرسِل أصلاً — `notify-server`
//    كان يبثّ SSE فقط (داخل التطبيق المفتوح)، و`app_settings.
//    push_worker_enabled = '0'` و`push_worker_url` فارغ، أي أن
//    القاعدة لم تكن تنادي أي مُرسِل. التوكنات كانت مسجّلة وسليمة
//    في `push_tokens`؛ الناقص كان الإرسال وحده.
//    فبقي الإشعار يظهر داخل التطبيق (استطلاع مباشر) ويختفي بمجرد
//    إغلاقه — وهو العطل نفسه بالضبط.
//
//  ★ ما يفعله هذا الملف: يرسل عبر FCM HTTP v1 إلى توكنات الجهاز
//    في `push_tokens`، فيستقبله أندرويد **والتطبيق مغلق تماماً**.
//
//  ★ المتطلّب الوحيد: ملف JSON لمفتاح الخدمة (Service Account) من
//    Firebase Console → Project Settings → Service accounts.
//    ضعه في `notify-server/fcm-service-account.json` (أو `FCM_SERVICE_ACCOUNT_FILE`).
//    **ولا ترفعه إلى git** — هو مفتاح توقيع يُسرّب أي حساب.
// =====================================================================

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { ApnsSender } from './apns.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const log = (m) => console.log(`[${new Date().toISOString()}] [fcm] ${m}`);

/**
 * ★★ قنوات أندرويد بأصواتها — لكل نوع حدث قناته كي يُسمع الصوت
 *   الصحيح (نغمة قبول ≠ رفض ≠ تغيّر سعر) حتى والتطبيق مغلق.
 *
 *   كان الإرسال يضبط `channel_id: 'default'` ⇒ كل الأحداث تُسمع
 *   بنغمة واحدة، ويختلط «تم القبول» بـ«تم الرفض» سماعياً.
 *   المعرّفات تطابق ما ينشئه التطبيق (NotifyChannels) وما يستعمله
 *   `tools/push_worker.js` حرفياً.
 */
const CH = {
  new_order: 'strasopa_v2_new_order',
  accepted: 'strasopa_v2_accepted',
  delivering: 'strasopa_v2_delivering',
  rejected: 'strasopa_v2_rejected',
  replaced: 'strasopa_v2_replaced',
  price_changed: 'strasopa_v2_price_changed',
  delivered: 'strasopa_v2_delivered',
  alert: 'strasopa_v2_alert',
};

/** نوع الحدث/النغمة ⇒ قناة أندرويد. مجهول ⇒ قناة التنبيه العامة. */
function channelFor(kind) {
  switch (String(kind || '').trim()) {
    case 'pending':
    case 'new_order':
    case 'driver_request':
      return CH.new_order;
    case 'accepted':
      return CH.accepted;
    case 'delivering':
      return CH.delivering;
    case 'rejected':
    case 'cancelled':
      return CH.rejected;
    case 'item_changed':
    case 'item_replaced':
    case 'item_deleted':
    case 'replaced':
      return CH.replaced;
    case 'price_changed':
      return CH.price_changed;
    case 'delivered':
      return CH.delivered;
    default:
      return CH.alert;
  }
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** يقرأ مفتاح الخدمة من ملف أو من متغيّر بيئة (JSON مضمّن). */
function loadServiceAccount() {
  const inline = String(process.env.FCM_SERVICE_ACCOUNT || '').trim();
  if (inline) {
    try {
      return JSON.parse(inline);
    } catch (e) {
      log(`FCM_SERVICE_ACCOUNT ليس JSON صالحاً: ${e.message}`);
      return null;
    }
  }
  const file =
    String(process.env.FCM_SERVICE_ACCOUNT_FILE || '').trim() ||
    path.join(__dirname, '..', 'fcm-service-account.json');
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    log(`تعذّرت قراءة مفتاح الخدمة (${file}): ${e.message}`);
    return null;
  }
}

/**
 * ★ مفتاح خدمة مشروع **diqarapp** — المشروع الوحيد المرتبط بالإشعارات
 *   الآن (٢٠٢٦-١١-٢٤): تطبيقات أندرويد وiOS والويب كلها فيه.
 *
 *   مفتاح الخدمة مشروعيّ لا تطبيقياً، فالمفتاح نفسه يرسل إلى توكنات
 *   المنصات الثلاث. توكنات أندرويد القديمة (مشروع الشطرة) ترد
 *   UNREGISTERED وتُستبدل عند تثبيت النسخة الجديدة.
 */
function loadWebServiceAccount() {
  const inline = String(process.env.FCM_WEB_SERVICE_ACCOUNT || '').trim();
  if (inline) {
    try {
      return JSON.parse(inline);
    } catch (e) {
      log(`FCM_WEB_SERVICE_ACCOUNT ليس JSON صالحاً: ${e.message}`);
      return null;
    }
  }
  const file =
    String(process.env.FCM_WEB_SERVICE_ACCOUNT_FILE || '').trim() ||
    path.join(__dirname, '..', 'fcm-diqarapp.json');
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    log(`تعذّرت قراءة مفتاح خدمة الويب (${file}): ${e.message}`);
    return null;
  }
}

/**
 * معرّف مشروع Firebase من `android/app/google-services.json`.
 *
 * ★ الغرض تشخيصي أكثر منه وظيفي: نعرف به **أي** مشروع يُتوقّع
 *   المفتاح له، فلا يبقى \"مفتاح غير صالح\" بلا سياق، وللمستخدم
 *   أن يعرف أنه ينظر إلى المشروع الخطأ.
 */
function projectFromAppConfig() {
  const file = path.join(__dirname, '..', '..', 'android', 'app', 'google-services.json');
  try {
    if (!fs.existsSync(file)) return '';
    return String(JSON.parse(fs.readFileSync(file, 'utf8'))?.project_info?.project_id || '');
  } catch {
    return '';
  }
}

export class FcmSender {
  constructor({ onLog = () => {} } = {}) {
    this.onLog = onLog;
    // ★ مفتاح مشروع الشطرة القديم: يبقى على القرص ولا يُستعمل للإرسال
    //   (٢٠٢٦-١١-٢٤) — قراءة تشخيصية فقط، تقديراً لقاعدة «لا تحذف».
    this.sa = loadServiceAccount();
    this.projectId = this.sa?.project_id || projectFromAppConfig();
    // ★ ما ينقص بالضبط — يُطبع عند الإقلاع بدل رسالة غامضة.
    this.missing = [];
    if (!this.sa) this.missing.push('fcm-service-account.json');
    else {
      if (!this.sa.client_email) this.missing.push('client_email');
      if (!this.sa.private_key) this.missing.push('private_key');
      if (!this.sa.project_id) this.missing.push('project_id');
    }
    // ★ مشروع diqarapp: مفتاح الإرسال لكل المنصات وذاكرة توكن مستقلة.
    this.webLink =
      String(process.env.WEB_PUSH_LINK || '').trim() ||
      'https://saydaliti.netlify.app/';
    this.webSa = loadWebServiceAccount();
    this.webProjectId = this.webSa?.project_id || '';
    this.webMissing = [];
    if (!this.webSa) this.webMissing.push('fcm-diqarapp.json');
    else {
      if (!this.webSa.client_email) this.webMissing.push('web.client_email');
      if (!this.webSa.private_key) this.webMissing.push('web.private_key');
    }
    // ★ التوكن يُجلب مرة كل ~٥٥ دقيقة؛ تجديده مع كل إشعار يضيف
    //   رحلة ذهاب وإياب إلى كل رسالة ⇒ تأخير مرئي + حصة API.
    //   المفتاحان يتشاركان الذاكرة بالمفتاح (client_email).
    this._tokenCache = new Map();
    // ★ آيفون: APNs مباشر بمفتاح .p8 — بلا مشروع Firebase.
    this.apns = new ApnsSender({ onLog });
    this.sent = 0;
    this.failed = 0;
    this.skipped = 0;
    // ★★ منع تكرار الإرسال داخل هذا العازل: نفس الجهاز ونفس الحدث
    //   لا يُرسَل مرتين. كان استطلاع `watcher` قد يرى نفس التغيّر
    //   مرتين (تحديثان متتاليان لنفس الصف) فيرسل نسختين، وأندرويد
    //   يعرض إشعارَين بصوتين — وهو عين «التكرار» المشتكى منه.
    this._dedupe = new Map(); // key => timestamp
    this.deduped = 0;
  }

  /** الإرسال الفعلي كله من مفتاح **diqarapp** (أمر الأدمن ٢٠٢٦-١١-٢٤). */
  get enabled() {
    return this.webEnabled;
  }

  /** هل يمكن إرسال أي إشعار (هاتف/ويب/آيفون)؟ */
  get canSend() {
    return this.enabled || this.webEnabled || this.apns.enabled;
  }

  /** هل مفتاح مشروع الويب صالح؟ (توكنات المتصفح تُرسل منه وحده). */
  get webEnabled() {
    return Boolean(
      this.webSa && this.webSa.client_email && this.webSa.private_key && this.webProjectId,
    );
  }

  /** تشخيص مختصر لـ`/api/health` — يعكس مشروع الإرسال الحقيقي (diqarapp). */
  get stats() {
    return {
      fcmEnabled: this.enabled,
      fcmProject: this.webProjectId || null,
      fcmMissing: this.webMissing.length ? this.webMissing : null,
      fcmWebEnabled: this.webEnabled,
      fcmWebProject: this.webProjectId || null,
      fcmWebMissing: this.webMissing.length ? this.webMissing : null,
      fcmSent: this.sent,
      fcmFailed: this.failed,
      fcmSkipped: this.skipped,
      fcmDeduped: this.deduped,
      ...this.apns.stats,
    };
  }

  /** يوقّع JWT (RS256) ويبدّله بـaccess token من Google — لكل مفتاح ذاكرته. */
  async _token(sa) {
    const key = sa.client_email;
    const cached = this._tokenCache.get(key);
    if (cached && Date.now() < cached.expiry - 60_000) {
      return cached.token;
    }
    const now = Math.floor(Date.now() / 1000);
    const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
    const claim = b64url(
      JSON.stringify({
        iss: sa.client_email,
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
        aud: 'https://oauth2.googleapis.com/token',
        iat: now,
        exp: now + 3600,
      }),
    );
    const signer = crypto.createSign('RSA-SHA256');
    signer.update(`${header}.${claim}`);
    const sig = b64url(signer.sign(sa.private_key));

    const res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${header}.${claim}.${sig}`,
      }),
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 300);
      throw new Error(`token ${res.status}: ${body}`);
    }
    const json = await res.json();
    const entry = {
      token: json.access_token,
      expiry: Date.now() + (Number(json.expires_in) || 3600) * 1000,
    };
    this._tokenCache.set(key, entry);
    return entry.token;
  }

  /**
   * إرسال رسالة واحدة إلى توكن جهاز.
   *
   * ★ `notification` **مع** `data`: وجود `notification` يعني أن نظام
   *   أندرويد يعرض الإشعار بنفسه حتى لو قُتل التطبيق ولا حاجة
   *   لمعالج خلفي — وهذا ما يجعل الوصول فورياً وموثوقاً.
   *   والبيانات تُمرَّر معه ليعرف التطبيق أين يذهب عند الضغط.
   *
   * ★ `priority: high` يمنع تاخّي التوصيل في خطة طاقة ROI.Battery
   *   Saver على أجهزة زبائننا — وهو أخطر سبب لتأخّر إشعار.
   *
   * ★ `image` تُقبل ولا تُستعمل: الإشعار نصّي بلا أي صورة (أمر الأدمن
   *   ٢٠٢٦-١١-٠٦)، فلا شعار داخل أيقونة الإشعار على الهاتف.
   */
  async send(token, { title, body, data = {}, image = '' }, opts = {}) {
    // ★★ ٢٠٢٦-١١-٢٤ (أمر الأدمن): كل المنصات — أندرويد وآيفون وويب —
    //   تُرسل من مشروع **diqarapp** وحده، ولا يُربط شيء بحساب الشطرة
    //   القديم. توكنات التطبيقات القديمة تموت وتُستبدل تلقائياً عند
    //   تثبيت النسخة المبنية على ملف الإعداد الجديد.
    //   ★ آيفون يبقى له مسار APNs خام للجسر الأصلي.
    const platform = String(opts.platform || 'android').trim().toLowerCase();
    const isWeb = platform === 'web';
    const isIos = platform === 'ios';
    // ★ توكن APNs خام (64 خانة hex) من الجسر الأصلي ⇒ APNs مباشر
    //   بمفتاح .p8 (المنع والتكرار داخل ApnsSender).
    const rawApns = isIos && /^[0-9a-f]{64}$/i.test(String(token || ''));
    if (rawApns) {
      return this.apns.send(token, { title, body, data });
    }
    const sa = this.webSa;
    const projectId = this.webProjectId;
    if (!this.webEnabled) {
      this.skipped += 1;
      return false;
    }
    if (!token) return false;

    // ★★ نفس الجهاز + نفس الطلب + نفس النوع = رسالة واحدة خلال
    //   دقيقتين. (itemId **ليس** في المفتاح: كل تغييرات الأصناف في
    //   الطلب الواحد حدث واحد `item_changed` عند التطبيق، فإرسال
    //   ثلاث نغمات لثلاثة أصناف تبديلها مرة واحدة خطأ.)
    //
    //   ★ `rowId` أولاً: صفّ الإشعار العام (كود خصم، محفظة، إعلان،
    //   حجز دكتور) بلا `orderId`، فلو بقي المفتاح (نوع + فارغ)
    //   لابتلع الثانيَين صفّان مختلفان حدثان مختلفان خلال الدقيقتين
    //   — صوت واحد بدل صوتين. والمُكرَّر هنا محكوم سلفاً بوسم
    //   `pushed_at` في القاعدة، فلا حاجة لعازل أوسع.
    const dedupeKey = [
      token,
      data.rowId || data.orderId || '',
      data.type || data.sound || data.status || '',
    ].join('|');
    const now = Date.now();
    const seenAt = this._dedupe.get(dedupeKey);
    if (seenAt && now - seenAt < 120000) {
      this.deduped += 1;
      return false;
    }
    this._dedupe.set(dedupeKey, now);
    if (this._dedupe.size > 500) {
      for (const [k, t] of this._dedupe) {
        if (now - t > 120000) this._dedupe.delete(k);
      }
      if (this._dedupe.size > 2000) this._dedupe.clear();
    }

    try {
      const accessToken = await this._token(sa);
      // ★★ لا صورة ولا شعار في الإشعار إطلاقاً (أمر الأدمن ٢٠٢٦-١١-٠٦):
      //   كان `image` يُركَّب كصورة كبيرة في شريط الإشعارات، فظهر
      //   شعارٌ داخل أيقونة الإشعار. أيقونة الشريط تبقى شاحنة
      //   التطبيق (`ic_stat_notification`) وحدها؛ الحجة `image`
      //   بقيت في التوقيع ولا تُستعمل — فلا لمس لمسار الإرسال.
      const base = {
        token,
        notification: {
          title: title || 'إشعار جديد',
          body: body || '',
        },
        data: Object.fromEntries(
          Object.entries({
            ...data,
            title: title || '',
            body: body || '',
          }).map(([k, v]) => [k, String(v ?? '')]),
        ),
      };
      const message = {
        message: isWeb
          ? {
              ...base,
              // ★ الويب: أولوية عالية + عمر قصير، ورابط النقر يفتح
              //   التطبيق إن كان مغلقاً. العنوان والنص يعرضهما عامل
              //   الخدمة (`firebase-messaging-sw.js`).
              webpush: {
                headers: {
                  Urgency: 'high',
                  TTL: '600',
                },
                notification: {
                  title: title || 'إشعار جديد',
                  body: body || '',
                  icon: '/icons/Icon-192.png',
                },
                fcm_options: {
                  link: this.webLink,
                },
              },
            }
          : isIos
            ? {
                ...base,
                // ★ آيفون عبر Firebase: أولوية 10 وصوت نظام افتراضي؛
                //   الـ`notification` أعلاه يكفي لعرض التنبيه والتطبيق
                //   مغلق، و`aps` يضمن الصوت.
                apns: {
                  headers: { 'apns-priority': '10' },
                  payload: {
                    aps: {
                      alert: {
                        title: title || 'إشعار جديد',
                        body: body || '',
                      },
                      sound: 'default',
                    },
                  },
                },
              }
            : {
                ...base,
                android: {
                  priority: 'high',
                  // ★★ قناة الحدث بصوته: النغمة تُشتق من `sound` (نفس خريطة
                  //   التطبيق) بدل `'default'` الذي كان يجعل كل الأحداث
                  //   تُسمع بنغمة واحدة.
                  notification: {
                    sound: 'default',
                    channel_id: channelFor(data.sound || data.type || data.status),
                  },
                  // ★ عمر قصير: إن تأخّرت الرسالة (بطارية/شبكة) أكثر من
                  //   ١٠ دقائق فخبرُها صار قديماً — وطابور القاعدة يعرضها
                  //   عند أول اتصال، فلا نخاطر بنغمة متأخّرة عن موعدها.
                  ttl: '600s',
                },
              },
      };
      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(message),
        },
      );
      if (res.ok) {
        this.sent += 1;
        return true;
      }
      const bodyText = (await res.text()).slice(0, 300);
      // ★ 404/UNREGISTERED: التوكن ميت (إعادة تثبيت/مسح بيانات).
      //   لا إعادة محاولة — بل نُبلغ المُنبّه ليمسح السجل.
      this.failed += 1;
      this.onLog(`فشل الإرسال ${res.status}: ${bodyText}`);
      return false;
    } catch (e) {
      this.failed += 1;
      this.onLog(`استثناء إرسال: ${e?.message || e}`);
      return false;
    }
  }
}