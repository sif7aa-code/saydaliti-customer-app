# ربط واتساب + API أكواد دخول

موقع صغير بملف واحد: يربط رقم واتساب عبر **QR** (بدون تطبيق أعمال)، ويصلك
`API` ترسل منه كود دخول إلى تطبيقك، وتتحقق من الكود فتحصل على `token`.

> تنبيه: ربط واتساب عبر Web التلقائي (غير الرسمي) قد يخالف شروط واتساب ويعرّض
> الرقم للحظر. استخدمه على رقم ثانوي للتجربة، ولحساب حقيقي استخدم
> WhatsApp Business Cloud API الرسمي. لا ترسل الأكواد من هذا الخادم بدون
> HTTPS، ولا تحفظ `x-api-key` داخل كود التطبيق المفتوح.

## التشغيل

```bash
npm install
npm start
```

ثم افتح <http://localhost:3000>

أول تشغيل يطبع `x-api-key` في الكونسول (ويُحفظ في `data/keys.json`).

## الربط

1. افتح <http://localhost:3000> وغيّر رمز QR كل 45 ثانية.
2. في الهاتف: واتساب ← **الأجهزة المرتبطة** ← **ربط جهاز**.
3. امسح الرمز. بعدها يظهر الرقم في الصفحة وتصبح جاهزاً للإرسال.

`QR` جديد بدون مسح الجلسة: زر **تحديث رمز QR**. لحذف الجلسة نهائياً:
**فصل الجلسة**.

## الإعدادات (`.env`)

انسخ `.env.example` إلى `.env`:

| المتغير | الافتراضي | الوصف |
| --- | --- | --- |
| `PORT` | `3000` | منفذ السيرفر |
| `APP_API_KEY` | يُولَّد تلقائياً | المفتاح المطلوب في `x-api-key` لتطبيقك |
| `ADMIN_KEY` | فارغ | لو حُدد، تحمي أزرار اللوحة عبر `x-admin-key` |
| `COUNTRY_CODE` | فارغ | مثال `964` — يحوّل `07xxxxxxxx` إلى دولي |
| `BRAND_NAME` | `سنتر الشطرة` | الاسم داخل الرسالة |
| `CODE_LENGTH` | `4` | طول الكود |
| `CODE_TTL_MINUTES` | `5` | صلاحية الكود |
| `RESEND_COOLDOWN_SECONDS` | `60` | أقل مدة بين كودين لنفس الرقم |
| `MAX_CODES_PER_PHONE_PER_HOUR` | `2` | حد لكل رقم |
| `MAX_CODES_TOTAL_PER_HOUR` | `60` | حد عام للسيرفر |
| `MAX_VERIFY_ATTEMPTS` | `5` | محاولات خاطئة قبل إلغاء الكود |
| `WHATSAPP_DRY_RUN` | فارغ | `1` = لا إرسال حقيقي، الكود يظهر في السجل (اختبار) |
| `COUNTRY_CODE` | — | ضروري للتحويل من رقم محلي |

## نص الرسالة

```
كود التحقق في تطبيق سنتر الشطرة هو 3425
صالح لمدة 5 دقائق. لا تشاركه مع أحد.
```

## تشفير الجلسات على القرص

جلسة واتساب (`data/session/*.json`) هي **الجهاز كله**: لو سُرقت، فُصلت
الأجهزة المرتبطة فوراً مع رقمك. لذلك تُكتب كل ملفات الجلسة مشفَّرة
**AES-256-GCM**، واسم الملف يُستخدم كـ`AAD` فلا يصلح نقل ملف من مكانه.

**هذا ليس خيار Baileys.** `useMultiFileAuthState` في الإصدار 6.7.24 تأخذ
مجلداً فقط وتكتب `JSON.stringify` نصاً صريحاً. البديل في
`src/encrypted-auth-state.js` بنفس الواجهة تماماً.

| المتغير | مطلوب | الوظيفة |
| --- | --- | --- |
| `WA_SESSION_KEY` | **نعم** | 32 بايت base64. بدونه **يرفض الخادم الإقلاع** (fail closed) |
| `WA_KEYS_KEY` | لا | يشفّر `data/keys.json` (مفتاح توقيع رموز الدخول) |

توليد مفتاح:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
```

### قبل أول تشغيل بعد التحديث

1. **انسخ مجلد `data/session` احتياطياً Somewhere آمن** — الترحيل
   يحوّل 74 ملفاً ولا يمكن التراجع عنه بالمفتاح نفسه.
2. ضع المفتاح في مدير كلمات مرور. **ضياعه = فقدان جلسة واتساب**،
   ولا يمكن فكّ أي نسخة احتياطية أُخذت قبله.

### الترحيل

عند الإقلاع الأول يفحص المجلد ويشفّر كل ملف JSON قديم ويعدّله في مكانه
(كتابة ذرّية عبر `.tmp` ثم `rename`). يظهر في السجل:

```
تم تشفير 74 ملف جلسة على القرص.
```

لا تحتاج مسح `QR` ولا إعادة ربط.

### سلوك الفشل

- `creds.json` موجودة والمفتاح خاطئ ⇒ **يرفض الإقلاع** برسالة صريحة.
  (الرجوع إلى جلسة جديدة كان سيعيد ربط الجهاز ويلغي الجلسة الأصلية
  بصمت — خسارة غير مرئية.)
- ملف معدَّل بايت واحد ⇒ `GCM` يفشل عند الفك، ويُعتبر الملف تالفاً.
- إعادة الربط من الصفر: احذف `SESSION_DIR` **صراحةً**.

### ⚠ اتصالات غير مشفّرة

الـAPI يعمل الآن على `http://162.35.126.155` — أي أن `x-api-key` ورموز
الدخول تمرّ **نصاً صريحاً** على الشبكة. تشفير القرص لا يحمي من ذلك.
ضع الخادم خلف Nginx مع شهادة TLS قبل الاعتماد على هذا عَملياً.

## الثبات

الجلسة لا تُفصل تلقائياً: إعادة اتصال تصاعدية (3 ث ← 20 ث)، مراقب كل 45 ثانية
يعيد التشغيل إذا توقف الاتصال، وpm2 + systemd يعيد تشغيل السيرفر بعد أي انقطاع.
لو انتهت صلاحية الجلسة (401/403) يُمسح سجل الجلسة ويُولَّد رمز QR جديد تلقائياً.

## تجربة قبل الربط

```bash
WHATSAPP_DRY_RUN=1 npm start
```

لا يُرسل شيء فعلياً، ويظهر الكود في الكونسول، فتختبر `verify` و`session`
فوراً. أزل المتغير بعد التأكد.

## الاختبارات

```bash
npm test
```

## المسارات

| الطريقة | المسار | الترويسة | الوظيفة |
| --- | --- | --- | --- |
| GET | `/api/status` | — | حالة واتساب + إحصاءات |
| GET | `/api/panel-key` | من `localhost` فقط | مفتاح الـ API للوحة التحكم |
| POST | `/api/auth/code` | `x-api-key` | `{ phone }` → إرسال كود |
| POST | `/api/auth/verify` | `x-api-key` | `{ phone, code }` → `{ token }` |
| GET | `/api/auth/session` | `x-api-key` + `Authorization` | فحص التوكن |
| POST | `/api/qr/refresh` | `x-admin-key` | رمز QR جديد |
| POST | `/api/logout` | `x-admin-key` | مسح الجلسة |
| GET | `/api/logs` | `x-admin-key` | سجل الأحداث |

### مثال

```bash
# المفتاح يُطبع في سجل الإقلاع. إن ضبطت WA_KEYS_KEY صارت المفاتيح
# في data/keys.enc مشفّرة، فاقرأها بالك مفتاحك لا بـjson:
KEY=$(grep '^x-api-key' /var/log/qrlogn.log | tail -1 | awk '{print $3}')
# أو (بلا تشفير):
KEY=$(node -e "console.log(JSON.parse(require('fs').readFileSync('./data/keys.json')).apiKey)")

curl -X POST http://localhost:3000/api/auth/code \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"phone":"9647700000000"}'

curl -X POST http://localhost:3000/api/auth/verify \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"phone":"9647700000000","code":"123456"}'
```

## ربط تطبيقك (Dart / Flutter)

`lib/services/whatsapp_login_service.dart`:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class WhatsappLogin {
  WhatsappLogin({required this.baseUrl, required this.apiKey});

  final String baseUrl;   // مثال: https://your-host.com
  final String apiKey;
  static const _codePath = '/api/auth/code';
  static const _verifyPath = '/api/auth/verify';

  Future<void> sendCode(String phone) async {
    final res = await http.post(
      Uri.parse('$baseUrl$_codePath'),
      headers: {'x-api-key': apiKey, 'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone}),
    );
    if (res.statusCode != 200) throw Exception('send_failed: ${res.body}');
  }

  Future<String?> verify(String phone, String code) async {
    final res = await http.post(
      Uri.parse('$baseUrl$_verifyPath'),
      headers: {'x-api-key': apiKey, 'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone, 'code': code}),
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body)['token'] as String?;
  }
}
```

ثم في شاشة الدخول: زر «إرسال كود» ← `sendCode`، وحقل لإدخال الكود ←
`verify`، وبعدها تحقّق من `token` عبر
`GET /api/auth/session` واحفظه في `shared_preferences` (أو استبدله
بجلسة Supabase لديك).

## النشر

- شغّله عبر `pm2` أو `systemd`، وExpo/Vercel لا يناسب (يحتاج عملية مستمرة
  واتصال خارجي).
- ضعه خلف Nginx + شهادة SSL، و`COUNTRY_CODE` والاسم في `.env`.
- بيانات الجلسة في `data/session` مشفّرة — لا تحذفها إلا عمداً، واحتفظ
  بـ`WA_SESSION_KEY` في مدير كلمات مرور خارج السيرفر.
