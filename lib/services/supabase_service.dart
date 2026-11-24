import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/secrets.dart';
import '../core/utils/account_name.dart';
import 'admin_password_session.dart';
import 'api_metrics.dart';
import 'notification_dedup.dart';
import 'notification_sound.dart';
import 'request_health.dart';
import 'status_center.dart';

/// نتيجة التحقق من وجود مستخدم في قاعدة البيانات.
enum UserLookupResult { found, notFound, error }

/// نتيجة تحديث حالة طلب من مندوب:
/// - success: تم التحديث بنجاح.
/// - conflict: الطلب تغيّر بسبب مندوب آخر.
/// - failed: تعذّر الاتصال أو خطأ في السيرفر.
enum OrderUpdateResult { success, conflict, failed }

/// نتيجة تسجيل طلب ممنوح نقاطه:
/// - awarded: سُجّل ومنح 10 نقاط.
/// - already: مسجّل سابقاً (ممنوع التكرار).
/// - failed: تعذّر الوصول للسيرفر.
enum RewardRecordStatus { awarded, already, failed }

/// نتيجة تحديث حالة طلب مع الوقت الحقيقي الذي حدثت فيه.
class OrderUpdate {
  const OrderUpdate(this.result, {this.at, this.status});

  final OrderUpdateResult result;
  final String? at;
  final String? status;

  bool get isSuccess => result == OrderUpdateResult.success;
}

/// نتيجة تسجيل حساب جديد.
class RegisterResult {
  const RegisterResult({
    required this.created,
    this.error,
    this.token,
    this.name,
  });

  final bool created;
  final String? error;

  /// التوكن الموقّع الذي أعادته `register_user` — بلاه تفشل كل
  /// طلبات المستخدم التالية بـ401.
  final String? token;

  /// الاسم كما خزّنته القاعدة (قد يكون مطبَّعاً).
  final String? name;
}

/// رفض من PostgREST عند استدعاء دالة: يحمل رقم الحالة وسبب الخادم
/// واسم الدالة. يبقى نص الخطأ مقروءاً بدل ابتلاعه.
class PostgrestFailure implements Exception {
  PostgrestFailure(this.statusCode, this.detail, this.fn);

  final int statusCode;
  final String detail;
  final String fn;

  bool get isAuthError =>
      statusCode == 401 || statusCode == 403 || statusCode == 28000;

  @override
  String toString() => 'RPC $fn → $statusCode: $detail';
}

/// ★ فلاتر «كل مندوب وطلباته» — مكان واحد حتى لا تتفرّع الصيغة في الشاشات.
///
/// طلبات المندوب المنتهية كانت تُقرأ بلا إسناد، فامتلأ تبويبا «مكتمل»
/// و«مرفوض» بطلبات بقية المندوبين — وكل رفض في النظام، بما فيه إلغاءات
/// الإدارة: «تشبك للجميع». الآن كل تبويب لا يرى إلا ما لهذا الرقم.
///
/// ★ هذه المرشّحات صارت **احتياطاً فقط**: المصدر الأساسي دالتا القاعدة
///   `driver_delivered_orders()` و`driver_rejected_orders()` (من
///   `SQL_DRIVER_ORDER_ISOLATION.sql`)، لأن الفلتر النصي في الرابط ترتيبُ
///   عرض لا عزل — من يملك مفتاح anon يستطيع كتابة رقم مندوب آخر. الدالة
///   تأخذ الرقم من توكن الجلسة، فإن لم تُنشَأ بعد (الملف لم يُشغَّل)
///   يرجع التطبيق إلى هذه المرشّحات بلا كسر.
class DriverOrderFilters {
  const DriverOrderFilters._();

  /// ★ المتاحة للمندوب: **كل الحالات المفتوحة**، لا حالة واحدة حرفية.
  ///   هذا هو المرشّح الأساسي الآن.
  ///
  ///   الشاشة تعرض البطاقة ما دام الطلب لم يُسلَّم ولم يُرفض ولم يُلغَ؛
  ///   وكان الفلتر كلمة `pending` وحدها، فأي طلب كُتبت حالته في القاعدة
  ///   بغيرها (`new` و`open` — وكلاهما معروف أصلاً في
  ///   `notification_sound.dart`) بقي **مخفيّاً** عن المندوب مع أن
  ///   إشعاره وصله: «صوت بلا شيء».
  ///
  ///   ★ لماذا تسمية لا نفياً (`not.in.(...)`)؟ لأن النفي يُرجع حالة
  ///   غريبة كـ`assigned` — أي طلب **أخذه زميل** — فيظهر «متاحاً» ويُقبل
  ///   مرتين. لا يُحرم أحد من طلبه، ولا يُعطى أحد طلب غيره.
  ///   `pending` أول القائمة وهي الحالة التي يكتبها التطبيق دائماً
  ///   ([SupabaseService.createOrder])، فالسلوك المعهود محفوظ.
  static const String availableOpen =
      'status=in.(pending,new,open,placed,created)';

  /// الاحتياط القديم حرفياً: `status=eq.pending`.
  ///
  /// ★ لا يُحذف: لو كان `orders.status` نوع `enum` في القاعدة ولم يكن
  ///   أحد الأسماء الزائدة ضمن قيمه، يُرفض `in.(…)` بخطأ ويصير الردّ
  ///   غير ناجح — فتنقلب القراءة كلها إلى «فارغ». عندها يرجع المرشّح
  ///   الضيّق فيُقرأ المتاح كما كان يُقرأ أمس.
  static const String availableStrict = 'status=eq.pending';

  /// مكتمل هذا المندوب: المسند إليه ووصل.
  static String delivered(String phone) =>
      'status=eq.delivered&assigned_driver_phone=eq.${_digits(phone)}';

  /// مرفوض/ملغى **لهذا المندوب** — المرشّح الأول: بختم الرافض.
  ///
  /// `or=(...)` بدل ترقيم `&&` لأن الشرطين بديلان لا مجتمعان: إمّا هو
  /// من رفض (طلب كان متاحاً فلم يُسنَد لأحد)، أو كان مسنداً إليه ثم
  /// رُفض/أُلغي من غيره.
  static String rejectedPrimary(String phone) {
    final p = _digits(phone);
    return 'status=in.(rejected,cancelled)'
        '&or=(rejected_by_phone.eq.$p,assigned_driver_phone.eq.$p)';
  }

  /// المرشّح الاحتياطي حين لا يكون `rejected_by_phone` موجوداً بعد:
  /// عمود واحد مضمون، فلا يُحرم المندوب من رفضاته كلها.
  static String rejectedFallback(String phone) =>
      'status=in.(rejected,cancelled)'
      '&assigned_driver_phone=eq.${_digits(phone)}';

  /// أرقام فقط: لا مسافات ولا '+' ولا رموز تكسر نصّ الفلتر.
  static String _digits(String phone) =>
      phone.trim().replaceAll(RegExp(r'[^0-9]'), '');
}

/// نتيجة قراءة «المتاحة» للمندوب: الصفوف، وهل نزلنا للاحتياط الضيّق،
/// وهل سقطت القراءتان معاً.
///
/// `[failed] = true` تعني «لم تصلني قراءة»، وهي **لا** تعني «لا طلبات
/// عندك» — والخلط بينهما هو ما جعل الشاشة تبدو فارغة مع وصول الإشعار.
class DriverAvailableRead {
  const DriverAvailableRead(
    this.orders, {
    required this.usedStrict,
    required this.failed,
  });

  final List<Map<String, dynamic>> orders;
  final bool usedStrict;
  final bool failed;
}

/// ★ الطلبات المتاحة للمندوب: الحالات المفتوحة أولاً، والمرشّح القديم
///   (`status=eq.pending`) احتياطاً عند سقوطها فقط.
///
///   [fetch] هو [_fetchOrdersChecked] من الخدمة: `null` = الردّ لم يكن
///   نجاحاً، و`[]` = لا صفوف لهذا الشرط فعلاً — والتمييز بينهما هو مربط
///   الفرس، لأن القراءة السابقة كانت تخلطهما فتعرض «لا طلبات» كاذبة.
///
///   · المرشّح المفتوح نجح ⇒ صفوفه تُرجَع كما هي ب**نداء واحد**، فلا
///     حِمل إضافي على قاعدة فيها مندوبون كثيرون واستطلاع كل بضع ثوانٍ.
///     وهو يلتقط الطلب مهما كان نصّ حالته (`pending` و`new` و`open`…).
///   · سقط (عمود مفقود، انقطاع، أو نوع `enum` لا يعرف الأسماء الزائدة) ⇒
///     نداء ثانٍ بـ[DriverOrderFilters.availableStrict]، فيبقى المتاح
///     يُقرأ كما كان يُقرأ أمس ولا تُطفأ الشاشة كلها بسبب مرشّح.
///   · الاثنان سقطا ⇒ `[failed] = true`: الشاشة تُخبره، والقائمة التي
///     أمامه لا تُمحى.
///
///   ★ ما رآه المندوب لم يتغيّر في الجوهر: `accepted` و`delivering`
///   يبقيان في تبويب «جاري» ولا يدخلان المتاحة، فلا يُسحب طلب من زميل.
Future<DriverAvailableRead> readDriverAvailableOrders(
  Future<List<Map<String, dynamic>>?> Function(String filter) fetch,
) async {
  final open = await fetch(DriverOrderFilters.availableOpen);
  if (open != null) {
    return DriverAvailableRead(open, usedStrict: false, failed: false);
  }

  final strict = await fetch(DriverOrderFilters.availableStrict);
  if (strict == null) {
    return const DriverAvailableRead([], usedStrict: true, failed: true);
  }
  return DriverAvailableRead(strict, usedStrict: true, failed: false);
}

/// حالة ندرة دالة الجلسة (`/rpc/…`) كما يقرأها رقم حالة ردّ PostgREST.
///
/// التمييز ضروري: **الدالة غير موجودة** (لم يُشغَّل ملف SQL بعد) أمرٌ ثابت
/// يُبنى عليه قرار البقاء على المرشّح النصي، أما انقطاع الشبكة أو ٤٠١ فهي
/// عابرة ولا يجوز أن تُسجَّل كغياب للدالة — وإلا بقي الجهاز عمره على
/// الاحتياط وهو كان قادراً على القراءة المعزولة.
enum RpcAvailability { available, notCreatedYet, transientFailure }

/// ترجمة رقم الحالة إلى واحد من أحوال [RpcAvailability] الثلاثة.
RpcAvailability rpcAvailabilityFor(int statusCode) {
  if (statusCode >= 200 && statusCode < 300) return RpcAvailability.available;
  // PGRST202: «الدالة غير موجودة في المخطط» — يأتي برقم ٤٠٤.
  if (statusCode == 404) return RpcAvailability.notCreatedYet;
  return RpcAvailability.transientFailure;
}

/// كل تواصل مع قاعدة البيانات عبر REST (Supabase).
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  // ★★ لا نص صريح: العنوان والمفتاح مُجزّآن في `core/secrets.dart`
  //   فيظهران في `strings` كأرقام، لا كنصّ. المفتاح **عام بحكم
  //   التصميم** (أمانه من RLS) — فالتجزئة تمنع الاستخراج المباشر.
  final String _url = Secrets.supabaseRestBase;
  final String _anonKey = Secrets.supabaseAnonKey;

  /// عميل واحد مشترك لكل التطبيق ⇒ اتصال TCP/TLS واحد **مُعاد الاستخدام**
  /// لكل الطلبات الـ ٥٦+.
  ///
  /// `http.get` وأخواتها تنشئ `Client` جديداً في كل استدعاء، فكل ضغطة
  /// زر تلامس الشبكة كانت تدفع مصافحة TLS كاملة (١٠٠–٣٠٠ ملّي) قبل أن
  /// يبدأ الطلب أصلاً — وهذا أكبر مصدر للحِمل المُحسّ على كل إجراء.
  ///
  /// ★ `RequestHealth.track` غلاف شفاف بنفس الواجهة: يعدّ الردود غير 2xx
  ///   والانقطاعات، فيعرف `AppRefresh` أن التحديث **نجح فعلاً** قبل أن
  ///   يُصدر رنّته. الغلاف لا يغيّر أي سطر نداء ولا أي سلوك.
  static final http.Client _http = RequestHealth.track(http.Client());

  /// توكن الجلسة الموقّع HMAC (المرحلة 2 من SQL_HARDEN_STAGE2).
  /// `null` = لا جلسة ⇒ القاعدة تعامل الطلب كزائر مجهول.
  String? _sessionToken;
  Map<String, String>? _headersCache;

  /// يُستدعى من AuthService بعد نجاح verify_login، وعند الخروج.
  ///
  /// ★ التوكن **لا يُحفظ في مكان دائم داخل التطبيق** — يبقى في الذاكرة
  ///   فقط، فيضيع بإغلاق التطبيق. هذا مقصود: التوكن bearer يمنح صلاحية
  ///   قراءة طلبات الآخرين، وتخزينه في SharedPreferences (localStorage
  ///   على الويب) يجعله قابلاً للسرقة بأي XSS. penggرب يعيد تسجيل الدخول.
  void setSessionToken(String? token) {
    final t = (token == null || token.isEmpty) ? null : token;
    if (t == _sessionToken) return;
    _sessionToken = t;
    _headersCache = null;
  }

  bool get hasSession => _sessionToken != null;

  /// الترويسات مُخزَّنة (كما كان `late final`) لكن تُبطَل عند تغيير
  /// التوكن، فتبقى بانيةً مرة واحدة لا مرة لكل طلب.
  ///
  /// ★ `x-app-token` هو ما يجعل `app.current_phone()` و`app.is_admin_req()`
  ///   تعملان؛ بدونه تفشل كل دوال الطلبات بعد المرحلة 2.
  Map<String, String> get _headers => _headersCache ??= {
    'apikey': _anonKey,
    'Authorization': 'Bearer $_anonKey',
    'Content-Type': 'application/json',
    'Prefer': 'return=representation',
    'x-app-token': ?_sessionToken,
  };

  /// آخر رسالة خطأ من رفع صورة.
  String? lastUploadError;

  /// آخر خطأ حقيقي عند إنشاء طلب (من رد السيرفر).
  String? lastOrderError;

  /// ★ آخر فشل حقيقي في تحديث حالة طلب (PATCH).
  ///
  /// ★ كان الفشل يُبتلع بـ`catch (_) {}` فيعود `failed` واحداً لكل
  ///   الأسباب، فتقول الشاشة «تعذر الاتصال بالسيرفر» — وهي كذبة:
  ///   ٤٠٠ (عمود ناقص) و٤٠١ (توكن منتهي) و٥٠٠ وتــResultado كلها
  ///   نفس الرسالة. النتيجة: المستخدم يعيد المحاولة ألف مرة على
  ///   خطأ لا علاقة له بالاتصال، والمطوّر لا يعرف السبب.
  String? lastOrderUpdateError;

  int? lastOrderUpdateStatus;

  /// ★★ **تذكرة الأدمن** — بديل كلمة اللوحة على الجهاز (2026-10-10).
  ///
  ///   المشكلة التي تُحلّ: كانت كلمة فتح اللوحة تُحفظ على القرص وتُرسل مع
  ///   كل عملية إدارية، ومن يستخرجها من ملف التفضيلات (أو يفتح هاتفك غير
  ///   المقفل) يملك اللوحة كلها من أي جهاز في العالم، ولا طريقة لإبطاله.
  ///
  ///   الآن: الكلمة تُدخَل **مرة**، فتُبدَّل في القاعدة بتذكرة عشوائية
  ///   (`admin_panel_login`) مربوطة بجلسة هذا الحساب ومدة صلاحيتها سبعة
  ///   أيام، وتسقط لحظة سحب دور الأدمن، وتُبطل كلها بـ
  ///   `select public.admin_device_revoke_all();`. الجهاز لا يعود يحمل ما
  ///   يشبه كلمة اللوحة، ومفتاح anon وحده لا يفتح شيئاً لأن التذكرة لا
  ///   تعمل بلا توكن الجلسة الموقّع لصاحبها.
  ///
  ///   يعيد `{ok, ticket, missing, code, message}` — و`missing: true`
  ///   يعني أن `SQL_ADMIN_PANEL_LOCKDOWN.sql` لم يُنفَّذ بعد، فيُتراجع
  ///   للبوابة القديمة بلا أي كسر.
  Future<Map<String, dynamic>> adminPanelLogin(String password) async {
    if (password.isEmpty) {
      return {'ok': false, 'message': 'أدخل كلمة الفتح'};
    }
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_panel_login'),
            headers: _headers,
            body: jsonEncode({'p_password': password}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 404 && res.body.contains('PGRST202')) {
        return {'ok': false, 'missing': true};
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return {'ok': false, 'message': _shortBody(res.body)};
      }
      final v = jsonDecode(res.body);
      // الدالة ترجع التذكرة نصّاً، أو رمز خطأ يبدأ بـ ERR: — ولا ترمي
      // استثناءً، وإلا أُبطلت سطور المحاولات التي يُبنى بها القفل.
      if (v is String && AdminPasswordSession.isTicket(v)) {
        return {'ok': true, 'ticket': v};
      }
      final code = v is String ? v : 'ERR:EMPTY';
      return {'ok': false, 'code': code, 'message': _adminTicketMessage(code)};
    } catch (e) {
      return {'ok': false, 'offline': true, 'message': 'تعذّر الاتصال: $e'};
    }
  }

  /// ترجمة رموز التذكرة إلى كلام مستخدم — بلا كشف ما لا يخصّ السائل.
  String _adminTicketMessage(String code) {
    if (code.contains('LOCKED')) {
      return 'توقّف المحاولات 15 دقيقة لكثرة الأخطاء.';
    }
    if (code.contains('NO_SESSION')) return 'افتح حسابك في التطبيق أولاً.';
    if (code.contains('NOT_ADMIN') || code.contains('NO_ACCOUNT')) {
      return 'هذا الحساب ليس له صلاحية لوحة التحكم.';
    }
    if (code.contains('CHECK_FAILED')) return 'تعذّر التحقق من الكلمة.';
    return 'كلمة المرور غير صحيحة';
  }

  /// ★ هل التذكرة المحفوظة ما زالت صالحة؟ (نعم/لا، و`null` = الدالة غير
  ///   مثبّتة بعد — أي لم تُشغَّل SQL، فنرجع للبوابة القديمة.)
  Future<bool?> adminTicketOk(String ticket, String op) async {
    if (!AdminPasswordSession.isTicket(ticket)) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_device_ok'),
            headers: _headers,
            body: jsonEncode({'p_credential': ticket, 'p_op': op}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 404 && res.body.contains('PGRST202')) return null;
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      return (jsonDecode(res.body) as bool?) == true;
    } catch (_) {
      return null;
    }
  }

  /// ★ بوابة اللوحة بالمستوى الأعلى: تتذكرة إن وجدت، وإلا بكلمة اللوحة.
  ///
  ///   `secret` = ما عند الجهاز (تذكرة محفوظة أو كلمة كُتبت الآن).
  ///   التذكرة **لا تُجرَّب ككلمة** أبداً: لو انتهت تُطلب الكلمة من صاحبها،
  ///   لأن تمريرها إلى `admin_panel_password_ok` يحسبها محاولة فاشلة، وخمس
  ///   منها تقفل الحساب — فيُقفل نفسه هو بلا أي خطأ منه.
  ///
  ///   `{ok, ticket?, offline?, expired?, missing?, message}` — و`offline:
  ///   true` يعني «لم نصل إلى القاعدة»: الشاشة تُبقي المحفوظة كما كانت
  ///   قبل هذا التغيير، فلا يضيع ما عند الجهاز بسبب انقطاع شبكة.
  Future<Map<String, dynamic>> unlockAdminPanel(
    String phone,
    String secret,
  ) async {
    if (secret.isEmpty) {
      return {'ok': false, 'message': 'أدخل كلمة الفتح'};
    }

    // (1) تذكرة الجلسة: تُفحص وحدها، ولا تمرّ على بوابة الكلمة إطلاقاً.
    if (AdminPasswordSession.isTicket(secret)) {
      final alive = await adminTicketOk(secret, 'open');
      if (alive == true) return {'ok': true, 'ticket': secret};
      if (alive == false) {
        return {
          'ok': false,
          'expired': true,
          'message': 'انتهت صلاحية هذه الجلسة — أدخل كلمة فتح اللوحة.',
        };
      }
      // لا ردّ مؤكد (شبكة أو دالة غير مثبّتة): لا نُهدر التذكرة ولا نفتح
      // الباب بكلمة ليست ملك أحد.
      return {'ok': false, 'offline': true, 'message': 'تعذّر الاتصال بالخادم'};
    }

    // (2) كلمة اللوحة: تُستبدل بتذكرة إن كانت الدوال مثبّتة.
    final login = await adminPanelLogin(secret);
    if (login['ok'] == true) return login;
    if (login['offline'] == true) {
      return {'ok': false, 'offline': true, 'message': login['message']};
    }
    if (login['missing'] == true) {
      // لم تُنفَّذ SQL_ADMIN_PANEL_LOCKDOWN.sql: البوابة القديمة كما هي.
      final old = await verifyAdminPanelPassword(phone, secret);
      if (old == null) {
        return {
          'ok': false,
          'offline': true,
          'message': 'تعذّر الاتصال بالخادم',
        };
      }
      return {
        'ok': old['ok'] == true,
        'missing': true,
        'message': old['message'] ?? 'تعذّر التحقق',
      };
    }
    return login;
  }

  /// ★★ يتحقّق من **كلمة فتح لوحة التحكم** — وهي `admin_secret`، لا كلمة
  /// مرور الحساب.
  ///
  /// ★ فصل مقصود: كلمة الدخول إلى التطبيق مخزّنة في `users.pw_hash`، وكلمة
  ///   اللوحة في `admin_secret`. استدعاء `verifyLogin` هنا كان يجعل كلمة مرور
  ///   أي حساب إدني تفتح اللوحة ⇒ باب مفتوح على من يعرف كلمة زبون.
  ///
  /// `p_phone` يُمرَّر لأن القفل التدريجي في القاعدة محسوب به (PostgREST
  /// لا يمرّر عنوان الـIP)، فيقفل هذا الحساب وحده بعد 5 محاولات.
  ///
  /// ★ جلسة المستخدم لا تتأثر: لا نمسّ `users` ولا `_sessionToken`.
  /// يعيد `{ok: bool, message: String}`.
  Future<Map<String, dynamic>?> verifyAdminPanelPassword(
    String phone,
    String password,
  ) async {
    if (password.isEmpty) {
      return {'ok': false, 'message': 'كلمة المرور غير صحيحة'};
    }
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_panel_password_ok'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone.trim(), 'p_password': password}),
          )
          .timeout(const Duration(seconds: 20));
      // ★ رسالة القفل وحدها تُترجم؛ ما عداه رسالة موحّدة حتى لا نكشف
      //   هل الخطأ في الرقم أم في الكلمة.
      if (res.statusCode >= 400 && res.statusCode < 500) {
        final body = _shortBody(res.body).replaceAll('{}', '').trim();
        if (body.contains('15 minutes') || body.contains('2 minutes')) {
          return {
            'ok': false,
            'message': 'تم إيقاف المحاولات مؤقتاً. حاول بعد قليل.',
          };
        }
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return {'ok': false, 'message': 'تعذّر التحقق'};
      }
      final ok = (jsonDecode(res.body) as bool?) == true;
      return {'ok': ok, 'message': ok ? 'تم الفتح' : 'كلمة المرور غير صحيحة'};
    } catch (e) {
      return {'ok': false, 'message': 'تعذّر الاتصال: $e'};
    }
  }

  /// ★ يستدعي دالة في `public` عبر `/rpc/` ويترجم ردّها إلى قائمة صفوف.
  ///
  /// ★ كل الطلبات المحمية بعد SQL_HARDEN_STAGE2 تمرّ من هنا: لا وصول
  ///   مباشراً إلى جدول، لأن `revoke all` أزال صلاحية anon.
  ///
  /// يرمي [PostgrestFailure] عند 4xx/5xx حتى لا تُبتلع أسباب رفض RPC.
  Future<List<Map<String, dynamic>>> rpcRows(
    String fn,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final res = await _http
        .post(
          Uri.parse('${_url}rpc/$fn'),
          headers: _headers,
          body: jsonEncode(params),
        )
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PostgrestFailure(res.statusCode, _shortServerError(res.body), fn);
    }
    if (res.body.trim().isEmpty) return const [];
    final decoded = jsonDecode(res.body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }
    // دالة تُرجع jsonb مفرداً (مثل order_item_field) ⇒ صف واحد.
    if (decoded is Map) return [Map<String, dynamic>.from(decoded)];
    return const [];
  }

  /// مثل [rpcRows] لكن تعيد صفاً واحداً أو null.
  Future<Map<String, dynamic>?> rpcOne(
    String fn,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final rows = await rpcRows(fn, params, timeout: timeout);
    return rows.isEmpty ? null : rows.first;
  }

  /// يختصر رد خطأ السيرفر إلى رسالة مفهومة.
  static String _shortServerError(String? body) {
    if (body == null || body.isEmpty) return 'بلا تفاصيل';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['message'] != null) {
        final msg = decoded['message'].toString();
        // ★ كود عجلة الحظ على طلب ثانٍ: يرفضه **الفهرس** في القاعدة
        //   (`orders_wheel_code_once_idx`) لا فحص في التطبيق — فلا
        //   توجد رسالة أوضح من هذا: الطلب الثاني لم يُدرَج، والكود
        //   لم يُخصم مرتين. يجب أن يُفحص **قبل** التعميم التالي،
        //   وإلا نُبلّغ الزبون «لديك طلب نشط واحد» وهو كذب.
        if (msg.contains('orders_wheel_code_once')) {
          return 'كود عجلة الحظ استُعمل في طلبك السابق — لا يُستعمل مرتين';
        }
        if (msg.contains('duplicate key')) {
          return 'لديك طلب نشط واحد فقط — أكمله أولاً أو انتظر قليلاً';
        }
        if (msg.contains('violates row-level security')) {
          return 'الصلاحيات ناقصة — شغّل سكربت الصلاحيات';
        }
        return msg.length > 160 ? '${msg.substring(0, 160)}…' : msg;
      }
    } catch (_) {}
    return body.length > 160 ? '${body.substring(0, 160)}…' : body;
  }

  /// ★ هل هذا الخطأ «عمود غير موجود» وحده؟
  ///
  /// الحلقة في [`createOrder`] كانت تُجرّب ثلاثة أجسام وراء بعضها بلا
  /// تمييز: `withExtras` ← `withCoupon` ← `base`. كان ذلك مقبولاً حين
  /// كانت الأعمدة الاختيارية فعلاً هي السبب الوحيد، أما الآن فأي رفض
  /// آخر — ومنه **رفض تكرار كود العجلة** — كان يهبط إلى `base` الذي
  /// **لا يحمل حقول الكود إطلاقاً**، فيُنشَأ الطلب بسعر كامل والزبون
  /// يظن أنه حصل على خصمه. التراجع إذن لا يكون إلا لعمود مفقود.
  static bool _isMissingColumnError(String? body) {
    if (body == null || body.isEmpty) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return false;
      final code = '${decoded['code'] ?? ''}';
      final msg = '${decoded['message'] ?? ''}';
      if (code == '42703' || code == 'PGRST204') return true;
      return msg.contains('does not exist') && msg.contains('column');
    } catch (_) {
      return false;
    }
  }

  /// آخر رسالة خطأ عند إرسال إشعار.
  String? lastNotificationError;

  /// كاش شعار الإشعارات لكل حساب: كل زبون له شعاره لحاله.
  ///
  /// يُملأ مرة واحدة ثم يُعاد استخدامه لكل إشعار يُرسل لذلك الزبون،
  /// فلا نضرب قاعدة البيانات مع كل تغيير حالة طلب.
  final Map<String, String> _brandImages = {};

  /// ★ تصفير كاش الشعارات — يُستدعى عند تبديل الحساب أو الخروج.
  ///
  /// كان الكاش لا يُصفَّر أبداً، فحسابٌ يغيّر صورته يُبقي الشعار
  /// القديم، وبعد تسجيل الخروج والدخول بحساب آخر قد يُرفَق شعار
  /// الحساب السابق. الآن: «شعار واحد لكل حساب» بلا خلط.
  void clearBrandCache() => _brandImages.clear();

  /// ★★ شعار حساب بعينه — **وليس إلا إن كان داخل التطبيق الآن**.
  ///
  /// القاعدة: «لا شعار إلا لمن هو داخل». الحساب الذي خرج من
  /// التطبيق (لغى توكن جهازه) يستقبل إشعاراته بلا صورة، فلا يبقى
  /// شعاره عالقاً على جهازه بعد خروجه، ولا يُرسل شعار حساب إلى
  /// حساب آخر.
  ///
  /// يُستعمل في [_notifyOrder] — إشعار صاحب الطلب.
  Future<String?> brandImageOf(String phone) async {
    if (phone.isEmpty) return null;
    // ── خارج التطبيق ⇒ بلا شعار. ──
    //  نفس معيار الخادم (`account_is_online`): توكن جهاز فعّال.
    if (!await accountIsOnline(phone)) return null;
    final hit = _brandImages[phone];
    if (hit != null) return hit.isEmpty ? null : hit;
    final found = (await fetchNotificationBrand(phone)).image;
    final url = (found ?? '').trim();
    _brandImages[phone] = url;
    return (url.isEmpty || url == 'null') ? null : url;
  }

  /// هل هذا الحساب داخل التطبيق الآن (له توكن جهاز فعّال)؟
  ///
  /// ★ نفس معيار الخادم في `account_is_online`، فيبقى السلوكان
  ///   متطابقين: داخل ⇒ شعاره، خارج ⇒ بلا شعار.
  /// الفشل أو انتهاء المهلة ⇒ `true` (الأسلم أن يُعرض شعاره على
  /// أن يُحرم منه).
  Future<bool> accountIsOnline(String phone) async {
    if (phone.isEmpty) return false;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/account_is_online'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(res.body) == true;
      }
    } catch (_) {}
    return true;
  }

  // ==========================================================
  //  الصور
  // ==========================================================

  /// يرفع صورة إلى سلة "images" ويُعيد رابطها العام.
  ///
  /// `mimeType`/`extension` يبقيان نوع الملف مطابقاً لمحتواه: نرفع غالباً
  /// WebP (أصغر بحوالي نصف الحجم بنفس الجودة الظاهرة)، فلو وُسم الملف
  /// `.jpg` مع محتوى WebP لرفضته بعض المتصفحات.
  /// أساس رابط سلة الصور (Storage). يُستعمل للرفع وللحذف معاً.
  static const String _storageBase =
      'https://piepmqbqdxhnsbynjgmg.supabase.co/storage/v1/object';

  Future<String?> uploadImage(
    Uint8List bytes, {
    String folder = 'shops',
    String? fileName,
    String mimeType = 'image/jpeg',
    String extension = 'jpg',
  }) async {
    try {
      lastUploadError = null;
      const bucket = 'images';
      final name =
          fileName ??
          '${DateTime.now().millisecondsSinceEpoch}_${folder}_${bytes.length}.$extension';
      final path = '$bucket/$folder/$name';
      final res = await _http.post(
        Uri.parse('$_storageBase/$path'),
        headers: {
          'apikey': _anonKey,
          'Authorization': 'Bearer $_anonKey',
          'Content-Type': mimeType,
          'x-upsert': 'true',
        },
        body: bytes,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return '$_storageBase/public/$path';
      }
      String reason;
      try {
        final body = jsonDecode(res.body);
        reason = (body is Map && body['message'] != null)
            ? body['message'].toString()
            : res.body;
      } catch (_) {
        reason = res.body;
      }
      lastUploadError =
          'فشل رفع الصورة للسيرفر (خطأ ${res.statusCode}): $reason';
    } catch (e) {
      lastUploadError = 'فشل الاتصال بالسيرفر لرفع الصورة: $e';
    }
    return null;
  }

  /// ★★ حذف ملف صورة من سلة `images`.
  ///
  /// ★ لماذا؟ الصورة تُرفع **قبل** الحفظ (هذا تصميم رافع الصور عندنا:
  ///   ترفع ثم تمرّر الرابط). فإذا مسح الأدمن الصورة أو ألغى النموذج
  ///   بقي الملف يتيمًا في السحابة إلى الأبد — يأخذ مساحة ويظهر في
  ///   قائمة الملفات بلا أي صف في القاعدة يشير إليه.
  ///
  /// ★ صلاحيات: سلة `images` فيها سياسة حذف لـ`anon` (ملف
  ///   `supabase_fix_bucket.sql`)، وهذا مسار يعمل — تحقّقنا منه برفع
  ///   ملف تجريبي وحذفه بمفتاح الأنون فرجّع «Successfully deleted».
  ///
  /// ★ يقبل رابطاً كاملاً (الذي يُخزَّن في القاعدة) أو مساراً نسبياً
  ///   مثل `images/products/x.webp`، ويعيد true عند الحذف الفعلي.
  ///   الفشل صامت عمداً: تعذّر الحذف لا يُلغي حذف الصف من القاعدة.
  Future<bool> deleteImage(String urlOrPath) async {
    final path = storagePathOf(urlOrPath);
    if (path.isEmpty) return false;
    try {
      final res = await _http
          .delete(
            Uri.parse('$_storageBase/$path'),
            headers: {'apikey': _anonKey, 'Authorization': 'Bearer $_anonKey'},
          )
          .timeout(const Duration(seconds: 12));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// استخراج مسار السلة من رابط أو مسار مخزَّن في القاعدة.
  /// يعيد '' إن لم يكن الملف في سلة صورنا — فلا نحذف شيئاً بحدس.
  static String storagePathOf(String urlOrPath) {
    var s = urlOrPath.trim();
    if (s.isEmpty) return '';
    const full = '/object/public/';
    final i = s.indexOf(full);
    if (i >= 0) return s.substring(i + full.length);
    const obj = '/object/';
    final j = s.indexOf(obj);
    if (j >= 0) s = s.substring(j + obj.length);
    if (s.startsWith('storage/v1/')) s = s.substring('storage/v1/'.length);
    if (s.startsWith('/')) s = s.substring(1);
    if (s.startsWith('object/')) s = s.substring('object/'.length);
    if (s.startsWith('public/')) s = s.substring('public/'.length);
    return s.startsWith('images/') ? s : '';
  }

  // ==========================================================
  //  الحسابات
  // ==========================================================

  Future<bool> testConnection() async {
    try {
      final res = await _http.get(
        Uri.parse('${_url}categories?select=count&limit=1'),
        headers: _headers,
      );
      return res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  /// تسجيل حساب جديد (اسم + هاتف + كلمة مرور).
  ///
  /// ★★ يمرّ عبر `register_user` (SECURITY DEFINER) لا عبر INSERT مباشر
  ///   على `users`: بعد `SQL_HARDEN_ALL` §1.7 و`SQL_HARDEN_STAGE2` §2.16
  ///   became الـINSERT ممنوعاً على `anon` والسياسة الوحيدة المسموحة
  ///   `users_admin_insert` (أدمن فقط) ⇒ كان التسجيل يرتدّ 401 دائماً
  ///   («new row violates row-level security policy») ولا يوجد أي
  ///   طريق آخر لإنشاء حساب. الدالة هي المدخل الوحيد، وتُبقي الجدول
  ///   مقفلاً — فتح GRANT لـanon بالضبط هو ما صنع العطل.
  ///
  /// ★ تُرجع الجلسة جاهزة: بدون `x-app-token` تردّ كل طلبات المستخدم
  ///   بـ401 مباشرةً بعد التسجيل، فيخرج من حسابه الذي أنشأه للتو.
  Future<RegisterResult> registerUser({
    required String name,
    required String phone,
    required String password,
  }) async {
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/register_user'),
            headers: _headers,
            body: jsonEncode({
              'p_name': name.trim(),
              'p_phone': phone.trim(),
              'p_pass': password,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is! Map) {
          return const RegisterResult(
            created: false,
            error: 'رد غير متوقع من الخادم',
          );
        }
        final row = Map<String, dynamic>.from(decoded);
        if (row['ok'] != true) {
          return RegisterResult(
            created: false,
            error: (row['error'] ?? 'تعذّر إنشاء الحساب').toString(),
          );
        }
        final token = row['session_token']?.toString();
        if (token != null && token.isNotEmpty) setSessionToken(token);
        // صلاحيات الإشعارات: العنوان مضبوط أصلاً عند الإنشاء.
        return RegisterResult(
          created: true,
          token: token,
          name: (row['name'] ?? name).toString(),
        );
      }
      // ★ PostgREST يردّ 404 إن لم تُنفَّذ SQL_FIX_REGISTER_401.sql بعد.
      //   الرسالة الصامتة «تعذّر إنشاء الحساب (404)» كانت تُظنّ خللاً
      //   في التطبيق، بينما السبب ملف SQL غير مُطبَّق.
      if (res.statusCode == 404) {
        return const RegisterResult(
          created: false,
          error:
              'التسجيل غير مُفعّل على الخادم — نفّذ SQL_FIX_REGISTER_401.sql',
        );
      }
      if (res.statusCode == 409 || res.statusCode == 422) {
        return const RegisterResult(
          created: false,
          error: 'رقم الهاتف مسجّل مسبقاً — سجّل الدخول بدلاً من ذلك',
        );
      }
      return RegisterResult(
        created: false,
        error: 'تعذّر إنشاء الحساب (${res.statusCode})',
      );
    } catch (e) {
      return RegisterResult(created: false, error: 'فشل الاتصال: $e');
    }
  }

  /// تهيئة صلاحيات الإشعارات لحساب (يُستدعى عند التسجيل وكل دخول):
  /// يضبط عنوان الإشعارات فقط (لا شعار — أُزيلت الميزة بالكامل).
  Future<bool> grantNotificationAccess(String phone) async {
    if (phone.isEmpty) return false;
    try {
      final brand = await fetchNotificationBrand(phone);
      // ★ لا يُكتب في الحساب إلا اسمٌ حقيقي — اللقب العام لا يُختم.
      if (!AccountName.isGeneric(brand.title)) {
        return updateUser(phone, {'notification_title': brand.title});
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// يبحث عن مستخدم برقم الهاتف.
  Future<Map<String, dynamic>?> findUser(String phone) async {
    final r = await findUserChecked(phone);
    return r.user;
  }

  /// ★★★ يقرأ صفّ المستخدم عبر دالة مخوّضة بـ SECURITY DEFINER.
  ///
  /// ★★★ محجوب الآن بالكامل (`SQL_PROTECT_ALL.sql` §1):
  ///   كانت الدالة **تُصدر جلسة موقّعة لأي رقم هاتف** بلا كلمة مرور
  ///   ولا كود — أي استيلاء على حساب الأدمن. كانت مخصّصة لمسار دخول
  ///   واتساب، وكوده كان يُتحقّق منه في **الخادم الخارجي** فقط بلا
  ///   أن تمرّ إثباتاً إلى القاعدة.
  ///   وفي هذا المشروع لا OTP أصلاً، فحُذف المدخل بالكامل: النتيجة
  ///   `null` دائماً. ⇒ تسجيل الدخول = [verifyLogin] بكلمة مرور.
  /// تسجيل دخول واتساب: الرمز يتحقق منه خادم الرموز، ثم تتحقق
  /// القاعدة من التوقيع **وتفحص الحساب في Supabase قبل إصدار الجلسة**.
  ///
  /// ★ `login_read_user` مُغلق عمداً: كان يُصدر جلسة لأي رقم هاتف
  ///   بلا كلمة مرور. الاستدعاء الآن عبر `login_wa_phone` الذي
  ///   يرفض التوقيع المزوَّف، ويرفض إعادة استخدام التوكن، ويتأكد أن
  ///   الحساب موجود ومفعّل، ويأخذ الأدوار من قاعدة البيانات لا من
  ///   مُدخلات العميل.
  Future<({Map<String, dynamic>? user, String? sessionToken, bool created})>
  loginWithToken(String phone, {String? token}) async {
    lastDeleteError = '';
    //  التوكن يأتي من WhatsappLoginService.verifyCode، وهو الخادم
    //  الذي تحقّق من الرمز الرقمي نفسه.
    final waToken = token?.trim() ?? _pendingWaToken;
    _pendingWaToken = null;

    if (waToken == null || waToken.length < 20) {
      lastDeleteError = 'لم يتم التحقق من الرمز';
      return (user: null, sessionToken: null, created: false);
    }

    try {
      final row = await rpcOne('login_wa_phone', {
        'p_phone': phone.trim(),
        'p_token': waToken,
      });
      if (row == null) {
        lastDeleteError = 'فشل التحقق من الرمز';
        return (user: null, sessionToken: null, created: false);
      }
      if (row['ok'] != true) {
        lastDeleteError = _waLoginError((row['error'] ?? '').toString());
        return (user: null, sessionToken: null, created: false);
      }

      final user = row['user'];
      final tok = row['session_token']?.toString();
      if (user is! Map || tok == null || tok.isEmpty) {
        lastDeleteError = 'استجابة غير متوقعة من الخادم';
        return (user: null, sessionToken: null, created: false);
      }
      // ★ `created` من القاعدة: أول دخول بكود واتساب يُنشئ الحساب،
      //   فيُعلَن للمستخدم «أهلاً بك» لا «مرحباً بعودتك».
      return (
        user: Map<String, dynamic>.from(user),
        sessionToken: tok,
        created: row['created'] == true,
      );
    } catch (e) {
      lastDeleteError = e.toString();
      return (user: null, sessionToken: null, created: false);
    }
  }

  /// رسائل عربية بدل الرموز الإنجليزية.
  static String _waLoginError(String code) {
    switch (code) {
      case 'MISSING_PHONE':
        return 'رقم الهاتف مفقود';
      case 'MISSING_TOKEN':
        return 'لم يتم التحقق من الرمز';
      case 'BAD_TOKEN':
      case 'BAD_SIGNATURE':
      case 'BAD_PAYLOAD':
      case 'BAD_CLAIMS':
        return 'الرمز غير صالح';
      case 'TOKEN_EXPIRED':
        return 'انتهت صلاحية الرمز - أعد الطلب';
      case 'TOKEN_REPLAYED':
        return 'استُخدم الرمز من قبل';
      case 'PHONE_MISMATCH':
        return 'الرمز لا يطابق هذا الرقم';
      case 'NO_SUCH_USER':
        return 'لا يوجد حساب بهذا الرقم';
      case 'ACCOUNT_DISABLED':
        return 'الحساب موقوف - راجع الإدارة';
      case 'NOT_CONFIGURED':
        return 'خطأ في الإعدادات - راجع الإدارة';
    }
    return code.isEmpty ? 'تعذّر تسجيل الدخول' : code;
  }

  /// يبحث عن مستخدم مع تمييز «غير موجود» عن «خطأ».
  Future<({UserLookupResult status, Map<String, dynamic>? user})>
  findUserChecked(String phone) async {
    if (phone.isEmpty) {
      return (status: UserLookupResult.notFound, user: null);
    }
    try {
      // ★★ كان يستعلم جدول users مباشرةً. بعد تفعيل RLS، الاستعلام
      //   المباشر يُرجع `[]` لغير المطابق ⇒ `notFound` ⇒ خروج فوري من
      //   التطبيق بعد كل دخول. من هنا جاء «يسجّل خروج فوراً».
      //
      //   الحل: يُقرأ عبر دالة SECURITY DEFINER تُرجع صف المستخدم
      //   متجاهلةً RLS، بعد أن تتحقق الدالة أن الجلسة صالحة.
      //   نفس منطق loginReadUser، مخصّص لدورة المراقبة.
      ApiMetrics.hit('app_read_own_user');
      final row = await rpcOne('app_read_own_user', {'p_phone': phone.trim()});
      if (row == null) {
        return (status: UserLookupResult.notFound, user: null);
      }
      final active = row['is_active'];
      if (active == false) {
        return (status: UserLookupResult.notFound, user: null);
      }
      return (status: UserLookupResult.found, user: row);
    } catch (e) {
      return (status: UserLookupResult.error, user: null);
    }
  }

  /// يربط توكن الجهاز بحسابه في جدول الأجهزة.
  ///
  /// ★ الجهاز يتبع **حساباً واحداً فقط** في الوقت نفسه.
  ///
  ///   المشكلة السابقة: التوكن واحد للجهاز، وكل حساب سجّل دخول على
  ///   الجهاز كان يُضاف للجدول. فينتهي الجدولSeveral حسابات تشترك
  ///   بنفس التوكن، فيصلها إشعار كل واحد منها — والإشعار يظهر
  ///   لحساب غير مسجّل به، أو يتكرر عند كل تبديل حساب.
  ///
  ///   الحل: عند ربط التوكن بحساب، نُعطّل ربطه ببقية الحسابات.
  ///   الحساب الذي سجّل دخوله آخر هو صاحب الجهاز.
  ///
  ///   يعيد true إن نجح. يتجاهل الأخطاء بأمان (لو لم يُشغَّل سكربت الإشعارات).
  ///
  /// ★★ سجّل `fcm_token` في جدول `users` — عبر دالة مخوّضة.
  ///
  ///   كان PATCH مباشراً بـanon، وهو يرفض بـ`42501 permission denied`.
  ///   فلم يكن أي جهاز يُسجَّل، فكان `push-api` يجد `tokens: 0` فلا تصل
  ///   إشعارات إطلاقاً — حتى والتطبيق مغلق.
  ///
  ///   الدالة تتحقق أن الجلسة الموقّعة تخص نفس الرقم، فلا يكتب أحد
  ///   توكناً لحساب غيره (وهو ما كان يجعل `grant update` خطيراً).
  Future<bool> registerFcmToken(String phone, String token) async {
    if (phone.isEmpty || token.isEmpty) return false;
    try {
      final res = await rpcCall('register_fcm_token', {
        'p_phone': phone.trim(),
        'p_token': token.trim(),
      });
      return res is Map && res['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> registerPushToken(
    String phone,
    String token, {
    String platform = 'android',
    String? deviceLabel,
  }) async {
    if (phone.isEmpty || token.isEmpty) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final row = {
      'user_phone': phone,
      'token': token,
      'platform': platform,
      'device_label': deviceLabel,
      'is_active': true,
      'last_seen_at': now,
    };
    // ★ نجرّب الترقيم على user_phone أولاً: التوكن يتغير أحياناً (تحديث
    //   FCM، إعادة تسجيل) ⇒ كان (user_phone,token) يُنتج صفاً جديداً لكل
    //   توكن، فتراكم إلى 19 صفاً لنفس الرقم. الآن صف واحد لكل حساب.
    //   ثم نجرّب (token) للقواعد القديمة، فالترقيم الأخير يُرقّم
    //   التطبيق على مستوى (user_phone).
    for (final onConflict in ['user_phone', 'token']) {
      try {
        final res = await http
            .post(
              Uri.parse('${_url}push_tokens?on_conflict=$onConflict'),
              headers: {
                ..._headers,
                // بدون هذه الترويسة يتجاهل PostgREST on_conflict ويضع
                // الصف من جديد فيرجع 409 عند التعارض.
                'Prefer': 'resolution=merge-duplicates,return=representation',
              },
              // 'on_conflict' يُمرَّر في الـ query string لا في الـ body،
              // وإلا رفضه PostgREST لأنه ليس عموداً في الجدول.
              body: jsonEncode(row),
            )
            .timeout(const Duration(seconds: 12));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          // ★ الجهاز صار لهذا الحساب وحده ⇒ إشعاراته ما تتكرر.
          unawaited(_claimTokenForAccount(phone, token));
          // آخر ظهور للجهاز: نستعمله في تنظيف التوكنات القديمة.
          unawaited(_bumpDeviceSeen(token, now));
          return true;
        }
      } catch (_) {}
    }
    // فشل الإدراج (جدول غير موجود أو قيد قديم): نكتفي بحفظه في الحساب.
    return updateUser(phone, {'fcm_token': token});
  }

  /// ★ يجعل هذا الجهاز يتبع [phone] وحده، ولا يتبع أي حساب آخر.
  ///
  ///   [_bumpDeviceSeen] reactivates every row that carries the token,
  ///   which would resurrect links to other accounts and bring the
  ///   duplicate notifications back. Here we deactivate the *other*
  ///   accounts only — this account's own row stays active.
  Future<void> _claimTokenForAccount(String phone, String token) async {
    try {
      await _http.patch(
        Uri.parse('${_url}push_tokens?token=eq.$token&user_phone=neq.$phone'),
        headers: _headers,
        body: jsonEncode({'is_active': false}),
      );
    } catch (_) {}
    // الفشل لا يضرّ: الحارس الحقيقي هو [registerPushToken] نفسه.
  }

  /// يحدّث `last_seen_at` لكل صف يحمل هذا التوكن (بلا خطأ إن لم يكن العمود).
  ///
  /// ★ لا نُعيد تفعيل الصفوف المعطّلة: حساب سابق استعمل نفس الجهاز،
  ///   وتفعيل صفّه الآن يعيد إشعارات حسابه لهذا الجهاز. من يستعمل
  ///   الجهاز هو من يسجّل توكنه (في [_claimTokenForAccount]).
  Future<void> _bumpDeviceSeen(String token, String iso) async {
    try {
      await _http.patch(
        Uri.parse('${_url}push_tokens?token=eq.$token'),
        headers: _headers,
        body: jsonEncode({'last_seen_at': iso}),
      );
    } catch (_) {}
    // نتجاهل الفشل — العمود قد لا يكون موجوداً في قواعد أقدم.
  }

  /// ★★ تعطيل توكنات جهاز يقوكن الحساب — يُستدعى عند تسجيل الخروج.
  ///
  /// السبب: [accountIsOnline] (أي «هل يُرسل شاره») ترجع false
  /// بعد الخروج: توكن الجهاز هو معيار «الحساب داخل
  /// التطبيق الآن» في الخادم أيضا («account_is_online»). بلا
  /// هذا لبقى توكن قديم يقول إن الحساب داخلا، فيُرسل له
  /// شارهه دائماً.
  ///
  /// ★★ كان `PATCH push_tokens` مباشراً بمفتاح `anon`. وبعد قفل
  /// الجدول بـRLS (`SQL_LOCKDOWN_PHASE1.sql`) صار ذلك كل الإيقاع — أي أن
  /// الحساب يَبقى «داخلا» بعد خروجه. فنستدعي دالةً
  /// `security definer` تتحقّق أن الرقم حساب حقيقيًا وله صف توكن.
  ///
  /// الفشل يُتجاهل: أسوأ ما فيه أن يبقى الشعار يُرسل.
  ///
  /// ★ [timeoutSeconds] صار قابلاً للضبط لأن `AuthService.logout` ينتظر
  ///   هذه الطلبية الآن (ثلاث ثوانٍ) لا يقذفها: الخروج لا يجوز أن
  ///   يتعلّق على شبكة ميتة، والرسالة التي لا تصل في ثلاث ثوانٍ لن
  ///   تصل قبل أن يغلق المستخدم التطبيق على أي حال.
  Future<void> deactivatePushTokens(
    String phone, {
    int timeoutSeconds = 8,
  }) async {
    final p = phone.trim();
    if (p.isEmpty) return;
    try {
      await _http
          .post(
            Uri.parse('${_url}rpc/deactivate_own_push_tokens'),
            headers: _headers,
            body: jsonEncode({'p_phone': p}),
          )
          .timeout(Duration(seconds: timeoutSeconds));
    } catch (_) {}
  }

  /// ★ أجهزة حساب معيّن (تقرير الأدمن عن الإشعارات).
  ///
  /// ★★ كان `GET push_tokens` مباشراً بمفتاح `anon` — أي أن **أي
  /// شخص** يقرأ توكنات FCM لكل الحسابات (وهذا أخطر باب). بعد قفل
  /// الجدول بـRLS صار ذلك ممنوعاً، فنستدعي دالة `admin_list_devices`
  /// `security definer` التي تشترط **كلمة مرور لوحة الأدمن** (لا
  /// كلمة مرور حساب) وتعيد نفس الشكل الذي تتوقّعه الشاشة.
  ///
  /// [adminPassword] كلمة `admin_secret`؛ بلاها تُرجع `const []`
  /// بدل أن تُسرّب أو تُرمش الشاشة.
  Future<List<Map<String, dynamic>>> fetchDeviceTokens(
    String phone, {
    String? adminPassword,
  }) async {
    if (phone.isEmpty && (adminPassword ?? '').isEmpty) return const [];
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_list_devices'),
            headers: _headers,
            body: jsonEncode({
              'p_admin_password': adminPassword ?? '',
              'p_phone': phone,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['ok'] == true) {
          final rows = decoded['devices'];
          if (rows is List) {
            return rows
                .whereType<Map>()
                .map(Map<String, dynamic>.from)
                .toList();
          }
        }
      }
    } catch (_) {}
    return const [];
  }

  /// عنوان الحساب داخل الإشعارات: **اسمه الحقيقي** لا لقباً عاماً.
  ///
  ///   التسلسل: عنوانُه المضبوط، ثم اسمه في `users`، ثم اسم صيدليته إن كان
  ///   تاجراً، ثم رقمه الثابت. والألقاب العامة (حساب/زبون/مندوب/مستخدم)
  ///   لا تُعدّ أسماءً أصلاً — تُتجاهل كما يُتجاهل الفراغ، لأن خانتين
  ///   باسمٍ واحد لا تميّزان أحداً.
  ///
  /// ملاحظة: لا يوجد شعار خاص بالإشعارات anymore — القرار النهائي
  /// كان حذف الميزة بالكامل ⇒ الإشعارات بلا صور من الحساب.
  Future<({String? image, String title})> fetchNotificationBrand(
    String phone,
  ) async {
    if (phone.isEmpty) return (image: null, title: '');

    // نستعلم بالعمودين الأساسية (بدون notification_image).
    const selects = [
      'name,notification_title,avatar_url,is_shop_owner',
      'name,notification_title',
      'phone',
    ];
    Map<String, dynamic>? row;
    for (final select in selects) {
      try {
        final res = await _http
            .get(
              Uri.parse('${_url}users?select=$select&phone=eq.$phone&limit=1'),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final list = jsonDecode(res.body) as List;
          if (list.isEmpty) return (image: null, title: phone);
          row = Map<String, dynamic>.from(list.first as Map);
          break;
        }
      } catch (_) {}
    }
    if (row == null) return (image: null, title: phone);
    final u = row;

    String pick(String key) {
      final v = u[key]?.toString().trim() ?? '';
      return (v.isEmpty || v == 'null') ? '' : v;
    }

    String? image;
    final avatar = pick('avatar_url');
    if (avatar.isNotEmpty) image = avatar;

    final custom = pick('notification_title');
    final name = pick('name');
    var label = AccountName.isGeneric(custom) ? name : custom;

    // التاجر: اسم صيدليته اسمه، ووجوهته شعاره — فلا يُترك بلا هويّة.
    final isOwner = u['is_shop_owner'] == true;
    if (isOwner && (image == null || AccountName.isGeneric(label))) {
      final shop = await fetchShopByOwnerPhone(phone);
      final shopName = shop?['name']?.toString().trim() ?? '';
      if (AccountName.isGeneric(label) && !AccountName.isGeneric(shopName)) {
        label = shopName;
      }
      if (image == null) {
        final logo = shop?['logo_image']?.toString().trim() ?? '';
        if (logo.isNotEmpty && logo != 'null') image = logo;
      }
    }

    // لم يُعرف اسمٌ حقيقي ⇒ الرقم الثابت، ولا كلمة من عندنا.
    final title = AccountName.real(name: label, phone: phone);
    return (image: image, title: title);
  }

  /// الشعار/الصورة التي تظهر داخل إشعارات هذا الحساب.
  /// [fetchNotificationBrand] هي الدالة الكاملة (الشعار + العنوان).
  Future<String?> fetchNotificationImage(String phone) async {
    final brand = await fetchNotificationBrand(phone);
    return brand.image;
  }

  /// الأعمدة المسموح للتطبيق قراءتها من `users`.
  ///
  /// ★ `password` و`pw_hash` ليسا منها — استُبعدا بشكل مقصود: المفتاح
  ///   العام (anon) مضمّن في التطبيق، فأي عمود يُقرأ هنا يقرأه كل
  ///   من يفكّ الـAPK. و`select=*` لن يعيدهما أصلاً لأن القاعدة
  ///   سحبت صلاحية القراءة عنهما.
  static const String userSelectColumns =
      'id,phone,name,avatar_url,is_active,is_admin,is_driver,'
      'is_shop_owner,fcm_token,notification_image,notification_title,'
      'created_at,updated_at';

  /// الأعمدة التي يجوز للتطبيق تعديلها مباشرةً.
  ///
  /// ★ `password` مسموح **عن قصد**: تترايجر `trg_hash_password`
  ///   تلتقطه فوراً فتحوّله إلى bcrypt وتمحو النص. أما `is_admin`
  ///   و`is_driver` و`is_active` و`is_shop_owner` فليست هنا، فلن
  ///   يستطيع anon ترقيته إلى أدمن ولو ضبط عنوان الطلب.
  static const Set<String> _userWritableColumns = {
    'name',
    'avatar_url',
    'address',
    'fcm_token',
    'notification_title',
    'notification_image',
    'password',
  };

  Future<List<Map<String, dynamic>>> fetchUsers() async {
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}users?select=$userSelectColumns&order=created_at.desc',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
      // ★ كان السطر التالي بصمت: أي خطأ (401 بلا توكن، 42501، شبكة)
      //   كان يُترجم إلى «لا يوجد مستخدمون» بلا أي أثر. فلا طريقة لمعرفة
      //   أن الأدمن لا يرى القائمة لأن الطلب رُفض، لا لأن البيانات غائبة.
      lastRpcError =
          'fetch_users HTTP ${res.statusCode}: '
          '${_shortBody(res.body)}';
    } catch (e) {
      lastRpcError = 'fetch_users failed: $e';
    }
    return [];
  }

  Future<bool> updateUser(String phone, Map<String, dynamic> values) async {
    if (phone.isEmpty || values.isEmpty) return false;
    // ★ حاجز دفاعي في العميل أيضاً: حتى لو أضاف مطور لاحقاً حقلاً
    //   حساساً إلى الخريطة، يُرفض هنا بدل أن يُرسَل للسيرفر.
    final safe = <String, dynamic>{};
    values.forEach((k, v) {
      if (_userWritableColumns.contains(k)) safe[k] = v;
    });
    if (safe.isEmpty) return false;
    try {
      final res = await _http.patch(
        Uri.parse('${_url}users?phone=eq.$phone'),
        headers: _headers,
        body: jsonEncode(safe),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// ★ تغيير صلاحية مستخدم — عبر دالة واحدة على الخادم.
  ///
  /// كان `setDriverRole` يكتب بـPATCH على `users`، والتريجر
  /// `trg_guard_user_privileges` (من `SQL_LOCKDOWN.sql`) يرفض ذلك بالخطأ
  /// 42501 لأي مستدعٍ ⇒ كانت لوحة الأدمن تعرض «تعذر» على **كل** تغيير
  /// صلاحية (مندوب، صاحب صيدلية، تفعيل/تعطيل). السبب في القاعدة لا هنا.
  ///
  /// التحقق من تسجيل الدخول — المصدر **الوحيد** للحقيقة.
  ///
  /// كان `login_screen.dart` يسحب `users?select=*` ويقارن كلمة المرور
  /// **في العميل**، أي أن كلمة مرور كل مستخدم كانت تنزل إلى الجهاز،
  /// وأي مفتاح anon كان يقرأها كلها. الآن التحقق يتم داخل القاعدة
  /// على bcrypt (cost 12) مع قفل تدريجي لكل IP، وكلمة المرور لا
  /// تُخزَّن إلا كتجزئة ولا تعود في الردّ إطلاقاً.
  ///
  /// يعيد `{ok, message, phone, name, avatar_url, is_admin, is_driver,
  /// is_shop_owner}` أو `{ok:false, message}` عند الفشل.
  Future<Map<String, dynamic>?> verifyLogin(
    String phone,
    String password,
  ) async {
    if (phone.trim().isEmpty || password.isEmpty) {
      return {'ok': false, 'message': 'رقم الهاتف أو كلمة المرور غير صحيحة'};
    }
    // أي محاولة فاشلة تُبطل التوكن القديم فوراً: لا يجوز أن يبقى توكن
    // جلسة سابقة معلّقاً على الجهاز بعد فشل تسجيل دخول.
    setSessionToken(null);
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/verify_login'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone.trim(), 'p_pass': password}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        // PostgREST يردّ 400 مع رسالة الدالة، ومنها نصّ قفل المحاولات.
        return {
          'ok': false,
          'message': _shortBody(res.body).replaceAll('{}', '').trim().isEmpty
              ? 'تعذّر التحقق من الدخول'
              : _shortBody(res.body),
        };
      }
      final decoded = jsonDecode(res.body);
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        // ★ بعد SQL_HARDEN_STAGE2 يعيد verify_login حقل session_token.
        //   نحفظه فوراً هنا فيُرفَق بكل الطلبات التالية.
        //   وقبلها (المرحلة 1 فقط) لا يوجد الحقل ⇒ تبقى الجلسة بلا توكن.
        final token = map['session_token']?.toString();
        if (map['ok'] == true && token != null && token.isNotEmpty) {
          setSessionToken(token);
        }
        return map;
      }
      return {'ok': false, 'message': 'رد غير متوقع من الخادم'};
    } catch (e) {
      return {'ok': false, 'message': 'تعذّر الاتصال: $e'};
    }
  }

  /// ★★ هل الرقم مسجّل في القاعدة أصلاً؟ — يُستدعى **بعد فشل**
  /// الدخول فقط.
  ///
  /// ★ لماذا هذا الاستدعاء منفصل عن `verify_login`؟ لأن الأخير يُبقي
  ///   رسالة واحدة بالعمد: «رقم الهاتف أو كلمة المرور غير صحيحة».
  ///   وخلطهما يمنع عدّاد الأرقام المسجّلة (من يجرّب ١٠٠ رقم ويعرف
  ///   أيها له حساب). أمّا بعد **فشل** الدخول فالمستخدم اصطدم
  ///   بجدار، وتخمينُ سبب الجدار من خارجه ليس تسريباً مفيداً لمن
  ///   يجرّب أرقاماً — بل هو ما يحتاجه ليعرف: يسجّل حساباً، أم
  ///   يدخل بالكود، أم كلمة سره ضاعت.
  ///
  /// ★ الحساب الذي أنشأه كود واتساب بلا كلمة مرور يُرجع
  ///   `has_password:false` — عرض «كلمة مرور خاطئة» له يظنّه أن
  ///   كلمة السر ضاعت، والصحيح أنه يدخل بالكود.
  ///
  /// يعيد `{exists, has_password, is_active}` أو `null` عند تعذّر
  /// الوصول (وعندها يُعرض نص الخادم الأصلي كما هو).
  Future<Map<String, dynamic>?> accountStatus(String phone) async {
    final p = phone.trim();
    if (p.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/account_status'),
            headers: _headers,
            body: jsonEncode({'p_phone': p}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['ok'] == true) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// الآن نمرّ عبر `admin_set_user_role`: تنفّذ بصلاحية مالكها، فلا يعترضها
  /// التريجر، و**تفحص أن الطالب أدمن** — فلا يغيّر نوع أي حساب إلا الأدمن.
  /// **بلا كلمة مرور** — رسالة تأكيد في التطبيق فقط.
  ///
  /// `isDriver` / `isShopOwner` / `isActive` = null تعني «اتركه كما هو».
  /// ★ لا تقبل `is_admin` عمداً: ترقية أي حساب إلى أدمن تبقى ممنوعة.
  Future<Map<String, dynamic>?> adminSetUserRole(
    String phone, {
    bool? isDriver,
    bool? isShopOwner,
    bool? isActive,
  }) async {
    if (phone.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_set_user_role'),
            headers: _headers,
            body: jsonEncode({
              'p_phone': phone,
              'p_is_driver': isDriver,
              'p_is_shop_owner': isShopOwner,
              'p_is_active': isActive,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        // ★ لا نبتلع السبب. ردّ PostgREST يسمّي ما ينقص بالضبط
        //   (الدالة غير موجودة، أو الصلاحية ممنوحة، أو اسم خاطئ)،
        //   و«تعذّر الاتصال» وحدها كانت تخفي الثلاثة.
        return {
          'ok': false,
          'error': 'الخطأ ${res.statusCode}: ${_shortBody(res.body)}',
        };
      }
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {'ok': false, 'error': 'رد غير متوقع من الخادم'};
    } catch (e) {
      return {'ok': false, 'error': 'تعذّر الاتصال: $e'};
    }
  }

  /// ردّ الخادم في سطر واحد قصير، للعرض في رسالة واحدة.
  static String _shortBody(String body, [int max = 170]) {
    var s = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return '(بدون نص)';
    if (s.length > max) s = '${s.substring(0, max)}…';
    return s;
  }

  /// تغيير كلمة مرور بعد تأكيد ملكية الرقم بكود واتساب.
  ///
  /// الكتابة كلها داخل القاعدة في `reset_password_reason` (انظر
  /// `SQL_FIX_PASSWORD_RESET.sql`)، فالدالة تتحقق من توقيع التوكن الذي
  /// أصدره خادم واتساب بعد تأكيد الكود، ثم تكتب الكلمة الجديدة في العمود
  /// `password` لسطر الحساب نفسه فيتولاها ترايجر التجزئة — تختفي القديمة
  /// ولا يبقى لها أثر، ولا تُترك كلمة المرور نصّاً.
  ///
  /// ★ الردّ **خريطة** لا `bool`: `{'ok': true, 'name': …, 'phone': …}` عند
  ///   النجاح، و`{'ok': false, 'error': '<CODE>'}` عند الرفض، ليُقال للزبون
  ///   سبب التعذّر («الكود انتهى»، «لا حساب بهذا الرقم») لا «تعذّر الحفظ»
  ///   وحدها كما كان. رموز المسار نفسه: `HTTP_404` و`LEGACY_FUNCTION`
  ///   و`EXCEPTION`.
  ///
  ///   الهواتف التي لم تُحدَّث بعد تستدعي `reset_password_with_token` —
  ///   وهي غلاف `boolean` على نفس الدالة، فالاستعادة تصلها من يوم تشغيل
  ///   الملف ولا تنتظر بناءً.
  Future<Map<String, dynamic>> resetPassword({
    required String phone,
    required String newPassword,
    required String resetToken,
  }) async {
    final cleanPhone = phone.trim();
    // لا رحلة شبكة بطلب لن تقبله القاعدة أصلاً.
    if (cleanPhone.isEmpty) return const {'ok': false, 'error': 'BAD_PHONE'};
    if (resetToken.isEmpty) {
      return const {'ok': false, 'error': 'MISSING_TOKEN'};
    }
    if (newPassword.isEmpty) {
      return const {'ok': false, 'error': 'PW_SHORT'};
    }

    // ★ الترخيص داخل القاعدة لا في الطرف: التوقيع من خادم واتساب + آخر ٩
    //   أرقام + استعمال واحد، فحذف حقل الكود من الـAPK لا يفيد أحداً.
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/reset_password_reason'),
            headers: _headers,
            body: jsonEncode({
              'p_phone': cleanPhone,
              'p_token': resetToken,
              'p_new_password': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint(
          'RESET_PW => HTTP ${res.statusCode} '
          'body=${_shortBody(utf8.decode(res.bodyBytes))}',
        );
        return {'ok': false, 'error': 'HTTP_${res.statusCode}'};
      }

      final body = utf8.decode(res.bodyBytes).trim();
      final decoded = body.isEmpty ? null : jsonDecode(body);

      // الدالة ترجع jsonb فيها `ok` و`error` — وهو كل ما تحتاجه الشاشة.
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        debugPrint('RESET_PW => ${_shortBody(jsonEncode(map))}');
        return map;
      }

      // نصّ لا يشبه jsonb (WAF أو وسيط عدّل الردّ): لا نوهم الزبون بنجاح.
      debugPrint('RESET_PW => غير متوقع "$body"');
      return const {'ok': false, 'error': 'BAD_RESPONSE'};
    } catch (e) {
      debugPrint('RESET_PW => exception $e');
      return const {'ok': false, 'error': 'EXCEPTION'};
    }
  }

  /// لم يعد هناك حاجة لمسح التوكن من الحسابات الأخرى: جدول الأجهزة صار
  /// يقبل نفس التوكن لعدة حسابات (المفتاح = الحساب + التوكن)، حتى يبقى
  /// توكن كل حساب محفوظاً دائماً على هذا الجهاز.
  ///
  /// نبقي الدالة موجودة (قد تستدعيها شاشات قديمة) لكنها لا تفعل شيئاً.
  Future<void> clearFcmTokenElsewhere(String token, String keepPhone) async {
    if (token.isEmpty || keepPhone.isEmpty) return;
  }

  /// ★ كان `DELETE` على `users?phone=eq.<phone>` بالمفتاح العام.
  ///   أي أن أي شخص — بلا حساب ولا كلمة مرور — كان يحذف أي مستخدم
  ///   بطلب HTTP واحد (تم اختباره: حساب حُذف فعلاً بالمفتاح العام).
  ///   الآن الحذف يمرّ عبر `admin_delete_user`، وهي دالة
  ///   `security definer` لا تقبل إلا كلمة مرور أدمن صحيحة
  ///   (bcrypt) — نفس نمط `admin_create_discount_code` المستخدم
  ///   في شاشات الأدمن الأخرى.
  Future<bool> deleteUser(String phone, {required String adminPassword}) async {
    if (phone.isEmpty || adminPassword.isEmpty) return false;
    final res = await rpcCall('admin_delete_user', {
      'p_phone': phone,
      'p_admin_password': adminPassword,
    });
    return res is Map && res['ok'] == true;
  }

  /// ★★ **حذف الزبون حسابه بنفسه** — `delete_own_account()` من
  ///   `SQL_DELETE_ACCOUNT.sql`.
  ///
  ///   بلا أي وسائط عمداً: الرقم يُؤخذ من **توكن الجلسة** داخل القاعدة
  ///   (`app_verify_token(app_request_token())`)، فلا يملك متصلٌ — ولو
  ///   بيده مفتاح anon — أن يحذف حساباً غيره بطلب HTTP واحد. هذا هو
  ///   الباب الذي كان مفتوحاً قبل `admin_delete_user` وأُغلق.
  ///
  ///   تُرجع ردّ الخادم كما هو: `{ok, deleted_phone, orders_removed,
  ///   blocked_until, message}` أو `{ok:false, error}` — والشاشة تعرض
  ///   `error`/`message` ولا تختلق نجاحاً كاذباً.
  Future<Map<String, dynamic>> deleteOwnAccount() async {
    final res = await rpcCall(
      'delete_own_account',
      const {},
      timeoutSeconds: 30,
    );
    if (res is Map) return Map<String, dynamic>.from(res);
    return {
      'ok': false,
      'error': (lastRpcError ?? '').isEmpty
          ? 'تعذّر حذف الحساب، حاول مرة أخرى'
          : lastRpcError!,
    };
  }

  /// ★ حالة «هذا الرقم محذوف»: الخادم يرد `blocked = true` مع
  ///   `blocked_until` حتى **ثلاث ساعات** بعد الحذف — فيُمنع الدوران
  ///   على نفس الرقم بحساب جديد، ثم يرجع طبيعياً.
  Future<Map<String, dynamic>> accountDeletionState(String phone) async {
    final p = phone.trim();
    if (p.isEmpty) return const {'blocked': false};
    final res = await rpcCall('account_deletion_state', {
      'p_phone': p,
    }, timeoutSeconds: 10);
    if (res is Map) return Map<String, dynamic>.from(res);
    // لا دليل ⇒ لا منع: خطأ شبكة أو ملف SQL لم يُشغَّل ليس سبباً
    // لإقفال باب الدخول على الناس.
    return const {'blocked': false};
  }

  // ==========================================================
  //  الأقسام
  // ==========================================================

  Future<List<Map<String, dynamic>>> fetchCategories() async {
    try {
      // ترتيب ثابت ومقصود: `sort_order` ثم الأقدم. بلا order كانت
      // PostgreSQL ترجع الصفوف بترتيب غير مضمون، فكان «القسم الافتراضي»
      // في نموذج إضافة المنتج قفزة عشوائية بين قسم وآخر.
      final res = await _http
          .get(
            Uri.parse(
              '${_url}categories?select=id,name_ar,name_en,icon_name,color_hex,image_url,image_path,shop_id,is_active'
              '&order=sort_order.asc,created_at.asc',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return [];
  }

  static const String _doctorSelectBase =
      'id,name,title,specialty,info,phone,image_path,area,category,'
      'is_featured,is_hero,is_verified,is_active';

  /// أعمدة البروفايل تأتي من tmp/doctors_profile.sql؛ قراءتها قبل تشغيل
  /// الملف تُرجع 400، فنرجع للقراءة الأساسية بدل إظهار دليل فارغ.
  static const String _doctorSelectProfile =
      '$_doctorSelectBase,city,bio,working_hours,notes,clinic_address,'
      'facebook_url';

  /// `secretary_phone` يأتي من SQL_DOCTOR_SECRETARY_WALLET.sql — يُقرأ
  /// بطبقة أعلى: إن لم يُشغَّل الملف بعد يسقط هذا الاختيار وحده وتبقى
  /// أعمدة البروفايل كلها (لا نُسقط كل شيء لعمود واحد).
  static const String _doctorSelectProfileWithSecretary =
      '$_doctorSelectProfile,secretary_phone';

  /// `cover_url` يأتي من tmp/doctors_cover.sql — طبقة أعلى من السكرتير،
  /// فقبل تشغيل الملف يسقط هذا الاختيار ويبقى السكرتير وأعمدة البروفايل.
  static const String _doctorSelectWithCover =
      '$_doctorSelectProfileWithSecretary,cover_url';

  static const Set<String> _doctorProfileKeys = {
    'city',
    'bio',
    'working_hours',
    'notes',
    'clinic_address',
    'facebook_url',
    'secretary_phone',
    'cover_url',
  };

  /// دليل الأطباء والمجمعات والمختبرات (جدول `doctors`) — قراءة عامة.
  ///
  /// ★ إضافة 2026-11-19: جدول عرض جديد بسياسات select فقط؛ سقوط
  ///   الطلب (قبل أن يضغط الأدمن Run على tmp/doctors_table.sql مثلاً)
  ///   يعيد قائمة فارغة فتُعرض حالة «الدليل قريباً» — لا استثناء ينهار.
  ///
  /// [includeInactive] للأدمن وحده: يعيد الملفات المخفية أيضاً، فلا يضيع
  /// صفّ «إرجاع إلى زبون» ولا تُنشأ نسخة مكرّرة عند إعادة التحويل.
  /// مثل [fetchDoctors] لكنها تفرّق بين «نجاح بلا صفوف» و«فشل النقل»:
  /// `[]` = الجدول فارغ فعلاً (حُذف كل الأطباء)، و`null` = تعذّر الجلب.
  /// ★ ضروري للكاش: نتيجة فارغة حقيقية يجب أن تُفرّغه، وفشل الشبكة
  ///   يجب ألا يمسح ما هو معروض.
  Future<List<Map<String, dynamic>>?> fetchDoctorsOrNull({
    bool includeInactive = false,
  }) async {
    final cover = await _fetchDoctorsSelect(
      _doctorSelectWithCover,
      includeInactive: includeInactive,
    );
    if (cover != null) return cover;
    final full = await _fetchDoctorsSelect(
      _doctorSelectProfileWithSecretary,
      includeInactive: includeInactive,
    );
    if (full != null) return full;
    final profile = await _fetchDoctorsSelect(
      _doctorSelectProfile,
      includeInactive: includeInactive,
    );
    if (profile != null) return profile;
    return _fetchDoctorsSelect(
      _doctorSelectBase,
      includeInactive: includeInactive,
    );
  }

  Future<List<Map<String, dynamic>>> fetchDoctors({
    bool includeInactive = false,
  }) async {
    final cover = await _fetchDoctorsSelect(
      _doctorSelectWithCover,
      includeInactive: includeInactive,
    );
    if (cover != null) return cover;
    final full = await _fetchDoctorsSelect(
      _doctorSelectProfileWithSecretary,
      includeInactive: includeInactive,
    );
    if (full != null) return full;
    final profile = await _fetchDoctorsSelect(
      _doctorSelectProfile,
      includeInactive: includeInactive,
    );
    if (profile != null) return profile;
    final base = await _fetchDoctorsSelect(
      _doctorSelectBase,
      includeInactive: includeInactive,
    );
    return base ?? const [];
  }

  Future<List<Map<String, dynamic>>?> _fetchDoctorsSelect(
    String select, {
    bool includeInactive = false,
  }) async {
    final visibility = includeInactive ? '' : '&is_active=eq.true';
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}doctors?select=$select$visibility'
              '&order=is_hero.desc,is_featured.desc,sort_order.asc,created_at.asc',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return null;
  }

  /// إضافة طبيب/مجمع/مختبر — كتابة أدمن فقط.
  /// ★ تتطلب سياسات `doctors_admin_*` في tmp/doctors_table.sql؛ بلاها
  ///   يرفضها RLS ويُظهر [lastAdminError] السبب الحقيقي.
  Future<bool> addDoctor({
    required String name,
    String title = '',
    String specialty = '',
    String info = '',
    String phone = '',
    String area = '',
    String city = '',
    String category = 'doctors',
    String? imagePath,
    bool isFeatured = false,
    bool isVerified = false,
    String bio = '',
    String workingHours = '',
    String notes = '',
    String clinicAddress = '',
    String facebookUrl = '',
    String secretaryPhone = '',
    String coverUrl = '',
  }) async {
    lastAdminError = '';
    if (name.trim().isEmpty) {
      lastAdminError = 'اسم الطبيب فارغ';
      return false;
    }
    final body = <String, dynamic>{
      'name': name.trim(),
      'title': title.trim(),
      'specialty': specialty.trim(),
      'info': info.trim(),
      'phone': phone.trim(),
      'area': area.trim(),
      'city': city.trim(),
      'category': category,
      'image_path': (imagePath == null || imagePath.trim().isEmpty)
          ? ''
          : imagePath.trim(),
      'is_featured': isFeatured,
      'is_hero': false,
      'is_verified': isVerified,
      'is_active': true,
      'sort_order': 100,
      'bio': bio.trim(),
      'working_hours': workingHours.trim(),
      'notes': notes.trim(),
      'clinic_address': clinicAddress.trim(),
      'facebook_url': facebookUrl.trim(),
      // رقم سكرتير العيادة: من يسجّل دخوله به يصله إشعار الحجز الجديد
      // ويستطيع الموافقة أو الرفض (SQL_DOCTOR_SECRETARY_WALLET.sql).
      'secretary_phone': secretaryPhone.trim(),
      // غلاف البروفايل — يضعه الأدمن وحده (tmp/doctors_cover.sql).
      'cover_url': coverUrl.trim(),
    };
    try {
      var res = await _http
          .post(
            Uri.parse('${_url}doctors'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      // قبل تشغيل tmp/doctors_profile.sql: نعيد المحاولة بلا أعمدة
      // البروفايل حتى تبقى إضافة الطبيب تعمل.
      if (res.statusCode == 400 && res.body.contains('42703')) {
        body.removeWhere((k, _) => _doctorProfileKeys.contains(k));
        res = await _http
            .post(
              Uri.parse('${_url}doctors'),
              headers: _headers,
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 12));
      }
      _logAdminHttp('addDoctor', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  Future<bool> updateDoctor(
    String doctorId,
    Map<String, dynamic> values,
  ) async {
    lastAdminError = '';
    if (doctorId.isEmpty || values.isEmpty) {
      lastAdminError = 'طلب تحديث ناقص';
      return false;
    }
    try {
      final body = Map<String, dynamic>.from(values);
      var res = await _http
          .patch(
            Uri.parse('${_url}doctors?id=eq.$doctorId'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      // نفس احتياط الإضافة: بلا أعمدة البروفايل يبقى التعديل يعمل.
      if (res.statusCode == 400 && res.body.contains('42703')) {
        body.removeWhere((k, _) => _doctorProfileKeys.contains(k));
        res = await _http
            .patch(
              Uri.parse('${_url}doctors?id=eq.$doctorId'),
              headers: _headers,
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 12));
      }
      _logAdminHttp('updateDoctor id=$doctorId', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        try {
          final updated = jsonDecode(res.body);
          if (updated is List && updated.isNotEmpty) return true;
          lastAdminError = 'لم يتغيّر أي صف — راجع سياسات الأمان';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  Future<bool> deleteDoctor(String doctorId) async {
    lastAdminError = '';
    if (doctorId.isEmpty) {
      lastAdminError = 'معرّف الطبيب فارغ';
      return false;
    }
    try {
      final res = await _http
          .delete(
            Uri.parse('${_url}doctors?id=eq.$doctorId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('deleteDoctor id=$doctorId', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        try {
          final deleted = jsonDecode(res.body);
          if (deleted is List && deleted.isNotEmpty) return true;
          lastAdminError =
              'منع الحذف سياسة الأمان (RLS) — شغّل tmp/doctors_table.sql';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  /// أقسام دليل الأطباء (شرائح الرئيسية) — قراءة عامة من `doctor_categories`.
  ///
  /// ★ جدول جديد في SQL_DOCTOR_DIRECTORY_CATEGORIES.sql؛ قبل تشغيله يعيد
  ///   فشل الجلب قائمة فارغة، فتستخدم الخدمة الثلاثة الأساسية بلا كسر.
  Future<List<Map<String, dynamic>>> fetchDoctorCategories() async {
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}doctor_categories?select=key,label'
              '&is_active=eq.true&order=sort_order.asc,created_at.asc',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return const [];
  }

  /// إضافة قسم دليل أطباء — أدمن فقط (سياسة `doctor_categories_admin_*`).
  Future<bool> addDoctorCategory({
    required String key,
    required String label,
    int sortOrder = 100,
  }) async {
    lastAdminError = '';
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}doctor_categories'),
            headers: _headers,
            body: jsonEncode({
              'key': key,
              'label': label.trim(),
              'sort_order': sortOrder,
              'is_active': true,
            }),
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('addDoctorCategory $key', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      _captureAdminError(res.statusCode, res.body);
      if (lastAdminError.contains('PGRST205') ||
          lastAdminError.contains('doctor_categories')) {
        lastAdminError =
            'جدول الأقسام غير منشأ — شغّل SQL_DOCTOR_DIRECTORY_CATEGORIES.sql';
      }
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  /// حذف قسم أضافه الأدمن. القسم الأساسي أو الذي فيه أطباء يرفضه الخادم
  /// (قيد المفتاح الأجنبي) وتُعرض الرسالة الحقيقية.
  Future<bool> deleteDoctorCategory(String key) async {
    lastAdminError = '';
    if (key.isEmpty) {
      lastAdminError = 'معرّف القسم فارغ';
      return false;
    }
    try {
      final res = await _http
          .delete(
            Uri.parse('${_url}doctor_categories?key=eq.$key'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('deleteDoctorCategory $key', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        try {
          final deleted = jsonDecode(res.body);
          if (deleted is List && deleted.isNotEmpty) return true;
          lastAdminError = 'لم يُحذف أي قسم — راجع سياسات الأمان';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      if (lastAdminError.contains('foreign key')) {
        lastAdminError = 'القسم فيه أطباء — انقلهم لقسم آخر قبل الحذف';
      }
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  /// تحديث قسم دليل أطباء (ترتيب/اسم/إظهار) — أدمن فقط.
  /// `null` = لا تغيّر الحقل. يعيد true إذا عُدّل صف واحد على الأقل.
  Future<bool> updateDoctorCategory(
    String key, {
    String? label,
    int? sortOrder,
    bool? isActive,
  }) async {
    lastAdminError = '';
    if (key.isEmpty) {
      lastAdminError = 'معرّف القسم فارغ';
      return false;
    }
    final body = <String, dynamic>{
      if (label != null) 'label': label.trim(),
      'sort_order': ?sortOrder,
      'is_active': ?isActive,
    };
    if (body.isEmpty) return true;
    try {
      final res = await _http
          .patch(
            Uri.parse('${_url}doctor_categories?key=eq.$key'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('updateDoctorCategory $key', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        try {
          final updated = jsonDecode(res.body);
          if (updated is List && updated.isNotEmpty) return true;
          lastAdminError = 'لم يُحدَّث أي قسم — راجع سياسات الأمان';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  Future<bool> addCategory({
    required String name,
    String? imageUrl,
    String? imagePath,
    String? shopId,
  }) async {
    lastAdminError = '';
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}categories'),
            headers: _headers,
            body: jsonEncode({
              'name_ar': name,
              'image_url': imageUrl ?? imagePath,
              'image_path': imagePath,
              // القسم يُربط بصيدلية واحد فقط؛ null = قسم عام لكل الصيدليات.
              'shop_id': (shopId == null || shopId.isEmpty) ? null : shopId,
              'is_active': true,
            }),
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('addCategory', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  /// تعديل قسم (منها ربطه بصيدلية).
  Future<bool> updateCategory(
    String categoryId,
    Map<String, dynamic> values,
  ) async {
    if (categoryId.isEmpty || values.isEmpty) return false;
    try {
      final res = await _http.patch(
        Uri.parse('${_url}categories?id=eq.$categoryId'),
        headers: _headers,
        body: jsonEncode(values),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// ★ سبب آخر فشل في حذف — يُعرض للمستخدم بدل «تم» الكاذبة.
  String lastDeleteError = '';

  /// ★ سبب آخر فشل في عمليات لوحة الأدمن (بانرات / أقسام).
  ///
  /// كان الفشل هنا يُبتلع فيعود `false` واحداً لكل الأسباب وتقول
  /// الشاشة «تعذر…» — RLS يمنع؟ عمود ناقص؟ شبكة؟ كلها شيء واحد.
  /// الآن يُقرأ جسم رد PostgREST ({message, hint}) ويُعرض في الشاشة.
  String lastAdminError = '';

  /// يقرأ السبب الحقيقي من جسم رد PostgREST ويضعه في [lastAdminError].
  void _captureAdminError(int status, String body) {
    var msg = 'HTTP $status';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final m = (decoded['message'] ?? decoded['error'] ?? '').toString();
        final h = (decoded['hint'] ?? '').toString();
        if (m.isNotEmpty) msg = m;
        if (h.isNotEmpty) msg = '$msg ($h)';
      }
    } catch (_) {}
    lastAdminError = msg;
  }

  /// ★ تسجيل تشخيصي في logcat لعمليات لوحة الأدمن (إضافة/حذف بانر وقسم):
  ///   `adb logcat -s flutter` يعرض الحالة الفعلية وجسم رد PostgREST،
  ///   لأن رسالة الشاشة (SnackBar) تختفي بعد ثوانٍ ولا يمكن التقاطها لاحقاً.
  void _logAdminHttp(String op, int status, String body) {
    final b = body.length > 400 ? '${body.substring(0, 400)}…' : body;
    debugPrint('ADMIN_HTTP $op => HTTP $status body=$b');
  }

  /// التوكن الذي أعاده خادم الرموز بعد التحقق، يُستخدم مرة واحدة
  ///  في loginWithToken ثم يُبطَل فلا يبقى في الذاكرة بعدها.
  String? _pendingWaToken;

  /// استدعاء دالة حذف ترجع jsonb فتعطي السبب الحقيقي.
  ///
  /// ★ لماذا لا `DELETE` مباشر:
  ///   PostgREST يرجع **200 بجسم فارغ** حتى حين يمنع RLS أو المفتاح
  ///   الأجنبي الحذف ⇒ الكود القديم كان `return statusCode < 300`
  ///   فيُعلن النجاح بينما لم يُحذف صف واحد.
  ///   الدالة داخل القاعدة تتحقق وتُرجع `ok:true/false` مع السبب.
  Future<bool> _callDelete(String fn, Map<String, dynamic> args) async {
    final ok = await _callDeleteQuiet(fn, args);
    if (ok) {
      // ★ ٢٠٢٦-١١-٠٦: الحذف لا يظهر في نافذة الواشر — الصف يختفي
      //   منها فلا يُرى فيه «تغيّر». كان الاعتماد على دورة الاستطلاع؛
      //   و لمّا صار للواشر بوابة تكتفي بالقياس صار أسوأ حال للحذف
      //   دقيقةً (المسح الإلزامي). هذه النبضة تلغي الانتظار كله،
      //   و هي إلى VPS لا إلى Supabase ⇒ صفر بايت من الحصة.
      unawaited(pokeNotifyServer('deleted:$fn'));
    }
    return ok;
  }

  Future<bool> _callDeleteQuiet(String fn, Map<String, dynamic> args) async {
    lastDeleteError = '';
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/$fn'),
            headers: _headers,
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        final data = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : const <String, dynamic>{};
        if (data['ok'] == true) return true;

        final err = (data['error'] ?? '').toString();
        lastDeleteError = _friendlyDeleteError(err, data);
        return false;
      }

      lastDeleteError = 'HTTP ${res.statusCode}';
      return false;
    } catch (e) {
      lastDeleteError = e.toString();
      return false;
    }
  }

  /// ★ مثل [_callDelete] لكنه يعيد جسم الردّ كاملاً لا نجاح/فشل فقط.
  ///
  ///   لماذا؟ حذف الصيدلية صار مرحلتين (طلب 2026-10-10): الدالة في الوضع
  ///   الآمن ترجع **الأثر** — كم طلباً ومنتجاً وقسماً ومدفوعة ستُمحى —
  ///   فتبنيه الشاشة في نافذة تأكيد واحدة، ثم تعيد الطلب بالحذف المؤكَّد.
  ///   `false/true` وحده لا يكفي لعرض الأرقام.
  ///
  ///   المهلة أطول (٢٥ث) من بقية دوال الحذف: الحذف المؤكَّد يمسح سطور
  ///   طلبات ومنتجات وأقسامات في رحلة واحدة.
  Future<Map<String, dynamic>> _callRpcJson(
    String fn,
    Map<String, dynamic> args,
  ) async {
    lastDeleteError = '';
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/$fn'),
            headers: _headers,
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 25));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        return decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : const <String, dynamic>{};
      }

      lastDeleteError = 'HTTP ${res.statusCode}';
      return {'ok': false, 'error': 'HTTP_${res.statusCode}'};
    } catch (e) {
      lastDeleteError = e.toString();
      return const {'ok': false, 'error': 'EXCEPTION'};
    }
  }

  static String _friendlyDeleteError(String code, Map<String, dynamic> data) {
    switch (code) {
      case 'NO_SESSION':
        return 'انتهت الجلسة - أعد تسجيل الدخول';
      case 'NOT_DRIVER':
        return 'هذا الحساب ليس حساب مندوب';
      case 'NOT_ACTIVE':
        return 'حسابك موقوف - راجع الإدارة';
      case 'NO_USER':
        // بوابة الكتالوج (catalog_gate) تقرأ جدول المستخدمين — لا صفّ له
        return 'لا يوجد حساب بهذا الرقم - راجع الإدارة';
      case 'NOT_FOUND':
        return 'العنصر لم يعد موجوداً';
      case 'NOT_ADMIN':
        // ★ عام: حذف الصيدلية للأدمن، وحذف منتج/قسم للأدمن أو صاحب الصيدلية.
        return 'الحذف للأدمن أو صاحب الصيدلية';
      case 'SHOP_HAS_ORDERS':
        // ★ لم يعد طريقاً مسدوداً: الشاشة تعرض هذا الأثر وتكمل بالحذف
        //   المؤكَّد (طلب 2026-10-10: «احذفه فوراً» بدل «عطّله بدل حذفه»).
        final n = (data['orders'] ?? 0).toString();
        return 'له $n طلباً — سيُحذف معها';
      case 'BAD_ARGUMENT':
        return 'طلب غير صالح';
    }
    return code.isEmpty ? 'تعذّر الحذف - حاول مرة أخرى' : code;
  }

  Future<bool> deleteCategory(String categoryId) async {
    if (categoryId.isEmpty) return false;
    return _callDelete('delete_category', {'p_category': categoryId});
  }

  // ==========================================================
  //  الصيدليات
  // ==========================================================

  /// صيدليات الكتالوج. `is_active=false` تعني «مخفية عن الزبائن» (صاحبها
  /// أُعيد زبوناً): الصف ومنتجاته ومحفظته يبقون، ويعود الظهور عند التحويل.
  ///
  /// ★ قبل تشغيل `tmp/shop_visibility.sql` لا يوجد العمود، فيرجع الطلب
  ///   400 برمز 42703 — نعيد المحاولة بلا العمود بدل كتالوج فارغ.
  Future<List<Map<String, dynamic>>> fetchShops() async {
    ApiMetrics.hit('shops');
    const select =
        'id,name,category_id,logo_image,image_path,'
        'background_color,delivery_fee,'
        'delivery_fee_amount,special_note,is_open,working_hours,working_days,'
        'owner_phone,created_at';
    try {
      var res = await _http
          .get(
            Uri.parse(
              '${_url}shops?select=$select,is_active,directory_keys'
              '&order=created_at.desc',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      // قبل تشغيل SQL_SHOP_DIRECTORY_KEYS.sql العمود غير موجود: نرجع
      // تدريجياً بدل صيدليات فارغة.
      if (res.statusCode == 400 && res.body.contains('42703')) {
        res = await _http
            .get(
              Uri.parse(
                '${_url}shops?select=$select,is_active'
                '&order=created_at.desc',
              ),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 12));
      }
      if (res.statusCode == 400 && res.body.contains('42703')) {
        res = await _http
            .get(
              Uri.parse('${_url}shops?select=$select&order=created_at.desc'),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 12));
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return [];
  }

  Future<Map<String, dynamic>?> fetchShopById(String shopId) async {
    if (shopId.isEmpty) return null;
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}shops?select=*&id=eq.$shopId&limit=1'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return null;
        return Map<String, dynamic>.from(list.first as Map);
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> fetchShopByOwnerPhone(String ownerPhone) async {
    if (ownerPhone.isEmpty) return null;
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}shops?select=*&owner_phone=eq.$ownerPhone&limit=1',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return null;
        return Map<String, dynamic>.from(list.first as Map);
      }
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> fetchShopOwners() async {
    final users = await fetchUsers();
    return users.where((u) => u['is_shop_owner'] == true).toList();
  }

  Future<bool> addShop({
    required String name,
    String? imageUrl,
    String? imagePath,
    String? categoryId,
    String? categoryName,
    String? ownerPhone,
  }) async {
    try {
      final res = await _http.post(
        Uri.parse('${_url}shops'),
        headers: _headers,
        body: jsonEncode({
          'name': name,
          'logo_image': imageUrl ?? imagePath,
          'image_path': imagePath,
          'category_id': (categoryId == null || categoryId.isEmpty)
              ? null
              : categoryId,
          'owner_phone': (ownerPhone == null || ownerPhone.trim().isEmpty)
              ? null
              : ownerPhone.trim(),
          'is_open': true,
        }),
      );
      _logAdminHttp('addShop', res.statusCode, res.body);
      // ★ فحص صادق: 401/42501 يعني RLS منع الإدراج (لا سياسة INSERT).
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return true;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// ★ ينقل الصيدلية إلى قسم: يربط الاتجاهين معاً في عملية واحدة.
  ///
  /// `shops.category_id = section` + `categories.shop_id = shop`.
  /// الربط في الاتجاهين هو ما يجعل الصيدلية **ومنتجاته** يظهران في القسم،
  /// ومproducts بلا قسم تُورَث قسم صيدليتها.
  ///
  /// يمرّ عبر دالة `link_shop_category` (انظر `SQL_LINK_SHOP_CATEGORY.sql`)
  /// بدل PATCH على `categories.shop_id` مباشرة، لأن ذلك العمود محميّ
  /// بـ`SQL_LOCKDOWN.sql`. إن لم تكن الدالة منصّبة بعد، نُرجع `false`
  /// ولا نكسر العملية: `shops.category_id` كُتب أصلاً مع الإنشاء.
  Future<bool> linkShopCategory(String shopId, String categoryId) async {
    if (shopId.isEmpty || categoryId.isEmpty) return false;
    try {
      await rpcRows('link_shop_category', {
        'p_shop_id': shopId,
        'p_category_id': categoryId,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> updateShop(String shopId, Map<String, dynamic> values) async {
    if (shopId.isEmpty || values.isEmpty) return false;
    try {
      final res = await _http.patch(
        Uri.parse('${_url}shops?id=eq.$shopId'),
        headers: _headers,
        body: jsonEncode(values),
      );
      _logAdminHttp('updateShop id=$shopId', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        // مع return=representation: `[]` = لم يتغيّر أي صف (RLS/فلتر).
        try {
          final updated = jsonDecode(res.body);
          if (updated is List && updated.isNotEmpty) return true;
          lastAdminError = 'لم يتغيّر أي صف — راجع سياسات الأمان';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// يحفظ صورة الصيدلية في قاعدة البيانات.
  ///
  /// نكتب **ثلاثة** أعمدة عمداً — `logo_image` و `image_path` و `logo_path`:
  ///  - `fetchShops()` يقرأ `logo_image` ثم `image_path`.
  ///  - `fetchShopById()` و `fetchNotificationBrand()` يستخدمان `select=*`.
  ///  - `logo_path` موجود في المخطط لكن **لا أحد يقرأه ولا يكتبه**، فإذا
  ///    تُرك بلا تحديث ينافس العمودين الآخرين ويختلف المصدر الحقيقة.
  ///
  /// [imageUrl] = `null` يمسح الصورة (يكتب null صراحةً، لا يتجاهلها).
  Future<bool> updateShopImage(String shopId, String? imageUrl) async {
    if (shopId.isEmpty) return false;
    final v = (imageUrl != null && imageUrl.trim().isNotEmpty)
        ? imageUrl.trim()
        : null;
    try {
      final res = await _http.patch(
        Uri.parse('${_url}shops?id=eq.$shopId'),
        headers: _headers,
        body: jsonEncode({
          'logo_image': v,
          'image_path': v,
          'logo_path': v,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      lastOrderError = _shortServerError(res.body);
      return false;
    } catch (e) {
      lastOrderError = 'تعذر الاتصال بالسيرفر: $e';
      return false;
    }
  }

  Future<bool> updateShopWorkingHours(
    String shopId, {
    String? openTime,
    String? closeTime,
    String? workingDays,
    bool? isOpen,
  }) async {
    final values = <String, dynamic>{};
    if (openTime != null && closeTime != null) {
      values['working_hours'] = '$openTime - $closeTime';
    }
    if (workingDays != null && workingDays.isNotEmpty) {
      values['working_days'] = workingDays;
    }
    if (isOpen != null) values['is_open'] = isOpen;
    return updateShop(shopId, values);
  }

  /// ★ تغيير اسم الصيدلية — **عبر دالة في القاعدة**، لا PATCH على `shops`.
  ///
  /// الاسم محفوظ أربع مرات: `shops.name` (الحقيقة)، `products.shop_name`
  /// (بطاقة المنتج)، `order_items.shop_name` (**مفتاح ربط** محفظة التاجر
  /// وبطاقته)، و`shop_earnings.shop_name`. تعديل `shops` وحده يُبقي
  /// الثلاثة على الاسم القديم فتصير أرقام المحفظة **صفراً** — لذا الطلب
  /// كله يذهب إلى `admin_rename_shop` التي تُحدّث النسخ الأربع في
  /// معاملة واحدة وترفض الاسم المكرر. انظر `SQL_ADMIN_RENAME_SHOP.sql`.
  ///
  /// يعيد جسم الدالة خاماً: `{'ok': true, 'name': ..., 'products': 3,
  /// 'order_items': 12, 'sections': 1, ...}` أو `{'ok': false, 'error': ...}`.
  Future<Map<String, dynamic>> renameShop(String shopId, String newName) async {
    if (shopId.isEmpty) return const {'ok': false, 'error': 'BAD_ARGUMENT'};
    final data = await _callRpcJson('admin_rename_shop', {
      'p_shop': shopId,
      'p_new_name': newName,
    });
    debugPrint(
      'SHOP_RENAME $shopId => ok=${data['ok']} '
      'name="${data['name'] ?? ''}" error="${data['error'] ?? ''}" '
      'products=${data['products'] ?? 0} items=${data['order_items'] ?? 0} '
      'sections=${data['sections'] ?? 0}',
    );
    return data;
  }

  /// حذف صيدلية — بمرحلتين حسب [force].
  ///
  /// ★ `force: false` (الافتراضي) = **استطلاع الأثر**: الدالة في القاعدة
  ///   لا تحذف متى كان للصيدلية طلبات، بل ترجع أرقام ما سيُمحى
  ///   (`orders`, `products`, `categories`, `payouts`, `paid`).
  /// ★ `force: true` = حذف كامل فوراً: الصيدلية ومنتجاته وأقسامه وسطور
  ///   طلباته والطلبات التي صارت بلا سطور، مع إبطال مدفوعات المالك
  ///   (`voided = true`) حتى لا يطلع الرصيد سالباً.
  ///
  /// يعيد الجسم الخام: `{'ok': true, 'deleted_orders': 3, ...}` أو
  /// `{'ok': false, 'error': 'SHOP_HAS_ORDERS', 'orders': 3, ...}`.
  /// عند النجاح يعيد أيضاً `logo` و`logo_path` ليُحذف الشعار من السحابة.
  Future<Map<String, dynamic>> deleteShopDetailed(
    String shopId, {
    bool force = false,
  }) async {
    if (shopId.isEmpty) return const {'ok': false, 'error': 'BAD_ARGUMENT'};
    final data = await _callRpcJson('delete_shop', {
      'p_shop': shopId,
      'p_force': force,
    });
    if (data['ok'] != true) {
      lastDeleteError = _friendlyDeleteError(
        (data['error'] ?? '').toString(),
        data,
      );
    }
    return data;
  }

  /// النسخة القديمة (bool) — باقية لأية نداءات لا تحتاج الأثر.
  Future<bool> deleteShop(String shopId) async {
    if (shopId.isEmpty) return false;
    return _callDelete('delete_shop', {'p_shop': shopId});
  }

  // ==========================================================
  //  المنتجات
  // ==========================================================

  /// جلب المنتجات.
  ///
  /// [activeOnly] = يترك النشط فقط **على الخادم** ⇒ حمولة أصغر
  /// بكثير (التصفية القديمة كانت في العميل بعد تحميل كل شيء).
  /// نمرّره false من شاشات الأدمن لأنها تحتاج المعطّل أيضاً.
  Future<List<Map<String, dynamic>>> fetchProducts({
    String? shopId,
    bool activeOnly = false,
  }) async =>
      (await fetchProductsOrNull(shopId: shopId, activeOnly: activeOnly)) ??
      const [];

  /// مثل [fetchProducts] لكنها تفرّق بين «نجاح بلا صفوف» و«فشل النقل».
  ///
  /// ★ لماذا: كاش الكتالوج (`_Dataset`) كان يعامل القائمة الفارغة كفشل
  ///   شبكة فيحتفظ بالمنتجات القديمة. فإطفاء آخر منتج ظاهر (أو كل منتجات
  ///   صيدلية) كان يتركه معروضاً بلا نهاية — بلاغ «عند إطفاء منتج لا يختفي».
  ///   الآن: `null` = فشل ⇒ يُحتفظ بالكاش، و`[]` = نجاح بلا صفوف ⇒ يُفرَّغ.
  Future<List<Map<String, dynamic>>?> fetchProductsOrNull({
    String? shopId,
    bool activeOnly = false,
  }) async {
    ApiMetrics.hit('products');
    final watch = Stopwatch()..start();
    try {
      const base =
          'select=id,name,price,old_price,special_note,'
          'is_video,is_active,shop_id,shop_name,category_id,image_path,'
          'requires_prescription';
      // ★ `discount_percent` حُذف: لم يكن مستعملاً في أي مكان
      //   (الخصم يُحسب من old_price في Product) ⇒ توفير في الحمولة.
      // ★ 2026-11-06 — `logo_image` و`created_at` حُذفا من القائمة:
      //   · `logo_image` نسخة طبق الأصل من `image_path` في كل صفوف
      //     القاعدة (قياس حيّ: ٣٩٢/٣٩٢ متطابقان، ولا صفّ image_path
      //     فارغ عنده قيمة في logo_image). وكل قارئ في التطبيق يبدأ
      //     بـ`image_path` ثم يقع على `logo_image` احتياطاً، فالاحتياط
      //     باق عملياً بلا قيمة مضافة على السلك.
      //   · `created_at` للترتيب فقط، والترتيب يفعله الخادم
      //     (`order=created_at.desc`) ولا يقرأه أحد في العميل: لا في
      //     `Product` حقلٌ له ولا في بصمة الهوية `_productIdentity`.
      //   النتيجة المقاسة على الشبكة: ٢٨٫٧KB ⇒ ٢٢٫٧KB للكتالوج كامل.
      final active = activeOnly ? '&is_active=eq.true' : '';
      // ★ حدّ أعلى للصفحات: يمنع تنزيل جدول ضخم دفعة واحدة.
      //   مرفوع من 800/400: الحدّ كان يقتطع المنتجات الأقدم فيُظهر عدد
      //   منتجات ناقصاً في الأقسام والشاشة الرئيسية.
      final uri = shopId == null || shopId.isEmpty
          ? '${_url}products?$base&order=created_at.desc$active&limit=2000'
          : '${_url}products?$base&shop_id=eq.$shopId&order=created_at.desc'
                '$active&limit=1000';
      // ★ العميل المشترك `_http` بدل `http.get` الساكنة: هذه الأخيرة
      //   تفتح اتصال TCP/TLS جديداً عند **كل** نداء، أي بضع مئات من
      //   الأجزاء من الثانية على شبكة ضعيفة. (العميل موجود أصلاً في الملف.)
      final res = await _http
          .get(Uri.parse(uri), headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        debugPrint(
          '⏱ fetchProducts ${res.body.length ~/ 1024}KB '
          'in ${watch.elapsedMilliseconds}ms'
          '${shopId == null ? '' : ' shop=$shopId'}',
        );
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return null;
  }

  /// ★ ملاحظات المنتج [specialNote]: نص حر يكتبه الأدمن عند النشر
  ///   («وزن العبوة»، «يُقدَّم ساخناً»، «الصورة للزينة»...).
  ///   يُخزَّن في `products.special_note` وهو **عام للقراءة**:
  ///   جله fetchProducts يطلبه صراحة ضمن `select`، فيظهر عند كل
  ///   زبون في بطاقة المنتج وصفحته دون تسجيل دخول.
  Future<bool> addProduct({
    required String name,
    double price = 0,
    double? oldPrice,
    String? shopId,
    String? shopName,
    String? categoryId,
    String? imageUrl,
    String? imagePath,
    String? serialNumber,
    String? specialNote,
    bool isActive = true,
    bool requiresPrescription = false,
  }) async {
    try {
      final res = await _http.post(
        Uri.parse('${_url}products'),
        headers: _headers,
        body: jsonEncode({
          'name': name,
          'price': price,
          'old_price': (oldPrice == null || oldPrice <= 0) ? null : oldPrice,
          'shop_id': (shopId == null || shopId.isEmpty) ? null : shopId,
          'shop_name': shopName,
          'category_id': categoryId,
          'logo_image': imageUrl ?? imagePath,
          'image_path': imagePath,
          'serial_number': serialNumber,
          // ★ فارغ = null حتى لا يظهر «سطر ملاحظات» أجوف عند الزبون.
          'special_note': (specialNote == null || specialNote.trim().isEmpty)
              ? null
              : specialNote.trim(),
          'is_active': isActive,
          'requires_prescription': requiresPrescription,
        }),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<bool> updateProduct(
    String productId,
    Map<String, dynamic> values,
  ) async {
    if (productId.isEmpty || values.isEmpty) return false;
    try {
      final res = await _http.patch(
        Uri.parse('${_url}products?id=eq.$productId'),
        headers: _headers,
        body: jsonEncode(values),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// ★★ نشر تعديل سعر المنتج على الطلبات غير المكتملة — **أداة يدوية**.
  ///
  /// ★ منذ `SQL_PRICE_LIVE_FOR_ALL.sql` لم تعد شاشات الأدمن والتاجر
  ///   تحتاجها: تريجر على `products.price` في القاعدة ينشر السعر على بنود
  ///   الطلبات الجارية ويُعيد حساب الإجمالي ويُشعر الزبون في نفس لحظة
  ///   الحفظ، من أي مصدر جاء التغيير. بقيت الدالة هنا **عمداً** لمسار
  ///   يدوي (تنسيق كتلة من المنتجات دفعة واحدة بعد إصلاح في pgAdmin، أو
  ///   قاعدة لم يُشغَّل عليها الملف بعد) — ولم تُحذف حتى لا يضيع وسيلة
  ///   موجودة. ★ لا تُنادَ بعد PATCH على `products` وإلا تكرّر إشعار
  ///   لنفس الطلب (نفس `dedupe_key` يُحدَّث فيعيد الدفع).
  ///
  /// ★ لماذا كانت ضرورية؟ تعديل سعر المنتج في الكتالوج **لا** يمسّ الطلبات
  ///   القائمة أصلاً: الطلب سطر ثابت عند إرساله. فالمشتري الذي
  ///   يحمل المنتج في طلب لم يكتمل بعد يبقى على السعر القديم حتى
  ///   التسليم — أي أن السعر الذي طلب به لم يعد السعر المعروض.
  ///
  /// ★ لا نمسّ الطلب `delivered`: محسوم وشُحن، وتعديله-financial.
  ///   المتبقّي (pending/accepted/delivering) فهو قابل للتعديل.
  ///
  /// ★ يُرجع عدد الطلبات التي تحدّثت، فيخبر الأدمن
  ///   متى أخطأ وأصلح — ويكتشف أن النشر لم يعمل إن كان صفراً.
  Future<int> propagateProductPriceToOpenOrders({
    required String productId,
    required double newPrice,
    String? productName,
  }) async {
    if (productId.isEmpty || newPrice <= 0) return 0;
    List<Map<String, dynamic>> items;
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}order_items?select=id,order_id,quantity&product_id=eq.'
              '${Uri.encodeComponent(productId)}&limit=300',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return 0;
      items = List<Map<String, dynamic>>.from(jsonDecode(res.body) as List);
    } catch (_) {
      return 0;
    }
    if (items.isEmpty) return 0;

    // ★ الطلبات المكتملة تُستبعد قبل أي كتابة — لا تعديل مالي على
    //   ما شُحن فعلاً مهما كان عددها.
    final openOrders = <String, List<String>>{}; // orderId → itemIds
    final orderIds = <String>{
      for (final i in items) (i['order_id'] ?? '').toString(),
    }.where((s) => s.isNotEmpty).toList();
    if (orderIds.isEmpty) return 0;

    try {
      final res = await _http.get(
        Uri.parse(
          '${_url}orders?select=id,status&id=in.('
          '${orderIds.join(',')})&limit=300',
        ),
        headers: _headers,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return 0;
      final rows = jsonDecode(res.body) as List;
      final open = <String>{
        for (final r in rows)
          if (const {
            'pending',
            'accepted',
            'delivering',
          }.contains('${(r as Map)['status']}'))
            '${r['id']}',
      };
      for (final i in items) {
        final oid = '${i['order_id'] ?? ''}';
        final iid = '${i['id'] ?? ''}';
        if (oid.isEmpty || iid.isEmpty || !open.contains(oid)) continue;
        (openOrders[oid] ??= <String>[]).add(iid);
      }
    } catch (_) {
      return 0;
    }

    var touched = 0;
    for (final entry in openOrders.entries) {
      var orderOk = false;
      for (final itemId in entry.value) {
        // ★ نُعيد استخدام المسار الموجود: يُحدّث السعر وي-total
        //   الطلب ويُشعر الزبون — فلا مسار ثانٍ بلا إشعار.
        final ok = await updateOrderItemPrice(
          itemId,
          newPrice,
          productName: productName,
        );
        if (ok) orderOk = true;
      }
      if (orderOk) touched++;
    }
    return touched;
  }

  Future<bool> deleteProduct(String productId) async {
    if (productId.isEmpty) return false;
    return _callDelete('delete_product', {'p_product': productId});
  }

  // ==========================================================
  //  الطلبات
  // ==========================================================

  /// هل للعميل طلب صيدلية نشط؟ (طلبات المندوب الحر لا تُحسب)
  Future<bool> hasActiveOrder(String userPhone) async {
    if (userPhone.isEmpty) return false;
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}orders?select=id&user_phone=eq.$userPhone'
              '&status=in.(pending,accepted,delivering)'
              '&is_free_driver_request=is.false&limit=1',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return (jsonDecode(res.body) as List).isNotEmpty;
      }
    } catch (_) {}
    return false;
  }

  /// إنشاء طلب جديد من عميل مع بنوده.
  Future<Map<String, dynamic>?> createOrder({
    required String orderNumber,
    String? userPhone,
    String? userName,
    double totalAmount = 0,
    double deliveryFee = 0,
    String? address,
    String? notes,
    String? couponCode,
    double? couponDiscount,
    double? latitude,
    double? longitude,
    bool isFreeDriverRequest = false,
    List<Map<String, dynamic>> items = const [],
    String? prescriptionPath,
  }) async {
    // ★ حارس الخدمة: لا طلب بلا رقم حساب. الواجهة تفتح الدخول أولاً،
    //   وهذا يمنع أي مسار آخر من إرسال طلب بهوية فارغة.
    if (userPhone == null || userPhone.trim().isEmpty) {
      lastOrderError = 'سجّل الدخول أولاً لإرسال الطلب';
      return null;
    }
    try {
      // ★★ طلب فيه وصفة: لا يظهر للمندوبين ولا تُفتح أزرارهم إلا بعد
      //   موافقة صاحب الصيدلية على الوصفة (طلب الأدمن 2026-11-20).
      //   البوابة `pharmacy_gate_ready` تُثبت أن سكربت القاعدة
      //   (SQL_PHARMACY_APPROVAL.sql) منصَّب. قبل تنصيبه يبقى السلوك
      //   القديم (`pending`) حتى لا يعلق طلب في حالة لا يقرؤها أحد.
      final hasPrescription =
          prescriptionPath != null && prescriptionPath.trim().isNotEmpty;
      final needsPharmacyApproval =
          hasPrescription && await pharmacyGateReady();
      final initialStatus = needsPharmacyApproval
          ? 'pharmacy_review'
          : 'pending';

      final base = <String, dynamic>{
        'order_number': orderNumber,
        'user_phone': userPhone,
        'user_name': userName,
        'total_amount': totalAmount,
        'delivery_fee': deliveryFee,
        'address': address,
        'notes': notes,
        'status': initialStatus,
        'payment_status': 'pending',
        'can_transfer_to_other_driver': true,
        // ★ بلا إحداثيات؟ لا نُرسل null صريحاً — نُغفل العمودين تماماً
        //   كي يبقى الطلب قابلاً للإرسال ولو تعذر تحديد الموقع أصلاً.
        'latitude': ?latitude,
        'longitude': ?longitude,
      };

      // أعمدة اختيارية قد لا تكون موجودة في القاعدة قبل تشغيل سكربت التحديث،
      // لذلك نجرّب أولاً بكل الأعمدة ثم نتراجع تدريجياً.
      final withExtras = <String, dynamic>{
        ...base,
        'coupon_code': (couponCode == null || couponCode.trim().isEmpty)
            ? null
            : couponCode.trim().toUpperCase(),
        'coupon_discount': couponDiscount ?? 0,
        'is_free_driver_request': isFreeDriverRequest,
        // ★ وصفة الطبيب: صورة ترفعها السلة عندما يحوي الطلب صنفاً
        //   `requires_prescription`. في `withExtras` وحده لأن العمود
        //   جديد — القاعدة القديمة بلا العمود تُهبط للنسخة الأخفّ بنفس
        //   آلية التراجع الموجودة.
        'prescription_path':
            (prescriptionPath == null || prescriptionPath.trim().isEmpty)
            ? null
            : prescriptionPath.trim(),
      };
      final withCoupon = <String, dynamic>{
        ...base,
        'coupon_code': (couponCode == null || couponCode.trim().isEmpty)
            ? null
            : couponCode.trim().toUpperCase(),
        'coupon_discount': couponDiscount ?? 0,
      };

      // ★ أول محاولة بكل الأعمدة، ثم التدرّج لأخفّها **إن كان السبب
      //   عموداً ناقصاً فقط** (قاعدة لم يُشغَّل فيها سكربت الأعمدة).
      //   ★★ أما أي رفض آخر — رفضُ تكرار كود العجلة من فهرس القاعدة،
      //   أو خطأ شبكة، أو صلاحيات — فيُوقف الحلقة فوراً. كان التراجع
      //   الأعمى يهبط إلى `base` الخالي من حقول الكود، فيُقبل الطلب
      //   **بسعر كامل** ويُسجَّل للمندوب بلا خصم، والزبون يقرأ في
      //   فاتورته أنه استعمل كوده. هذه أصدق نقطة في المسار: الرفض
      //   يظهر رسالته، والطلب لا يُنشأ بنصف ما رآه الزبون.
      http.Response? res;
      for (final payload in [withExtras, withCoupon, base]) {
        res = await _http
            .post(
              Uri.parse('${_url}orders'),
              headers: _headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode >= 200 && res.statusCode < 300) break;
        if (!_isMissingColumnError(res.body)) break;
      }
      if (res == null || res.statusCode < 200 || res.statusCode >= 300) {
        // نحفظ سبب الرفض الحقيقي من السيرفر لتظهر رسالة مفهومة للمستخدم.
        lastOrderError =
            'HTTP ${res?.statusCode ?? 0}: ${_shortServerError(res?.body)}';
        return null;
      }
      lastOrderError = null;

      final order = Map<String, dynamic>.from(
        jsonDecode(res.body).first as Map,
      );
      final orderId = order['id'].toString();

      // ★★ بنود الطلب: **لا تُبتلع الأخطاء**.
      //
      // ★ ما كان يحدث: `catch (_) {}` وحده، و`http.post` **لا يرمي**
      //   على 4xx/5xx — يعيد Response. أي أن فشل الإدراج (انقطاع
      //   شبكة، 400، 409) كان يصمت تماماً، فيبقى الطلب موجوداً
      //   **بلا بنود** والمندوب يفتح «التفاصيل» فيجدها فارغة ولا
      //   يعرف ما يوصّل. ويظهر بوضوح عند أول طلب من صيدلية جديدة،
      //   لأن أول طلبٍ منه يمرّ بشبكة أضعف أو حقل ناقص.
      //
      // ★ الحل: فحص الحالة + إعادة محاولة واحدة، ثم **إرجاع null**
      //   حتى لا يُقال للزبون «تم الطلب» وهو طلب غير قابل للتنفيذ.
      //   لأن طلباً بلا أصناف أسوأ بكثير من رسالة فشل صريحة.
      var failedItems = 0;
      String? itemError;

      // ★★ إدراج البنود **دفعة واحدة** بدل بنداً بنداً.
      //
      //  ★ ما كان يحدث: حلقة `for` بـ POST لكل صنف ⇒ طلب من ١٠ أصناف
      //    = ١٠ جولات TLS/ترحلة (٣٠٠–٦٠٠ مللي لكل واحدة ⇒ ٣–٦ ثوانٍ
      //    قبل أن يُبلَّغ المندوب أصلاً). وPostgREST يقبل **مصفوفة**
      //    في جسم الطلب فيُدرج الكل في ذهاب وإياب واحد.
      //  النتيجة: صنف واحد أو اثنان = نفس الزمن تقريباً.
      final rows = <Map<String, dynamic>>[
        for (final item in items)
          {
            'order_id': orderId,
            'product_id': item['productId'],
            'shop_id': item['shopId'],
            'product_name': item['name'],
            'shop_name': item['shopName'],
            'quantity': item['quantity'],
            'price': item['price'],
            'total': (item['price'] as num) * (item['quantity'] as num),
            'product_image': item['image'],
          },
      ];

      if (rows.isNotEmpty) {
        var ok = false;
        for (var attempt = 0; attempt < 2 && !ok; attempt++) {
          try {
            final r = await _http
                .post(
                  Uri.parse('${_url}order_items'),
                  headers: _headers,
                  body: jsonEncode(rows),
                )
                .timeout(const Duration(seconds: 15));
            ok = r.statusCode >= 200 && r.statusCode < 300;
            if (!ok)
              itemError = 'HTTP ${r.statusCode}: ${_shortServerError(r.body)}';
          } catch (e) {
            itemError = e.toString();
          }
        }
        if (!ok) failedItems = items.length;
      }

      // ★ بند ناقص واحد يُبطل الطلب كله: توصيل طلب ناقص أسوأ من
      //   رفضه، والمندوب لا يستطيع إبلاغ الزبون.
      if (failedItems > 0) {
        lastOrderError =
            'تعذّر تسجيل ${failedItems} من ${items.length} صنف'
            '${itemError == null ? '' : ' ($itemError)'}';
        // ★ تنظيف: بنود نجحت + الطلب نفسه. بلاه يبقى في القاعدة
        //   طلب يراه المندوب ولا يستطيع تنفيذه.
        try {
          await _http.delete(
            Uri.parse('${_url}order_items?order_id=eq.$orderId'),
            headers: _headers,
          );
          await _http.delete(
            Uri.parse('${_url}orders?id=eq.$orderId'),
            headers: _headers,
          );
        } catch (_) {}
        return null;
      }

      unawaited(
        addNotification(
          userPhone: userPhone,
          title: 'تم استلام طلبك ✅',
          body: needsPharmacyApproval
              ? 'وصل طلبك إلى الصيدلية. طلبك يحمل وصفة طبية — '
                    'بعد موافقة الصيدلية على الوصفة سيصل إلى المندوب '
                    'ويصلك قريباً.'
              : 'أرسلنا طلبك إلى الصيدلية وسيصلك قريباً، '
                    'يمكنك متابعته من سجل طلباتي.',
          type: 'order_created',
          sound: NotifySound.alert.key,
        ),
      );

      // إشعار كل المندوبين بالطلب الجديد: «لديك طلب جديد رقم #N».
      // ★ `await` لا `unawaited`: الإشعار الآن يُكتب داخل القاعدة،
      //   فنداؤه سريع (~١٠٠–٣٠٠ ملّي) — وانتظاره يضمن وصوله حتى لو
      //   أغلق الزبون الشاشة فوراً. والدالة لا ترمي استثناءً، فلا
      //   يبطل طلبٌ نجح.
      final serial = order['serial_number']?.toString().trim() ?? '';
      // ★★ لا ننتظر: المشغّل `AFTER INSERT` على `orders` كتب إشعار
      //   المندوبين **قبل** هذا السطر أصلاً (داخل نفس المعاملة)،
      //   فالإشعار وصل المندوب في اللحظة نفسها مع قَيد الطلب.
      //   انتظارُ هذه الدالة يضيف ~٢٠٠ مللي على شاشة الزبون بلا أي
      //   فائدة: هي تصبح `sent_to = 0` لأن الصفوف موجودة.
      //  بقى الاستدعاء للسلوك القديم (قاعدة بلا الدالة) — لكن بلا
      //   تعطيل، والبديل لا يُبطئ شيئاً: أعدنا `order` قبله.
      unawaited(
        needsPharmacyApproval
            // ★ طلب بوصفة: لا إشعار مندوبين الآن. تُكتب صفوفهم في
            //   القاعدة لحظة **موافقة الصيدلية** فقط (دالة
            //   `pharmacy_approve_order`)، فلا يرى مندوبٌ طلباً لم
            //   تعتمده الصيدلية بعد.
            ? Future<void>.value()
            : notifyDriversOfNewOrder(
                order,
                serial: serial.isEmpty ? orderNumber : '#$serial',
                isDriverRequest: isFreeDriverRequest,
              ),
      );
      return order;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchOrders(String filter) async {
    return await _fetchOrdersChecked(filter) ?? const [];
  }

  /// مثل [_fetchOrders] لكنها تُميّز **الفشل** عن **فارغ حقيقي**:
  /// `null` = الرد لم يكن نجاحاً (عمود غير موجود، انقطاع، 401)،
  /// و`[]` = لا طلبات لهذا الشرط فعلاً.
  ///
  /// التمييز لازم لأن فلترة «طلبات المندوب نفسه» تجرب مرشّحاً أول ثم
  /// ترجع لمرشّح أقدَم؛ ولو ابتلعنا الخطأ كقائمة فارغة لقرأ المندوب
  /// «لا شيء لك» بينما طلباته موجودة.
  Future<List<Map<String, dynamic>>?> _fetchOrdersChecked(String filter) async {
    ApiMetrics.hit('orders');
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}orders?select=*&order=created_at.desc&$filter'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> fetchOrders(String filter) =>
      _fetchOrders(filter);

  Future<List<Map<String, dynamic>>> fetchAllOrders() => _fetchOrders('');

  /// ★ اسمَا دالتَي العزل في القاعدة (`SQL_DRIVER_ORDER_ISOLATION.sql`).
  static const String deliveredRpcFn = 'driver_delivered_orders';
  static const String rejectedRpcFn = 'driver_rejected_orders';

  /// `true` = ثبت أن الدالتين غير موجودتين (لم يُشغَّل ملف SQL بعد)،
  /// فلا تُدفع محاولتهما مع كل تحديث. الانقطاع و٤٠١ **لا** يضبطانها.
  bool _driverScopeRpcMissing = false;

  /// للاختبار والتشخيص فقط: هل صارت دوال العزل معلومة كغير موجودة؟
  bool get driverScopeRpcKnownMissing => _driverScopeRpcMissing;

  /// ينادي دالة العزل عبر `GET /rpc/<fn>`.
  ///
  /// يعيد `null` عند أي فشل (لا دالة، انقطاع، جلسة منتهية) لتُجرَّب
  /// المرشّحات النصية، وقائمة — قد تكون فارغة — عند النجاح: فارغ هنا يعني
  /// «لا طلبات لهذا المندوب فعلاً»، وهو معنى مختلف عن السقوط للاحتياط.
  Future<List<Map<String, dynamic>>?> _fetchDriverScopedRpc(String fn) async {
    if (_driverScopeRpcMissing) return null;
    try {
      final res = await _http
          .get(Uri.parse('${_url}rpc/$fn'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      final state = rpcAvailabilityFor(res.statusCode);
      if (state == RpcAvailability.available) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
      if (state == RpcAvailability.notCreatedYet) {
        _driverScopeRpcMissing = true;
      }
    } catch (_) {}
    return null;
  }

  /// ★ «مكتمل» هذا المندوب وحده.
  ///
  ///   المصدر الأساسي دالة القاعدة [deliveredRpcFn]: الرقم فيها يُقرأ من
  ///   توكن الجلسة الموقّع داخل القاعدة، فلا يستطيع حساب مندوب — ولا من
  ///   يملك مفتاح anon وحده — أن يطلب طلبات مندوب آخر. والمردود نفس شكل
  ///   `select=*` المرتّب بـ`created_at.desc`، فالشاشة لا تحتاج تعديلاً.
  ///   والدالة `stable` فتُباح لها قراءة GET؛ ولو لم تُنشَأ بعد يُستعمل
  ///   المرشّح النصي القديم بنفس النتيجة، فلا كسر ولا انتظار.
  Future<List<Map<String, dynamic>>> fetchMyDeliveredOrders(
    String phone,
  ) async {
    final scoped = await _fetchDriverScopedRpc(deliveredRpcFn);
    if (scoped != null) return scoped;
    return _fetchOrders(DriverOrderFilters.delivered(phone));
  }

  bool _rejectStampMissing = false;

  /// للاختبار والتشخيص فقط: هل صار الختم معلوماً كغائب؟
  bool get rejectStampKnownMissing => _rejectStampMissing;

  /// ★ «مرفوض» هذا المندوب وحده: ما رفضه هو أو كان مسنداً إليه ثم رُفض/أُلغي.
  ///
  ///   تُجرَّب دالة القاعدة [rejectedRpcFn] أولاً (عزل من داخل القاعدة)، ثم
  ///   المرشّح النصي بختم الرافض `rejected_by_phone` (من
  ///   `SQL_REJECTER_STAMP.sql`)، ثم المرشّح الأقدم على العمود المضمون
  ///   `assigned_driver_phone` — فأيّاً من الملفَّين لم يُشغَّل، يرى المندوب
  ///   رفضاته هو ولا يرى رفضات غيره. ولا رجوع أبداً إلى «كل المرفوض للجميع».
  ///
  ///   ★ المحاولتان الاحتياطيتان تُدفعان مرة واحدة لكل تشغيل: لو ثبت أن
  ///   العمود غير موجود يبقى الجهاز على المرشّح الأقدم حتى لا يُرفض طلب
  ///   شبكة مع كل فتح للتبويب.
  Future<List<Map<String, dynamic>>> fetchMyRejectedOrders(String phone) async {
    final scoped = await _fetchDriverScopedRpc(rejectedRpcFn);
    if (scoped != null) return scoped;
    if (!_rejectStampMissing) {
      final stamped = await _fetchOrdersChecked(
        DriverOrderFilters.rejectedPrimary(phone),
      );
      if (stamped != null) return stamped;
      _rejectStampMissing = true;
    }
    final fallback = await _fetchOrdersChecked(
      DriverOrderFilters.rejectedFallback(phone),
    );
    if (fallback != null) return fallback;
    // الاحتياطي نفسه فشل: نُنسى نتيجة «لا عمود» ونعيد المحاولة الكاملة
    // المرة القادمة — فالسبب قد يكون انقطاع شبكة لا غياب العمود.
    _rejectStampMissing = false;
    return const [];
  }

  Future<List<Map<String, dynamic>>> fetchOrdersByPhone(
    String userPhone,
  ) async {
    if (userPhone.isEmpty) return const [];
    return _fetchOrders('user_phone=eq.$userPhone');
  }

  /// الطلبات المتاحة للمندوب: **العادية + طلبات المندوب الحر مجمّعة**،
  ///   بحالتين للقراءة لا حالة واحدة.
  ///
  /// ★ كان `status=eq.pending` وحده، فكانت طلبات المندوب الحر تظهر مرتين
  ///   هنا وفي [fetchFreeDriverRequests] (تبويب منفصل)، وبسبب التبويبات
  ///   المستقلة كانت تختفي بصرياً عند قبول طلب آخر. الآن قائمة واحدة بلا
  ///   تكرار ولا اختفاء، والتمييز بالعمود `is_free_driver_request`.
  ///
  /// ★★ **لماذا صار الجلب مرشّحين؟** القراءة القديمة كانت ترجع قائمة
  ///   فارغة في ثلاث حالات لا تُميَّز بينها: لا طلب فعلاً، أو الردّ فشل
  ///   (انقطاع أو عمود مفقود أو صيغة مرفوضة من المخطّط)، أو أن الحالة
  ///   المكتوبة في القاعدة ليست كلمة `pending` الحرفية. في الحالتين
  ///   الأخيرتين كان المندوب يسمع رنّة الإشعار ثم يفتح شاشة فارغة —
  ///   «صوت بلا شيء». المنطق كله في [readDriverAvailableOrders]،
  ///   وهو يُختبر بلا شبكة.
  ///
  /// ★ [pendingOrdersReadFailed] يُميّز «لا طلبات عندك» عن «لم تصلني
  ///   القراءة»، فالشاشة تُخبره بدل أن توهمه أن الحيّ خالٍ.
  Future<List<Map<String, dynamic>>> fetchPendingOrders() async {
    ApiMetrics.hit('pending_orders');
    final read = await readDriverAvailableOrders(_fetchOrdersChecked);
    pendingOrdersReadFailed = read.failed;
    if (read.usedStrict) debugPendingStrictFallbackRuns++;
    return read.orders;
  }

  /// `true` = آخر قراءة للمتاحة سقطت في المرشّحين معاً.
  bool pendingOrdersReadFailed = false;

  /// كم مرة نُزول للمرشّح الضيّق؟ (للتشخيص من السجلات والاختبارات)
  int debugPendingStrictFallbackRuns = 0;

  /// طلبات المندوب الحر وحدها — لم تعد القائمة الرئيسية تعتمدها.
  Future<List<Map<String, dynamic>>> fetchFreeDriverRequests() =>
      _fetchOrders('is_free_driver_request=eq.true&status=eq.pending');

  Future<Map<String, dynamic>?> fetchOrderById(String orderId) async {
    if (orderId.isEmpty) return null;
    ApiMetrics.hit('order_by_id');
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}orders?select=*&id=eq.$orderId&limit=1'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return null;
        return Map<String, dynamic>.from(list.first as Map);
      }
    } catch (_) {}
    return null;
  }

  /// بحث إداري برقم الطلب التسلسلي أو بالرقم القديم.
  Future<List<Map<String, dynamic>>> searchOrdersBySerial(String query) async {
    final q = query.trim().replaceAll('#', '').trim();
    if (q.isEmpty) return <Map<String, dynamic>>[];
    if (int.tryParse(q) != null) {
      final bySerial = await _fetchOrders('serial_number=eq.$q');
      if (bySerial.isNotEmpty) return bySerial;
    }
    // ★ PostgREST filters are a mini-language: an unescaped comma or
    //   parenthesis in the value lets a caller inject an extra clause
    //   (`q = "1,or=(id.not.is.null)"`) and change what this returns.
    //   Commas/parens are stripped outright rather than escaped —
    //   encodeComponent alone would still leave PostgREST's own parser
    //   a way in, and stripping is the option that cannot be bypassed.
    final safe = q
        .replaceAll('%', '')
        .replaceAll('*', '')
        .replaceAll(',', '')
        .replaceAll('(', '')
        .replaceAll(')', '')
        .trim();
    if (safe.isEmpty) return <Map<String, dynamic>>[];
    return _fetchOrders('order_number=ilike.*$safe*');
  }

  Future<List<Map<String, dynamic>>> fetchOrderItems(String orderId) async {
    if (orderId.isEmpty) return const [];
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}order_items?select=*&order_id=eq.$orderId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return [];
  }

  Future<List<Map<String, dynamic>>> fetchAllOrderItems() async {
    try {
      final res = await _http
          .get(Uri.parse('${_url}order_items?select=*'), headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return [];
  }

  /// إشعار حقيقي للمستخدم عند تغيّر حالة طلبه.
  Future<void> _notifyOrder(
    String orderId,
    String title,
    String body, {
    String? sound,
    String? type,
    String? status,
    String? serial,
    Duration display = const Duration(seconds: 6),
  }) async {
    // ★★ النبضة قبل أي رجوع: تغيير الحالة تُكتب في `orders` ثم يُنادى
    //   هذا المسار، والخادم — الذي يرسل FCM لأصحاب الهاتف المقفل —
    //   يكتشفها من دورة استطلاع لا من هنا. بلا نبضة يبقى الزبون
    //   ثانيتين أو أكثر ينتظر «تم قبول طلبك» وهو لا يفتح التطبيق.
    unawaited(pokeNotifyServer(status ?? type ?? 'order'));
    // ★★ القاعدة صارت المصدر الوحيد للإشعارات.
    //    مشغّل `trg_notify_status_change` يكتب صفاً واحداً لكل
    //    تغيير حالة، والمفتاح `dedupe_key = status:<order>:<status>`
    //    مع فهرس فريد `notifications_dedupe_uidx` يمنع أي تكرار،
    //    حتى لو كتب مرتين في نفس اللحظة.
    //   سابقاً كان الإشعار يُكتب من هنا ومن المشغّل معاً ⇒ تصل
    //    رسالتان للزبون خلال ثانية عند التسليم.
    //    لذلك نُرجع هنا: القراءة تجلب ما كتبته القاعدة، ولا نكتب.
    if (status != null) {
      return;
    }
    final order = await fetchOrderById(orderId);
    final phone = order?['user_phone']?.toString() ?? '';
    if (phone.isEmpty) return;
    // ★ شعار صاحب الطلب وحده: `brandImageOf` يقرأ `avatar_url`
    //   (وشعار صيدليته إن كان صاحب صيدلية) ولا شيء غيره ⇒ لا شعار حساب
    //   على حساب. ومن لا شعار له ⇒ `image_url` فارغ، فيعرض التطبيق
    //   أيقونة النوع بدل صورة مستعارة من حساب آخر.
    final brandImage = await brandImageOf(phone);
    // ★★ الإشعار يكتبه **الخادم** لا الجهاز.
    //   `POST /notifications` مقفلة منذ تشديد RLS (401)، فكان تغيير
    //   السعر يُحفظ في القاعدة لكن جهاز الزبون لا يعلم ⇒ يبقى يرى
    //   السعر القديم. فالدالة `notify_order_owner` (security definer)
    //   تكتب الصف **لصاحب الطلب** الذي تحدّده هي من `orders` — فلا
    //   أحد يستطيع إشعار حساب آخر بهذا المسار، ولا نحتاج صلاحية
    //   جدول. وإن لم تكن الدالة موجودة بعد ⇒ نرجع للطريقة القديمة.
    final typeKey = (type ?? status ?? 'order').trim();
    final serialTag = serial ?? await _orderSerialTag(orderId);
    var sent = false;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/notify_order_owner'),
            headers: _headers,
            body: jsonEncode({
              'p_order_id': orderId,
              'p_title': title,
              'p_body': body,
              'p_sound': sound ?? 'alert',
              'p_type': typeKey,
              'p_serial': serialTag,
            }),
          )
          .timeout(const Duration(seconds: 10));
      sent = res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {}

    if (!sent) {
      //  قواعد بلا الدالة الجديدة ⇒ المسار القديم (يسقط بـ401 عند
      //  القفل، لكنه يعمل على قواعد أقدم).
      await addNotification(
        userPhone: phone,
        title: title,
        body: body,
        sound: sound,
        type: type,
        orderId: orderId,
        serial: serialTag,
        imageUrl: brandImage,
      );
    }
    // نفس الإشعار يُعرض فوراً على جهاز صاحب الطلب (لو هو من فتح التطبيق).
    // لا نعرضه على جهاز المندوب الذي أنشأ الحدث.
    // ★ نحجز المفتاح الموحّد قبل العرض حتى لا يعرضه الاستطلاع مرة
    //   ثانية (الصف مكتوب أعلاه ⇒ سيصلنا عبر _tick خلال ثوانٍ).
    if (StatusCenter.activeAccountPhone == phone) {
      final key = NotificationDedup.keyFor(
        orderId: orderId,
        type: type ?? status,
      );
      if (await NotificationDedup.claim(key)) {
        await StatusCenter.instance.broadcast(
          title: title,
          body: body,
          status: status,
          orderId: orderId,
          sound: sound,
          serial: serial,
          dedupeKey: key,
          duration: display,
        );
      }
    }
  }

  /// اسم صاحب حساب (المندوب) لعرضه في نص الإشعار: «بواسطة مصطفى».
  Future<String> accountName(
    String phone, {
    String fallback = 'المندوب',
  }) async {
    final p = phone.trim();
    if (p.isEmpty) return fallback;
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}users?select=name&phone=eq.$p&limit=1'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isNotEmpty) {
          final n = (list.first as Map)['name']?.toString().trim() ?? '';
          if (n.isNotEmpty && n != 'null') return n;
        }
      }
    } catch (_) {}
    return fallback;
  }

  /// ★ استدعاء دالة RPC ذرّية للطلب.
  ///
  /// لماذا لاPATCH بعد اليوم:
  ///   `Prefer: return=representation` يُرجع الصف متى سمحت RLS بـ`using`،
  ///   حتى لو لم يطابق الفلتر `status=eq.pending` شيئاً ⇒ كان التطبيق
  ///   يعلن «تم القبول» بلا أي تغيير حقيقي في القاعدة.
  ///   الدالة تُجري فحص الحالة والإسناد في عبارة UPDATE واحدة، وترجع
  ///   `ok` فقط متى تغيّر الصف فعلاً.
  Future<OrderUpdateResult> _callOrderAction(
    String fn,
    Map<String, dynamic> args,
  ) async {
    lastOrderUpdateError = null;
    lastOrderUpdateStatus = null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/$fn'),
            headers: _headers,
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 12));
      lastOrderUpdateStatus = res.statusCode;

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        final data = (decoded is Map<String, dynamic>) ? decoded : const {};
        final ok = data['ok'] == true;

        if (ok) {
          // ★ `already_mine` / `already`: الطلب بقي على حالته،
          //   ونعتبره نجاحاً حقيقياً لأن الحالة النهائية مطلوبة أصلاً.
          return OrderUpdateResult.success;
        }

        final err = (data['error'] ?? '').toString();
        if (err == 'ALREADY_TAKEN') {
          lastOrderUpdateError = 'تم قبول هذا الطلب من قبل مندوب آخر';
          return OrderUpdateResult.conflict;
        }
        if (err == 'NOT_YOUR_ORDER') {
          lastOrderUpdateError = 'هذا الطلب ليس مسنداً إليك';
          return OrderUpdateResult.conflict;
        }
        lastOrderUpdateError = _friendlyOrderError(err);
        return OrderUpdateResult.failed;
      }

      final detail = res.body.trim();
      lastOrderUpdateError =
          'HTTP ${res.statusCode}'
          '${detail.isEmpty ? '' : ' — ${detail.substring(0, detail.length > 180 ? detail.length : 180)}'}';
    } catch (e) {
      lastOrderUpdateError = e.toString();
    }
    return OrderUpdateResult.failed;
  }

  /// ترجمة رموز الدالة إلى رسالة عربية واضحة بدل الرمز الإنجليزي.
  static String _friendlyOrderError(String code) {
    switch (code) {
      case 'NO_SESSION':
        return 'انتهت الجلسة - أعد تسجيل الدخول';
      case 'NOT_DRIVER':
        return 'هذا الحساب ليس حساب مندوب - راجع الإدارة';
      case 'NOT_ACTIVE':
        return 'حسابك موقوف - راجع الإدارة';
      case 'NO_USER':
        // بوابة الكتالوج (catalog_gate) تقرأ جدول المستخدمين — لا صفّ له
        return 'لا يوجد حساب بهذا الرقم - راجع الإدارة';
      case 'IS_CUSTOMER':
        return 'لا يمكنك قبول طلبك بنفسك';
      case 'NOT_FOUND':
        return 'الطلب لم يعد موجوداً';
      case 'CONFLICT':
        return 'تغيّرت حالة الطلب - حدّث الصفحة';
      case 'BAD_STATUS':
        return 'حالة غير معروفة';
    }
    return code.isEmpty ? 'تعذّر تنفيذ الإجراء - حاول مرة أخرى' : code;
  }

  Future<OrderUpdate> acceptOrder(
    String orderId,
    String driverPhone, {
    String? driverName,
  }) async {
    final at = DateTime.now().toUtc().toIso8601String();
    // ★ الدالة تقرأ المندوب من الجلسة نفسها، ولا تقبل رقماً من
    //   الوسيط — فلا يمكن انتحال هوية مندوب آخر.
    final res = await _callOrderAction('accept_order', {'p_order': orderId});
    if (res == OrderUpdateResult.success) {
      // «تم قبول طلبك بواسطة مصطفى» — اسم المندوب + صوت تنبيه للزبون.
      //
      // ⚠️ كل شيء هنا داخل `unawaited` عمداً: جلب اسم المندوب ورقم الطلب
      // التسلسلي طلبا شبكة إضافيان، وكانا على المسار الحرج ⇒ زر القبول
      // ينتظر ثلاثة round-trips بدل واحد. الآنPATCH يعود فوراً ويبدأ
      // تجهيز الإشعار في الخلفية.
      final whoArg = driverName;
      unawaited(() async {
        final who = (whoArg != null && whoArg.trim().isNotEmpty)
            ? whoArg.trim()
            : await accountName(driverPhone);
        final serial = await _orderSerialTag(orderId);
        await _notifyOrder(
          orderId,
          'تم قبول طلبك ✅',
          'تم قبول طلبك $serial بواسطة $who وسيصلك قريباً.',
          sound: NotifySound.accepted.key,
          type: 'accepted',
          status: 'accepted',
        );
      }());
    }
    return OrderUpdate(res, at: at, status: 'accepted');
  }

  Future<OrderUpdate> startDelivering(
    String orderId,
    String driverPhone, {
    String? driverName,
  }) async {
    final at = DateTime.now().toUtc().toIso8601String();
    final res = await _callOrderAction('advance_order', {
      'p_order': orderId,
      'p_status': 'delivering',
    });
    if (res == OrderUpdateResult.success) {
      final whoArg = driverName;
      unawaited(() async {
        final who = (whoArg != null && whoArg.trim().isNotEmpty)
            ? whoArg.trim()
            : await accountName(driverPhone);
        final serial = await _orderSerialTag(orderId);
        await _notifyOrder(
          orderId,
          'طلبك في الطريق 🛵',
          'المندوب $who في طريقه إليك — الطلب $serial.',
          sound: NotifySound.delivering.key,
          type: 'delivering',
          status: 'delivering',
        );
      }());
    }
    return OrderUpdate(res, at: at, status: 'delivering');
  }

  Future<OrderUpdate> rejectOrder(
    String orderId,
    String reason, {
    String? driverName,
  }) async {
    final at = DateTime.now().toUtc().toIso8601String();
    final res = await _callOrderAction('reject_order', {
      'p_order': orderId,
      'p_reason': reason,
    });
    if (res == OrderUpdateResult.success) {
      // «تم رفض طلبك بواسطة X — السبب: …» مع صوت تنبيه للزبون.
      final whoArg = driverName;
      final why = (reason.trim().isEmpty) ? 'غير محدد' : reason.trim();
      unawaited(() async {
        final who = (whoArg != null && whoArg.trim().isNotEmpty)
            ? whoArg.trim()
            : await accountName(await _assignedDriverPhone(orderId));
        final serial = await _orderSerialTag(orderId);
        await _notifyOrder(
          orderId,
          'تم رفض الطلب ❌',
          'تم رفض طلبك $serial بواسطة $who — السبب: $why',
          sound: NotifySound.rejected.key,
          type: 'rejected',
          status: 'rejected',
        );
      }());
    }
    return OrderUpdate(res, at: at, status: 'rejected');
  }

  Future<OrderUpdate> completeOrder(
    String orderId,
    String driverPhone, {
    bool? canTransfer,
  }) async {
    final at = DateTime.now().toUtc().toIso8601String();
    // ★ الدالة تتحقق أن الطلب مسند لهذا المندوب قبل التسليم.
    //   `can_transfer_to_other_driver` لم يعد يُرسَل مع الحالة: المشغّل
    //   `guard_driver_wallet_owner` يمنع تغيير المندوب المسند بعد القبول
    //   ويكفي أن يبقى العمود كما هو.
    final res = await _callOrderAction('advance_order', {
      'p_order': orderId,
      'p_status': 'delivered',
    });
    if (res == OrderUpdateResult.success) {
      // النقاط تُمنح بتأكيد الاستلام، وعند التأكيد يُحذف إشعار الطلب.
      unawaited(() async {
        final serial = await _orderSerialTag(orderId);
        await _notifyOrder(
          orderId,
          'تم توصيل طلبك 🎉',
          'تم توصيل الطلب $serial بنجاح. شكراً لثقتك بنا.',
          sound: NotifySound.delivered.key,
          type: 'delivered',
          status: 'delivered',
        );
      }());
    }
    return OrderUpdate(res, at: at, status: 'delivered');
  }

  /// وسم الطلب التسلسلي (#1) للعرض في نص الإشعار، أو نص فارغ.
  Future<String> _orderSerialTag(String orderId) async {
    final order = await fetchOrderById(orderId);
    if (order == null) return '';
    final raw = order['serial_number']?.toString().trim() ?? '';
    if (raw.isNotEmpty && raw != 'null' && raw != '#---') {
      return raw.startsWith('#') ? raw : '#$raw';
    }
    final legacy = order['order_number']?.toString().trim() ?? '';
    if (legacy.isEmpty || legacy == 'null') return '';
    return legacy.startsWith('#') ? legacy : '#$legacy';
  }

  /// رقم المندوب المسند للطلب (لعرض اسمه في إشعار الرفض).
  Future<String> _assignedDriverPhone(String orderId) async {
    final order = await fetchOrderById(orderId);
    final p = order?['assigned_driver_phone']?.toString().trim() ?? '';
    return (p.isEmpty || p == 'null') ? '' : p;
  }

  /// إعادة فتح الطلب ليأخذه مندوب آخر (من الأدمن).
  Future<bool> reopenOrder(String orderId) async {
    if (orderId.isEmpty) return false;
    try {
      final res = await _http.patch(
        Uri.parse('${_url}orders?id=eq.$orderId'),
        headers: _headers,
        body: jsonEncode({
          'status': 'pending',
          'assigned_driver_phone': null,
          'rejection_reason': null,
          'accepted_at': null,
          'delivering_at': null,
          'delivered_at': null,
        }),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final order = await fetchOrderById(orderId);
      if (order != null) {
        final serial = order['serial_number']?.toString().trim() ?? '';
        unawaited(
          notifyDriversOfNewOrder(
            order,
            serial: serial.isEmpty ? '' : '#$serial',
          ),
        );
        unawaited(
          _notifyOrder(
            orderId,
            'أُعيد فتح طلبك 🔄',
            'تم إعادة الطلب ${serial.isEmpty ? '' : '#$serial'} '
                'إلى قائمة المندوبين من جديد.',
            sound: NotifySound.alert.key,
            type: 'reopened',
            status: 'pending',
          ),
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// ★ تغيير حالة الطلب من الأدمن — «مراقبة الطلبات».
  ///
  /// ★ **بلا SQL جديد وبلا دالة جديدة**: نفس مسار [reopenOrder] المثبّت
  ///   (PATCH على `orders`)، وسياسة `orders_update_staff` تسمح للأدمن
  ///   بأي حالة ولا تمنح الزبون أو المندوب شيئاً جديداً. لا سطح هجوم
  ///   إضافي = شرط «احمي لوحة التحكم ولا تغيّر شيئاً» محفوظ.
  ///
  /// ★ مستحقات المندوب لا تسقط: مشغّل `trg_driver_wallet_on_order`
  ///   يعمل على **أي** تحديث للصف، فحين يُكمل الأدمن طلباً يُستقرَّ
  ///   كود الخصم في دفتر المحفظة كما لو سلّمه المندوب نفسه.
  ///
  /// ★ الأوقات تُكتب وتُمحى مع الحالة لأن بطاقة التفاصيل تعرض
  ///   «استلام/توصيل/اكتمال»؛ إبقاء `delivered_at` بعد إرجاع الطلب
  ///   إلى الانتظار كذبٌ يقرأه الأدمن رقماً.
  Future<bool> adminSetOrderStatus(
    String orderId,
    String status, {
    String? reason,
  }) async {
    const allowed = {
      'pending',
      'accepted',
      'delivering',
      'delivered',
      'rejected',
      'cancelled',
    };
    lastAdminStatusError = null;
    if (orderId.isEmpty) return false;
    if (!allowed.contains(status)) {
      lastAdminStatusError = 'حالة غير معروفة';
      return false;
    }

    final order = await fetchOrderById(orderId);
    if (order == null) {
      lastAdminStatusError = 'الطلب لم يعد موجوداً';
      return false;
    }
    final driver = order['assigned_driver_phone']?.toString().trim() ?? '';

    // ★ حالات «في يد مندوب» لا تُمنح لطلب بلا مندوب: وإلا صار الطلب
    //   مقبولاً لا يراه أحد — المندوبون يرون `pending` وطلباتهم هم.
    if (driver.isEmpty &&
        {'accepted', 'delivering', 'delivered'}.contains(status)) {
      lastAdminStatusError = 'لا مندوب على هذا الطلب — أعده للمندوبين أولاً';
      return false;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    String? kept(String col) {
      final v = order[col]?.toString().trim();
      return (v == null || v.isEmpty || v == 'null') ? null : v;
    }

    final patch = <String, dynamic>{'status': status};
    switch (status) {
      case 'pending':
        // عودة كاملة لقائمة المندوبين — نفس ما يفعله [reopenOrder]:
        // `accept_order` يشترط `assigned_driver_phone is null`، فلو
        // تُرِك المندوب القديم على طلب «انتظاري» ما استطاع أحد قبوله.
        patch['assigned_driver_phone'] = null;
        patch['accepted_at'] = null;
        patch['delivering_at'] = null;
        patch['delivered_at'] = null;
        patch['rejection_reason'] = null;
        patch['rejected_by_phone'] = null;
        patch['rejected_by_name'] = null;
      case 'accepted':
        patch['accepted_at'] = kept('accepted_at') ?? now;
        patch['delivering_at'] = null;
        patch['delivered_at'] = null;
        patch['rejection_reason'] = null;
        patch['rejected_by_phone'] = null;
        patch['rejected_by_name'] = null;
      case 'delivering':
        patch['accepted_at'] = kept('accepted_at') ?? now;
        patch['delivering_at'] = kept('delivering_at') ?? now;
        patch['delivered_at'] = null;
        patch['rejection_reason'] = null;
        patch['rejected_by_phone'] = null;
        patch['rejected_by_name'] = null;
      case 'delivered':
        patch['accepted_at'] = kept('accepted_at') ?? now;
        patch['delivering_at'] = kept('delivering_at') ?? now;
        patch['delivered_at'] = kept('delivered_at') ?? now;
        patch['rejection_reason'] = null;
        patch['rejected_by_phone'] = null;
        patch['rejected_by_name'] = null;
      default:
        // rejected / cancelled من اللوحة: الرافض هنا **الإدارة**، لا
        // المندوب. يُكتب نصّاً ثابتاً لا رقماً — فلا يُنسب رفض لمندوب
        // بريء، ولا يحتاج العمود اسماً مزوّراً من الوسيط.
        patch['rejection_reason'] = (reason ?? '').trim().isEmpty
            ? (status == 'cancelled' ? 'إلغاء من الإدارة' : 'رفض من الإدارة')
            : reason!.trim();
        patch['rejected_by_name'] = 'الإدارة';
        patch['rejected_by_phone'] = null;
    }

    try {
      Future<http.Response> send(Map<String, dynamic> body) => _http
          .patch(
            Uri.parse('${_url}orders?id=eq.$orderId'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      var res = await send(patch);

      // ★ «مَن رفض» عمودان لا يظهران إلا بعد SQL_REJECTER_STAMP.sql.
      //   إن لم يُشغَّل الملف بعد يرفض PostgREST الـPATCH كله (42703)،
      //   فيتعطّل تغيير الحالة كلّه لأجل معلومة إضافية — نُعيد المحاولة
      //   بغيرهما: الحالة تُحفظ، ويسقط الختم حتى تشغيل الـSQL.
      if ((res.statusCode < 200 || res.statusCode >= 300) &&
          utf8.decode(res.bodyBytes).contains('rejected_by')) {
        res = await send(
          Map<String, dynamic>.from(patch)
            ..remove('rejected_by_phone')
            ..remove('rejected_by_name'),
        );
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        // ★ نصّ الخادم لا يُبتلع: 403 معناه أن الجلسة ليست أدمن، و25006
        //   أن المشغّل رفض — كل واحد منها إصلاحه في مكان مختلف.
        final detail = _shortBody(utf8.decode(res.bodyBytes));
        lastAdminStatusError =
            'تعذّر تغيير الحالة (HTTP ${res.statusCode})'
            '${detail.isEmpty ? '' : ': $detail'}';
        return false;
      }

      // ★ إشعار الزبون تكتبه القاعدة (مشغّل `trg_notify_status_change`
      //   بمفتاح إزالة تكرار)؛ دورنا النبضة فقط حتى لا ينتظر الهاتف
      //   دورة الاستطلاع. ثم نبض الحالة داخل التطبيق.
      unawaited(
        _notifyOrder(
          orderId,
          _statusNotifyTitle(status),
          '',
          status: status,
          sound: NotifySound.alert.key,
        ),
      );
      if (status == 'pending') {
        final refreshed = await fetchOrderById(orderId);
        if (refreshed != null) {
          final serial = refreshed['serial_number']?.toString().trim() ?? '';
          unawaited(
            notifyDriversOfNewOrder(
              refreshed,
              serial: serial.isEmpty ? '' : '#$serial',
            ),
          );
        }
      }
      return true;
    } catch (e) {
      lastAdminStatusError = 'تعذّر الاتصال: $e';
      return false;
    }
  }

  /// ★ آخر فشل في تغيير حالة طلب من اللوحة (للعرض لا للابتلاع).
  String? lastAdminStatusError;

  static String _statusNotifyTitle(String status) => switch (status) {
    'pending' => 'أُعيد طلبك إلى المندوبين 🔄',
    'accepted' => 'تم قبول طلبك ✅',
    'delivering' => 'طلبك في الطريق 🛵',
    'delivered' => 'تم توصيل طلبك 🎉',
    'cancelled' => 'تم إلغاء الطلب ❌',
    _ => 'تم رفض الطلب ❌',
  };

  // ==========================================================
  //  تعديل بنود الطلب (المندوب فقط)
  // ==========================================================

  Future<String?> _orderIdOfItem(String itemId) async {
    try {
      final res = await _http.get(
        Uri.parse('${_url}order_items?select=order_id&id=eq.$itemId&limit=1'),
        headers: _headers,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return null;
        return (list.first as Map)['order_id']?.toString();
      }
    } catch (_) {}
    return null;
  }

  /// إعادة حساب total_amount للطلب من بنوده.
  Future<void> _recalcOrderTotal(String? orderId) async {
    if (orderId == null || orderId.isEmpty) return;
    try {
      final items = await fetchOrderItems(orderId);
      if (items.isEmpty) return;
      var sum = 0.0;
      for (final it in items) {
        sum +=
            (it['total'] as num?)?.toDouble() ??
            ((it['price'] as num?)?.toDouble() ?? 0) *
                ((it['quantity'] as num?)?.toDouble() ?? 1);
      }
      await _http.patch(
        Uri.parse('${_url}orders?id=eq.$orderId'),
        headers: _headers,
        body: jsonEncode({'total_amount': sum}),
      );
    } catch (_) {}
  }

  /// إشعار الزبون عند أي تعديل على بنود طلبه (استبدال / سعر / حذف).
  ///
  /// [sound] نغمة الحدث: `replaced` للاستبدال والحذف، `price_changed`
  /// لتغيير السعر.
  ///
  /// ★ 2026-10-26 — **لا عرض ولا صوت على جهاز مَن نفّذ التعديل**.
  ///   كانت هذه الدالة تبثّ بطاقة الإشعار وتشغّل الصوت مباشرة على نفس
  ///   الجهاز الذي ضغط «حذف/استبدال» — أي جهاز المندوب — وبنصّ يخصّ
  ///   الزبون وحده («تم حذف منتج **من طلبك**»). والكارثة الثانية:
  ///   الصوت كان يمشي **مرتين** للحدث الواحد (النغمة من
  ///   `StatusCenter.broadcast` ثم `play(force: …)` التي تتجاوز حتى
  ///   خيار إيقاف الأصوات في الإعدادات)، فكل صنف يلمسه المندوب
  ///   يضيف صوتاً.
  ///   الزبون يستلم إشعاره من مساره هو: صفّ `notifications` الذي يكتبه
  ///   الخادم + نبضة `pokeNotifyServer` وبثّ `order.item_removed` الذي
  ///   يعالجه `_announceItemRemoved` — وكلها تحرسها بوابة
  ///   `NotificationDedup` الموحّدة فلا يتكرر الصوت عنده.
  ///   أما المنفّذ فرده على فعله هو شريط «تم حذف المنتج» في شاشته.
  Future<void> _notifyItemChange(
    String? orderId, {
    required String title,
    required String body,
    String? driverName,
    NotifySound sound = NotifySound.replaced,
  }) async {
    if (orderId == null || orderId.isEmpty) return;
    final who = (driverName != null && driverName.trim().isNotEmpty)
        ? ' بواسطة ${driverName.trim()}'
        : '';
    final orderIdStr = orderId;
    final serialTag = await _orderSerialTag(orderIdStr);
    unawaited(
      _notifyOrder(
        orderIdStr,
        title,
        '$body$who',
        sound: sound.key,
        type: 'item_changed',
        status: 'item_changed',
        serial: serialTag,
      ),
    );
  }

  /// تعديل سعر قطعة (مع تحديث total الصف).
  Future<bool> updateOrderItemPrice(
    String itemId,
    double price, {
    String? productName,
    String? driverName,
  }) async {
    if (itemId.isEmpty) return false;
    try {
      final orderId = await _orderIdOfItem(itemId);
      final qty = (await _itemQuantity(itemId)) ?? 1;
      final res = await _http.patch(
        Uri.parse('${_url}order_items?id=eq.$itemId'),
        headers: _headers,
        body: jsonEncode({'price': price, 'total': price * qty}),
      );
      // ★ `_touched`: الرد 200 وحده لا يكفي — لو منعت سياسة الصفّ التعديل
      //   يرجع PostgREST 200 بقائمة فارغة، فيقول «تم» وهو لم يتغيّر شيء.
      if (!_touched(res)) return false;
      await _recalcOrderTotal(orderId);
      final serial = orderId == null ? '' : await _orderSerialTag(orderId);
      unawaited(
        _notifyItemChange(
          orderId,
          title: 'تم تعديل منتج في طلبك',
          body:
              'الطلب $serial: ${productName ?? 'المنتج'} صار $price '
              '(الكمية $qty).',
          driverName: driverName,
          sound: NotifySound.priceChanged,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// ★ هل غيّر PATCH/DELETE سطراً فعلاً؟
  ///
  ///   الطلبات تحمل `Prefer: return=representation`، ولو منعت سياسة RLS
  ///   الكتابةَ يرجع السيرفر **200 بقائمة فارغة** لا بخطأ. وكان الكود
  ///   يفحص الرقم وحده ⇒ شاشة المندوب تقول «تم تعديل السعر» ولم يتغيّر
  ///   شيء في القاعدة. الفحص الآن: ردّ ناجح **وجسم فيه سطر**.
  bool _touched(http.Response res) {
    final code = res.statusCode;
    if (code < 200 || code >= 300) return false;
    try {
      final body = res.body;
      if (body.trim().isEmpty) return true; // 204 بلا تمثيل
      final decoded = jsonDecode(body);
      if (decoded is List) return decoded.isNotEmpty;
      if (decoded is Map) {
        // خطأ PostgREST القادم داخل ردّ 2xx غير متوقّع ⇒ لا نعدّه نجاحاً
        return decoded['error'] == null;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<double?> _itemQuantity(String itemId) async {
    try {
      final res = await _http.get(
        Uri.parse('${_url}order_items?select=quantity&id=eq.$itemId&limit=1'),
        headers: _headers,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return null;
        return list.first['quantity'] == null
            ? null
            : double.tryParse('${list.first['quantity']}');
      }
    } catch (_) {}
    return null;
  }

  /// اسم المنتج الحالي للبند (لعرضه قبل الاستبدال).
  Future<String> _itemName(String itemId) async {
    try {
      final res = await _http.get(
        Uri.parse(
          '${_url}order_items?select=product_name&id=eq.$itemId&limit=1',
        ),
        headers: _headers,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return 'منتج';
        final n = (list.first as Map)['product_name']?.toString().trim() ?? '';
        return (n.isEmpty || n == 'null') ? 'منتج' : n;
      }
    } catch (_) {}
    return 'منتج';
  }

  /// استبدال منتج في الطلب بقطعة أخرى.
  ///
  /// `productId`/`shopId` هما معرّفا القطعة الجديدة: بدونهما كان السجل
  /// يحتفظ بمعرّف المنتج القديم مع اسم وسعر وصورة المنتج الجديد، فتناقض
  /// السجل ولا يطابق أي منتج في الكتالوج.
  Future<bool> replaceOrderItem({
    required String itemId,
    required String orderId,
    required String productName,
    required String shopName,
    required double price,
    String? productId,
    String? shopId,
    String? image,
    String? driverName,
  }) async {
    if (itemId.isEmpty) return false;
    try {
      final qty = await _itemQuantity(itemId);
      final oldName = await _itemName(itemId);
      final body = <String, dynamic>{
        'product_name': productName,
        'shop_name': shopName,
        'price': price,
        'total': price * (qty ?? 1),
        'product_image': image,
      };
      if (productId != null && productId.isNotEmpty) {
        body['product_id'] = productId;
      }
      if (shopId != null && shopId.isNotEmpty) {
        body['shop_id'] = shopId;
      }
      final res = await _http.patch(
        Uri.parse('${_url}order_items?id=eq.$itemId'),
        headers: _headers,
        body: jsonEncode(body),
      );
      if (!_touched(res)) return false;
      await _recalcOrderTotal(orderId);
      final serial = await _orderSerialTag(orderId);
      unawaited(
        _notifyItemChange(
          orderId,
          title: 'تم استبدال منتج في طلبك',
          body:
              'الطلب $serial: استُبدل «$oldName» بـ «$productName» '
              'بسعر $price.',
          driverName: driverName,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// حذف قطعة من الطلب.
  Future<bool> deleteOrderItem(
    String itemId,
    String orderId, {
    String? driverName,
  }) async {
    if (itemId.isEmpty) return false;
    try {
      final name = await _itemName(itemId);
      final res = await _http.delete(
        Uri.parse('${_url}order_items?id=eq.$itemId'),
        headers: _headers,
      );
      if (!_touched(res)) return false;
      await _recalcOrderTotal(orderId);
      final serial = await _orderSerialTag(orderId);
      unawaited(
        _notifyItemChange(
          orderId,
          title: 'تم حذف منتج من طلبك',
          body: 'الطلب $serial: حُذف «$name» من الطلب.',
          driverName: driverName,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // ==========================================================
  //  إحصائيات
  // ==========================================================

  /// إحصائيات الطلبات: اليوم / ٧ أيام / ٣٠ يوماً / كل الفترات.
  ///
  /// ★ المكتمل وحده (delivered) يدخل الأرقام: المرفوض والملغي لا
  ///   يدخلان أبداً — نفس قاعدة `order_stats` على الخادم.
  ///
  /// المسار المفضّل: دالة `order_stats` على الخادم (أرقام فقط، بلا تحميل
  /// الطلبات إطلاقاً). إن لم تكن موجودة بعد، نحسبها محلياً بنفس التقسيم.
  Future<Map<String, dynamic>> fetchOrderStats() async {
    // 1) دالة الخادم — الأدق والأخف.
    try {
      final res = await _http
          .get(Uri.parse('${_url}rpc/order_stats'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['today'] is Map) {
          final m = Map<String, dynamic>.from(decoded);
          // تحويل المفاتيح إلى أرقام (jsonb يعيد أرقاماً سليمة).
          return {
            'today': _numBucket(m['today']),
            'week': _numBucket(m['week']),
            // ★ `month` كان مفقوداً من كلا المسارين، والواجهة تقرأه
            //   ⇒ «طلبات الشهر» كان يعرض صفراً دائماً بلا سبب ظاهر.
            'month': _numBucket(m['month']),
            'last_30_days': _numBucket(m['last_30_days']),
            'all_time': _numBucket(m['all_time']),
            'by_status': Map<String, dynamic>.from(
              (m['by_status'] as Map?) ?? const {},
            ),
            'generated_at':
                m['generated_at']?.toString() ??
                DateTime.now().toIso8601String(),
          };
        }
      }
    } catch (_) {}

    // 2) حساب محلي احتياطي بنفس التقسيم (أعمدة محدودة + ترقيم صفحات).
    return _fetchOrderStatsLocal();
  }

  /// ★ استدعاء دالة PostgREST (RPC) وإرجاع نتيجة JSON خام.
  ///
  /// ★★ POST لا GET — وهذه ليست تفصيلاً:
  ///   PostgREST ينفّذ استدعاءات **GET داخل معاملة للقراءة فقط**.
  ///   فأي دالة تكتب (مثل `commit_discount_code` التي تُدرج في
  ///   جدول الاستعمالات) تُرفض بـ:
  ///       25006 cannot execute INSERT in a read-only transaction
  ///   ومعها 405. كان هذا يُظهر «تعذّر الاتصال» في السلة بعد كل
  ///   طلب، لأننا كنا نقرأ الكود بـGET ولا نُقصمه إلا بـPOST.
  ///   الاستدعاء بالاسم يُعمل في الحالتين، فPOST هو الصحيح دائماً.
  ///
  /// يُرجع `null` عند فشل الشبكة أو رمز خارج 2xx، ويُخزّن السبب في
  /// [lastRpcError]. أما ردّ الخادم داخل 2xx فيُعاد كما هو ولو كان
  /// رسالة خطأ مفهومة — فالشاشة تعرضها للمستخدم.
  ///
  /// ★ إعادة محاولة واحدة بـGET عند **405 فقط** — انظر [_rpcGetRetry].
  Future<Object?> rpcCall(
    String fn,
    Map<String, dynamic> args, {
    int timeoutSeconds = 15,
  }) async {
    try {
      var res = await _http
          .post(
            Uri.parse('${_url}rpc/$fn'),
            headers: _headers,
            body: jsonEncode(args),
          )
          .timeout(Duration(seconds: timeoutSeconds));
      res = await _rpcGetRetry(fn, args, res, timeoutSeconds);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = utf8.decode(res.bodyBytes);
        // ★ 404 + PGRST202 = الدالة غير مثبّتة أو اسمها خطأ.
        //   هذا أشيع سبب في مشروعنا (ملف SQL لم يُشغَّل).
        final missing = res.statusCode == 404 && body.contains('PGRST202');
        lastRpcError = missing
            ? 'الدالة غير مثبّتة على الخادم — شغّل ملف SQL الخاص بها'
            : 'الخطأ ${res.statusCode}: ${_shortBody(body)}';
        return null;
      }
      lastRpcError = null;
      final raw = utf8.decode(res.bodyBytes);
      if (raw.trim().isEmpty) return null;
      return jsonDecode(raw);
    } catch (e) {
      lastRpcError = 'تعذّر الاتصال: $e';
      return null;
    }
  }

  /// ★ 405 على POST = الخادم يرفض هذه الطريقة لهذا المسار تحديداً.
  ///
  /// الدوال **القارئة** (`stable`) يصرّح لها PostgREST بـGET، وهو مسار
  /// مُجرَّب في هذا المشروع (`fetchOrderStatsRange` يعمل به منذ زمن).
  /// فحين ترجع «405» على_POST نُعيد الطلب مرة واحدة بـGET بنفس
  /// المعاملات في نصّ الاستعلام.
  ///
  /// ★ لا خطر في هذا ولا تغييب للأمان:
  ///   - لا يجري إلا بعد فشل مؤكّد (405)، فلا يمسّ أي مسار يعمل.
  ///   - دوال الكتابة تبقى محميّة: GET يُنفَّذ في معاملة **للقراءة
  ///     فقط**، فأي محاولة إدخال/تحديث تُرفض هناك (25006) قبل أن
  ///     تكتب شيئاً — أي أن هذه المحاولة لا تمنح أحداً صلاحية جديدة.
  ///   - لا نمرّر قَيماً مركّبة (خرائن/مصافي) في نصّ الاستعلام: لو
  ///     كان المعامل غير بدائي نُبقي ردّ POST الأصلي بدل تشويهه.
  Future<http.Response> _rpcGetRetry(
    String fn,
    Map<String, dynamic> args,
    http.Response res,
    int timeoutSeconds,
  ) async {
    if (res.statusCode != 405) return res;
    final primitive = args.values.every(
      (v) => v == null || v is num || v is bool || v is String,
    );
    if (!primitive) return res;
    try {
      final uri = Uri.parse('${_url}rpc/$fn').replace(
        queryParameters: {
          for (final e in args.entries) e.key: '${e.value ?? ''}',
        },
      );
      final again = await _http
          .get(uri, headers: _headers)
          .timeout(Duration(seconds: timeoutSeconds));
      // ★ نجح GET؟ نُرجعه. فشل؟ يُفضَّل بقاء ردّ POST برسالته الأصلية.
      if (again.statusCode >= 200 && again.statusCode < 300) return again;
      return res;
    } catch (_) {
      return res;
    }
  }

  /// ★ آخر خطأ من أي استدعاء دالة — للعرض في الواجهة.
  String? lastRpcError;

  /// ★ آخر رسالة فشل من `order_stats_range` — لعرضها في الواجهة.
  ///
  /// كانت الأخطاء تُبتلع ويُعرض «تحقق من الإنترنت» على أي عطل، وهو
  /// ما جعل لوحة الإحصائيات تبدو معطّلة وهي ليست كذلك.
  String? lastOrderStatsError;

  /// ★ إحصائيات حقيقية لأي فترة يختارها الأدمن.
  ///
  /// ★ المكتمل وحده (delivered) يدخل الأرقام؛ المرفوض والملغي لا
  ///   يدخلان أي رقم — القاعدة في `order_stats_range` على الخادم.
  ///
  /// [from] و[to] شاملان اليومين. نبعت `to` + يوم واحد إلى الخادم
  /// لأن النطاق هناك **غير شامل**، وإلا فوّتنا طلباً في ٢٣:٥٩.
  Future<Map<String, dynamic>> fetchOrderStatsRange(
    DateTime from,
    DateTime to,
  ) async {
    lastOrderStatsError = null;
    final start = DateTime(from.year, from.month, from.day);
    // نهاية الغد = حدّ أعلى حصري يغطّي اليوم المطلوب كاملاً.
    final end = DateTime(
      to.year,
      to.month,
      to.day,
    ).add(const Duration(days: 1));

    try {
      final uri = Uri.parse('${_url}rpc/order_stats_range').replace(
        queryParameters: {
          'p_from': start.toUtc().toIso8601String(),
          'p_to': end.toUtc().toIso8601String(),
          'p_tz': _localTzOffset(),
        },
      );
      final res = await _http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is Map && body.containsKey('count')) {
          return Map<String, dynamic>.from(body);
        }
        lastOrderStatsError = 'رد غير متوقع من الخادم';
      } else {
        lastOrderStatsError =
            'الخطأ ${res.statusCode}: '
            '${_shortBody(res.body)}';
      }
    } catch (e) {
      lastOrderStatsError = 'تعذّر الاتصال: $e';
    }

    // ★ الاحتياطي المحلي: نفس التقسيم، فيبقى الرقم معروضاً لو
    //   الـSQL لم يُشغَّل أو الشبكة تعطّلت. وهو أبطأ (تنزيل صفحات)
    //   أُصلح: كان السطر مكتوباً بحروف تالفة فظهر «????»
    final local = await _orderStatsRangeLocal(start, end);
    if (local['count'] == 0 && lastOrderStatsError != null) {
      return {...local, 'local_fallback': true};
    }
    return {...local, 'local_fallback': lastOrderStatsError != null};
  }

  /// إزاحة التوقيت المحلية بصيغة `±HH:MM` — لتجميع الأيام صحيحة.
  ///
  /// نحسبها من إزاحة الجهاز، فلا نثبّت «+03:00» في الكود ولا في
  /// القاعدة. والقاعدة تتحقق من الشكل وتستعمل الافتراضي إن ساء.
  static String _localTzOffset() {
    final off = DateTime.now().timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final h = off.inHours.abs().toString().padLeft(2, '0');
    final m = (off.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '$sign$h:$m';
  }

  /// ★ نفس حساب الفترة، لكن بالترقيم من `orders` مباشرة.
  ///
  /// ★ المكتمل وحده (delivered): المرفوض والملغي — وكل ما لم يكتمل —
  ///   لا يدخل أي رقم. واليوم يُحسب بتاريخ الاكتمال (`delivered_at`)
  ///   وإن غاب فبتاريخ الإنشاء، كما في `order_stats_range`.
  ///   (الفلترة بالتاريخ هنا على تاريخ الإنشاء — الخادم هو المرجع.)
  Future<Map<String, dynamic>> _orderStatsRangeLocal(
    DateTime start,
    DateTime end,
  ) async {
    var count = 0;
    var amount = 0.0;
    final customers = <String>{};
    final daily = <String, Map<String, dynamic>>{};
    final shopTotals = <String, double>{};
    final completedIds = <String>[];

    String dayOf(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    try {
      var offset = 0;
      const page = 1000;
      while (true) {
        final uri = Uri.parse(
          '${_url}orders?select=id,status,total_amount,created_at,delivered_at,user_phone'
          '&status=eq.delivered'
          '&created_at=gte.${start.toUtc().toIso8601String()}'
          '&created_at=lt.${end.toUtc().toIso8601String()}'
          '&order=created_at.desc&limit=$page&offset=$offset',
        );
        final res = await _http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode < 200 || res.statusCode >= 300) break;
        final rows = jsonDecode(res.body) as List;
        if (rows.isEmpty) break;

        for (final r in rows) {
          final m = Map<String, dynamic>.from(r as Map);
          final created = DateTime.tryParse(
            m['created_at']?.toString() ?? '',
          )?.toLocal();
          final doneAt = DateTime.tryParse(
            m['delivered_at']?.toString() ?? '',
          )?.toLocal();
          final at = doneAt ?? created;
          if (at == null) continue;
          final amt = (m['total_amount'] as num?)?.toDouble() ?? 0;

          count++;
          amount += amt;
          final phone = m['user_phone']?.toString().trim() ?? '';
          if (phone.isNotEmpty) customers.add(phone);
          final id = m['id']?.toString() ?? '';
          if (id.isNotEmpty) completedIds.add(id);

          final d = dayOf(at);
          final b = daily.putIfAbsent(d, () => {'day': d, 'count': 0});
          b['count'] = (b['count'] as int) + 1;
        }

        if (rows.length < page) break;
        offset += page;
        if (offset >= 20000) break;
      }

      // أفضل الصيدليات: بنود الطلبات المكتملة وحدها، بمعرّفاتها.
      // ★ كان الاستعلام السابق يجمع بنود **كل** الطلبات في كل
      //   الأزمنة، فتظهر صيدليات بمبالغ ليست من الفترة أصلاً.
      const chunk = 80;
      for (var i = 0; i < completedIds.length; i += chunk) {
        final endIdx = i + chunk < completedIds.length
            ? i + chunk
            : completedIds.length;
        final ids = completedIds.sublist(i, endIdx);
        final uri = Uri.parse(
          '${_url}order_items?select=shop_name,total,price,quantity'
          '&order_id=in.(${ids.join(',')})',
        );
        final res = await _http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode < 200 || res.statusCode >= 300) break;
        final rows = jsonDecode(res.body) as List;
        for (final r in rows) {
          final m = Map<String, dynamic>.from(r as Map);
          final name = (m['shop_name']?.toString() ?? '').trim();
          if (name.isEmpty) continue;
          final tot =
              (m['total'] as num?)?.toDouble() ??
              (m['price'] as num?)?.toDouble() ??
              0;
          shopTotals[name] = (shopTotals[name] ?? 0) + tot;
        }
      }
    } catch (e) {
      lastOrderStatsError ??= 'تعذّر الاتصال: $e';
    }

    final topShops =
        (shopTotals.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(5)
            .map((e) => {'shop_name': e.key, 'gross': e.value, 'items': 0})
            .toList();

    final dailyList = daily.values.toList()
      ..sort((a, b) => (a['day'] as String).compareTo(b['day'] as String));

    return {
      'from': start.toUtc().toIso8601String(),
      'to': end.toUtc().toIso8601String(),
      'count': count,
      'amount': double.parse(amount.toStringAsFixed(2)),
      'delivered': count,
      'customers': customers.length,
      'avg': count == 0
          ? 0.0
          : double.parse((amount / count).toStringAsFixed(2)),
      'daily': dailyList,
      'top_shops': topShops,
    };
  }

  Map<String, dynamic> _numBucket(Object? raw) {
    final m = Map<String, dynamic>.from((raw as Map?) ?? const {});
    int n(String k) =>
        m[k] is num ? (m[k] as num).toInt() : int.tryParse('${m[k]}') ?? 0;
    double d(String k) => m[k] is num
        ? (m[k] as num).toDouble()
        : double.tryParse('${m[k]}') ?? 0;
    return {
      'count': n('count'),
      'amount': d('amount'),
      'delivered': n('delivered'),
    };
  }

  Future<Map<String, dynamic>> _fetchOrderStatsLocal() async {
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startWeek = startToday.subtract(const Duration(days: 6));
    final start30 = startToday.subtract(const Duration(days: 29));

    final startMonth = DateTime(now.year, now.month, 1);
    var todayCount = 0,
        weekCount = 0,
        monthCount = 0,
        d30Count = 0,
        todayDelivered = 0,
        weekDelivered = 0,
        monthDelivered = 0;
    var todayAmount = 0.0, weekAmount = 0.0, monthAmount = 0.0, d30Amount = 0.0;
    var allAmount = 0.0, allCount = 0;
    final byStatus = <String, int>{};

    try {
      var from = 0;
      const page = 1000;
      while (true) {
        final uri = Uri.parse(
          '${_url}orders?select=order_number,status,total_amount,created_at,delivered_at'
          '&order=created_at.desc&limit=$page&offset=$from',
        );
        final res = await _http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode < 200 || res.statusCode >= 300) break;
        final rows = List<Map<String, dynamic>>.from(
          jsonDecode(res.body) as List,
        );
        if (rows.isEmpty) break;
        for (final r in rows) {
          final status = r['status']?.toString() ?? 'pending';
          byStatus[status] = (byStatus[status] ?? 0) + 1;
          // ★ المكتمل وحده يدخل الأرقام — المرفوض والملغي لا.
          if (status != 'delivered') continue;
          // يوم البيع = يوم الاكتمال، وإن غاب فتاريخ الإنشاء.
          final dt =
              DateTime.tryParse(
                r['delivered_at']?.toString() ?? '',
              )?.toLocal() ??
              DateTime.tryParse(r['created_at']?.toString() ?? '')?.toLocal();
          final amount = (r['total_amount'] as num?)?.toDouble() ?? 0;
          allCount++;
          allAmount += amount;
          if (dt == null) continue;
          if (!dt.isBefore(start30)) {
            d30Count++;
            d30Amount += amount;
          }
          if (!dt.isBefore(startWeek)) {
            weekCount++;
            weekAmount += amount;
            weekDelivered++;
          }
          if (!dt.isBefore(startMonth)) {
            monthCount++;
            monthAmount += amount;
            monthDelivered++;
          }
          if (!dt.isBefore(startToday)) {
            todayCount++;
            todayAmount += amount;
            todayDelivered++;
          }
        }
        if (rows.length < page) break;
        from += page;
        if (from >= 20000) break;
      }
    } catch (_) {
      return const {};
    }

    Map<String, dynamic> bucket(int c, double a, int d) => {
      'count': c,
      'amount': a,
      'delivered': d,
    };

    return {
      'today': bucket(todayCount, todayAmount, todayDelivered),
      'week': bucket(weekCount, weekAmount, weekDelivered),
      'month': bucket(monthCount, monthAmount, monthDelivered),
      'last_30_days': bucket(d30Count, d30Amount, 0),
      'all_time': {'count': allCount, 'amount': allAmount},
      'by_status': byStatus,
      'generated_at': now.toIso8601String(),
    };
  }

  /// بحث موحّد عن منتجات وصيدليات.
  Future<List<Map<String, dynamic>>> globalSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}rpc/global_search?p_q=${Uri.encodeComponent(q)}'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body) as List);
      }
    } catch (_) {}

    final out = <Map<String, dynamic>>[];
    final needle = q.toLowerCase();
    try {
      for (final p in await fetchProducts()) {
        if ((p['name']?.toString() ?? '').toLowerCase().contains(needle)) {
          out.add({...p, 'kind': 'product'});
        }
        if (out.length >= 20) break;
      }
    } catch (_) {}
    try {
      for (final s in await fetchShops()) {
        if ((s['name']?.toString() ?? '').toLowerCase().contains(needle)) {
          out.add({...s, 'kind': 'shop'});
        }
        if (out.length >= 40) break;
      }
    } catch (_) {}
    return out;
  }

  // ==========================================================
  //  حساب صاحب الصيدلية
  // ==========================================================

  /// إحصائيات صاحب الصيدلية (لوحة الأدمن).
  Future<Map<String, dynamic>> fetchShopOwnerStats(
    String ownerPhone, {
    String shopName = '',
  }) async {
    if (ownerPhone.isEmpty) return _emptyOwnerStats();
    // لا بيانات شخصية في logcat: آخر أربعة أرقام فقط مع الأعداد.
    final tail = ownerPhone.length > 4
        ? ownerPhone.substring(ownerPhone.length - 4)
        : ownerPhone;
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}v_shop_owner_stats?select=*&owner_phone=eq.$ownerPhone&limit=1',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isNotEmpty) {
          final row = Map<String, dynamic>.from(list.first as Map);
          // ★ أرقام البطاقة تذهب إلى logcat (`adb logcat -d -s flutter |
          //   grep OWNER_STATS`): هذا دليل قاطع أن `v_shop_owner_stats` صار
          //   يقرأ خط الأساس — أي أن التصفير وصل إلى البطاقة فعلًا.
          debugPrint(
            'OWNER_STATS …$tail منتجات=${row['product_count']} '
            'طلبات=${row['total_orders']} مكتملة=${row['delivered_orders']} '
            'مرفوضة=${row['rejected_orders']} ارباح=${row['revenue']}',
          );
          return row;
        }
        // ★ القائمة فارغة = هذا الرقم ليس في `v_shop_owner_stats` (صيدلية بلا
        //   owner_phone نظيف مثلاً) ⇒ البطاقة ستعود للحساب المحلي كل-Time.
        debugPrint('OWNER_STATS_EMPTY …$tail');
      } else {
        // ★ فشل الطلب (404/401/42P01 …) يعني أن العرض غير مثبَّت أو بلا صلاحية
        //   — وهو بالضبط ما يجعل «علامة الدولار» لا تصفر.
        _logAdminHttp('owner_stats…$tail', res.statusCode, res.body);
      }
    } catch (e) {
      debugPrint('OWNER_STATS_ERROR …$tail $e');
    }

    // بديل — بطبقتين.
    debugPrint('OWNER_STATS_FALLBACK …$tail');
    final shop = await fetchShopByOwnerPhone(ownerPhone);
    final name = shop?['name']?.toString() ?? shopName;
    if (name.isEmpty) return _emptyOwnerStats();
    var liveProducts = 0;
    try {
      liveProducts = (await fetchProducts(
        shopId: shop?['id']?.toString(),
      )).length;
    } catch (_) {
      liveProducts = 0;
    }

    // ★ الطبقة الأولى: `get_shop_balance` من الخادم — وهي تعرف **خط الأساس**،
    //   فأرقامها «منذ آخر تصفير» وليس كل-Time. بهذا تُصفَّر البطاقة فورًا
    //   حتى لو كان العرض `v_shop_owner_stats` غير مثبَّت أو بلا صلاحية،
    //   ويبقى «منتجات» حيًّا من جدول `products` (يتغيّر مع الحذف والإضافة).
    final bal = await _shopBalanceFromServer(ownerPhone);
    if (bal != null) {
      final ongoing = (bal['orders_count'] as num?)?.toInt() ?? 0;
      final delivered = (bal['delivered_orders'] as num?)?.toInt() ?? 0;
      final rejected = (bal['rejected_orders'] as num?)?.toInt() ?? 0;
      final row = <String, dynamic>{
        'owner_phone': ownerPhone,
        'shop_name': name,
        'product_count': liveProducts,
        'total_orders': ongoing + rejected,
        'delivered_orders': delivered,
        'rejected_orders': rejected,
        'revenue': (bal['gross'] as num?)?.toDouble() ?? 0.0,
        'in_progress_orders': ongoing > delivered ? ongoing - delivered : 0,
        'balance': (bal['balance'] as num?)?.toDouble() ?? 0.0,
        'reset_at': bal['reset_at'],
      };
      debugPrint(
        'OWNER_STATS_RPC …$tail منتجات=${row['product_count']} '
        'طلبات=${row['total_orders']} مكتملة=$delivered '
        'مرفوضة=$rejected ارباح=${row['revenue']} '
        'رصيد=${row['balance']}',
      );
      return row;
    }

    // الطبقة الأخيرة: حساب محلي كل-Time (يظهر فقط إن تعذّر الاتصال تمامًا).
    debugPrint('OWNER_STATS_LOCAL …$tail');
    try {
      final itemsRes = await _http.get(
        Uri.parse(
          '${_url}order_items?select=order_id&shop_name=eq.'
          '${Uri.encodeComponent(name)}',
        ),
        headers: _headers,
      );
      final ids = <String>{};
      if (itemsRes.statusCode >= 200 && itemsRes.statusCode < 300) {
        for (final r in jsonDecode(itemsRes.body) as List) {
          final id = (r as Map)['order_id']?.toString();
          if (id != null) ids.add(id);
        }
      }
      if (ids.isEmpty) {
        return {
          'owner_phone': ownerPhone,
          'shop_name': name,
          'product_count': liveProducts,
          'total_orders': 0,
          'delivered_orders': 0,
          'rejected_orders': 0,
          'revenue': 0.0,
        };
      }
      final joined = ids.join(',');
      final orders = await _fetchOrders('id=in.($joined)&limit=100');
      var delivered = 0, rejected = 0;
      var revenue = 0.0;
      for (final o in orders) {
        final s = o['status']?.toString() ?? '';
        if (s == 'delivered') {
          delivered++;
          revenue += (o['total_amount'] as num?)?.toDouble() ?? 0;
        } else if (s == 'rejected' || s == 'cancelled') {
          rejected++;
        }
      }
      return {
        'owner_phone': ownerPhone,
        'shop_name': name,
        'product_count': liveProducts,
        'total_orders': orders.length,
        'delivered_orders': delivered,
        'rejected_orders': rejected,
        'revenue': revenue,
      };
    } catch (_) {
      return _emptyOwnerStats();
    }
  }

  Map<String, dynamic> _emptyOwnerStats() {
    return const {
      'owner_phone': '',
      'shop_name': '',
      'product_count': 0,
      'total_orders': 0,
      'delivered_orders': 0,
      'rejected_orders': 0,
      'revenue': 0.0,
    };
  }

  /// ★★ عمولة المنصة الافتراضية (نسبة مئوية).
  ///
  /// هذا **احتياطي فقط** للنسب المحلية. الرقم المعروض فعلياً في الواجهة
  /// يُشتقّ من دفتر `shop_earnings` (‏`commission ÷ gross`)، فالنتيجة
  /// صحيحة ولو اختلفت النسبة في القاعدة. مرجع واحد للحقيقة = الدفتر.
  static const int defaultCommissionRate = 10;

  /// ★ النسبة الحقيقية للرصيد: تُحسب من الأرقام نفسها، لا من ثابت.
  ///
  /// كان يُقرأ `commission_rate` من ردّ القاعدة، وهو **ثابت مكتوب في
  /// دالة** ⇒ عرض 15% بينما الحساب 10%. الآن إن كانت هناك مبالغ
  /// نحصل على النسبة الفعلية منها، وإن كان الرصيد صفرياً نرجع للافتراضي.
  static int commissionRateOf(Map<String, dynamic> d) {
    final gross = (d['gross'] as num?)?.toDouble() ?? 0;
    final commission = (d['commission'] as num?)?.toDouble() ?? 0;
    if (gross > 0 && commission > 0) {
      final derived = (commission / gross * 100).round();
      // نتجاهل الشواذّ ( commission > gross أو نسبة خارج 0..100 ).
      if (derived > 0 && derived <= 100) return derived;
    }
    return (d['commission_rate'] as num?)?.toInt() ?? defaultCommissionRate;
  }

  /// صورة صفرية متوافقة مع مخرجات `get_shop_balance`.
  Map<String, dynamic> _emptyShopBalance() => {
    'balance': 0.0,
    'net': 0.0,
    'gross': 0.0,
    'commission': 0.0,
    'commission_rate': defaultCommissionRate,
    'earned': 0.0,
    'paid': 0.0,
    'pending': 0.0,
    'items_sold': 0,
    'orders_count': 0,
    'delivered_orders': 0,
    'settled_orders': 0,
    'rejected_orders': 0,
    'shop_name': '',
  };

  /// رصيد صاحب الصيدلية: من دفتر الأرباح في القاعدة (عمولة 10%).
  ///
  /// كان يُحسب هنا في العميل مباشرة من `order_items` + `orders`، وفيه
  /// ثلاث ثقوب حقيقية:
  ///   1) `&limit=500` ⇒ أي صيدلية تجاوز ٥٠٠ بند يرى رصيداً ناقصاً بصمت.
  ///   2) كان يعدّ **100%** من الإجمالي بلا استقطاع عمولة المنصة.
  ///   3) لا يعرف الدفعات (تصفير الرصيد) فلا ينزل الرصيد أبداً.
  /// الآن المصدر هو دالة القاعدة `get_shop_balance`: دفتر مُثبَّت
  /// وذرّي (لا يُحتسب الطلب مرتين) وقابل للتدقيق.
  ///
  /// إن لم يكن SQL مُشغَّلاً بعد، نرجع لحساب محلي **بنسبة الخصم نفسها**
  /// 100% كي لا تتناقض الأرقام بين الوضعين.
  Future<Map<String, dynamic>> fetchShopOwnerBalance(String ownerPhone) async {
    final m = await _shopBalanceFromServer(ownerPhone);
    if (m != null) return m;
    // احتياطي: قبل تشغيل ملف SQL الجديد.
    return _localShopOwnerBalance(ownerPhone);
  }

  /// يقرأ `get_shop_balance` من الخادم **وحده** (بلا احتياطي محلي) — `null` عند
  /// الفشل. المهم هنا: هذه الدالة تعرف **خط الأساس الزمني** للتصفير، فعدّاداتها
  /// وأرباحها «من آخر تصفير» وليس كل-Time؛ لذلك تُصلح بطاقة «أصحاب الصيدليات»
  /// حتى لو كان `v_shop_owner_stats` غير مثبَّت على الخادم.
  Future<Map<String, dynamic>?> _shopBalanceFromServer(
    String ownerPhone,
  ) async {
    if (ownerPhone.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/get_shop_balance'),
            headers: _headers,
            body: jsonEncode({'p_owner_phone': ownerPhone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is Map) {
          final m = Map<String, dynamic>.from(body);
          if (m.isNotEmpty && m.containsKey('balance')) return m;
        }
      }
    } catch (_) {}
    return null;
  }

  /// سجل طلبات صاحب الصيدلية: مبيعاته **و** طلبات المندوب التي أرسلها،
  /// مع صافي ربحه في كل طلب بيع.
  ///
  /// ★ `null` = تعذّر الجلب ≠ «لا يوجد». الشاشة تعرض السبب
  ///   بدل قائمة فارغة توحي التاجر أن صيدليته لا يبيع شيئاً.
  String? lastShopOrdersError;

  Future<Map<String, dynamic>?> fetchShopCompletedOrders(
    String ownerPhone,
  ) async {
    lastShopOrdersError = null;
    if (ownerPhone.isEmpty) return null;
    ApiMetrics.hit('shop_completed_orders');
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/my_shop_orders'),
            headers: _headers,
            body: jsonEncode({'p_owner_phone': ownerPhone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 404) {
        lastShopOrdersError = 'السجل غير مثبَّت — شغّل SQL_SHOP_ORDERS.sql';
        return null;
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is Map && body.isNotEmpty) {
          return Map<String, dynamic>.from(body);
        }
        lastShopOrdersError = 'رد غير متوقع من الخادم';
        return null;
      }
      lastShopOrdersError = 'تعذّر جلب السجل (${res.statusCode})';
      return null;
    } catch (_) {
      lastShopOrdersError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  // ==================================================================
  // ★★ بوابة موافقة الصيدلية على طلبات الوصفة
  //   (تُنصَّب بدوال ملف SQL_PHARMACY_APPROVAL.sql)
  // ==================================================================

  bool _pharmacyGateReady = false;
  DateTime? _pharmacyGateFailedAt;

  /// هل سكربت موافقة الصيدلية منصَّب في القاعدة؟
  ///
  /// ★ البوابة تحمي من طلبٍ معلّق: إن كانت الحالة الجديدة
  ///   (`pharmacy_review`) لا يقرؤها أحد بعد، نبقى على `pending`
  ///   (سلوك ما قبل السكربت) حتى يُنصَّب. النجاح يُحفظ للجلسة كلها،
  ///   والفشل يُعاد فحصه بعد ٣٠ ثانية كي يلاحظ التطبيق التنصيب
  ///   بلا إعادة تشغيل.
  Future<bool> pharmacyGateReady() async {
    if (_pharmacyGateReady) return true;
    final failedAt = _pharmacyGateFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 30)) {
      return false;
    }
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/pharmacy_gate_ready'),
            headers: _headers,
            body: '{}',
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          jsonDecode(res.body) == true) {
        _pharmacyGateReady = true;
        return true;
      }
    } catch (_) {}
    _pharmacyGateFailedAt = DateTime.now();
    return false;
  }

  String? lastPharmacyReviewError;

  /// طلبات الوصفة المنتظرة لموافقة صاحب الصيدلية.
  /// `null` = تعذّر الجلب (الدالة غير منصّبة أو شبكة) ≠ `[]` لا يوجد.
  Future<List<Map<String, dynamic>>?> fetchPharmacyReviewOrders(
    String ownerPhone,
  ) async {
    lastPharmacyReviewError = null;
    if (ownerPhone.isEmpty) return null;
    try {
      return await rpcRows('pharmacy_review_orders', {
        'p_owner_phone': ownerPhone,
      });
    } on PostgrestFailure catch (e) {
      lastPharmacyReviewError = e.statusCode == 404
          ? 'غير مثبّت — شغّل SQL_PHARMACY_APPROVAL.sql'
          : 'تعذّر جلب الطلبات (${e.statusCode})';
      return null;
    } catch (_) {
      lastPharmacyReviewError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  /// موافقة الصيدلية: يحوّل الطلب إلى `pending` ويُشعر المندوبين.
  Future<Map<String, dynamic>?> approvePharmacyOrder(
    String orderId,
    String ownerPhone,
  ) => _pharmacyAction('pharmacy_approve_order', orderId, ownerPhone);

  /// رفض الصيدلية: يلغي الطلب ويكتب سبب الرفض ليصل للزبون.
  Future<Map<String, dynamic>?> rejectPharmacyOrder(
    String orderId,
    String ownerPhone,
    String reason,
  ) => _pharmacyAction(
    'pharmacy_reject_order',
    orderId,
    ownerPhone,
    reason: reason,
  );

  Future<Map<String, dynamic>?> _pharmacyAction(
    String fn,
    String orderId,
    String ownerPhone, {
    String reason = '',
  }) async {
    if (orderId.isEmpty || ownerPhone.isEmpty) return null;
    try {
      return await rpcOne(fn, {
        'p_order': orderId,
        'p_owner_phone': ownerPhone,
        if (fn == 'pharmacy_reject_order') 'p_reason': reason,
      });
    } catch (_) {
      return null;
    }
  }

  /// محفظة التاجر: الرصيد الحقيقي بعد قِص عمولة المنصة (10%).
  ///
  /// ★ المصدر `my_shop_wallet` في القاعدة — دفتر واحد للتاجر
  ///   وللأدمن، فلا يختلف رقمان على الشاشة نفسها.
  /// ★ `lastShopWalletError` يُملأ عند غياب الدالة، فنُظهر
  ///   رسالة «شغّل SQL» بدل صفر صامت: صفر كاذب أسوأ من لا شيء.
  String? lastShopWalletError;

  Future<Map<String, dynamic>?> fetchShopWallet(String ownerPhone) async {
    lastShopWalletError = null;
    if (ownerPhone.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/my_shop_wallet'),
            headers: _headers,
            body: jsonEncode({'p_owner_phone': ownerPhone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 404) {
        lastShopWalletError =
            'محفظة التاجر غير مثبَّتة — شغّل SQL_SHOP_WALLET.sql';
        return null;
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is Map && body.isNotEmpty)
          return Map<String, dynamic>.from(body);
        lastShopWalletError = 'رد غير متوقع من الخادم';
        return null;
      }
      lastShopWalletError = 'تعذّر جلب المحفظة (${res.statusCode})';
      return null;
    } catch (_) {
      lastShopWalletError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  /// احتياطي محلي (يعمل فقط قبل تشغيل `SQL_SHOP_BALANCE_15.sql`).
  ///
  /// ★ يستقطع [defaultCommissionRate] للمنصة ليطابق القاعدة. وإن تجاوزت
  ///   بنود الصيدلية الحدّ الأعلى للصفحة فالرقم قد يكون ناقصاً — ولهذا
  ///   المصدر الحقيقي هو الدالة، وهذا مجرد تعافٍ مؤقت.
  Future<Map<String, dynamic>> _localShopOwnerBalance(String ownerPhone) async {
    final empty = _emptyShopBalance();
    final shop = await fetchShopByOwnerPhone(ownerPhone);
    final name = shop?['name']?.toString() ?? '';
    if (name.isEmpty) return empty;
    try {
      final res = await _http.get(
        Uri.parse(
          '${_url}order_items?select=order_id,quantity,total&shop_name=eq.'
          '${Uri.encodeComponent(name)}&limit=5000',
        ),
        headers: _headers,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return empty;
      final rows = jsonDecode(res.body) as List;
      if (rows.isEmpty) return empty;

      var itemsSold = 0;
      final byOrder = <String, double>{};
      for (final r in rows) {
        final m = Map<String, dynamic>.from(r as Map);
        final oid = m['order_id']?.toString() ?? '';
        if (oid.isEmpty) continue;
        itemsSold += (m['quantity'] as num?)?.toInt() ?? 0;
        byOrder[oid] =
            (byOrder[oid] ?? 0) + ((m['total'] as num?)?.toDouble() ?? 0);
      }
      if (byOrder.isEmpty) return empty;

      final ids = byOrder.keys.join(',');
      final orders = await _fetchOrders('id=in.($ids)&limit=500');
      var gross = 0.0, pending = 0.0;
      var delivered = 0, rejected = 0;
      for (final o in orders) {
        final oid = o['id']?.toString() ?? '';
        final amount = byOrder[oid] ?? 0;
        final s = o['status']?.toString() ?? '';
        if (s == 'delivered') {
          gross += amount;
          delivered++;
        } else if (s == 'rejected' || s == 'cancelled') {
          rejected++;
        } else {
          pending += amount;
        }
      }
      // ★ 90% لصاحب الصيدلية بعد استقطاع عمولة المنصة 10%.
      final rate = SupabaseService.defaultCommissionRate;
      final commission = gross * rate / 100;
      final net = gross - commission;
      return {
        'balance': net,
        'net': net,
        'gross': gross,
        'commission': commission,
        'commission_rate': rate,
        'earned': net,
        'paid': 0.0,
        'pending': pending,
        'items_sold': itemsSold,
        'orders_count': byOrder.length,
        'delivered_orders': delivered,
        'settled_orders': delivered,
        'rejected_orders': rejected,
        'shop_name': name,
      };
    } catch (_) {
      return empty;
    }
  }

  /// ★ تصفير رصيد صيدلية — **الأدمن فقط** بكلمة مرور يتحقق منها الخادم.
  ///
  /// لا يحذف شيئاً: يسجّل «دفعة» بقيمة المستحق فيصبح الرصيد صفراً،
  /// ويبقى السجل كاملاً. الحذف كان سيمحو «كم دُفع سابقاً» بلا رجعة.
  Future<Map<String, dynamic>?> adminResetShopBalance(
    String ownerPhone,
    String adminPassword,
  ) async {
    if (ownerPhone.isEmpty || adminPassword.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_reset_shop_balance'),
            headers: _headers,
            body: jsonEncode({
              'p_owner_phone': ownerPhone,
              'p_admin_password': adminPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));
      // ★ تشخيص في logcat (`adb logcat -d -s flutter | grep ADMIN_HTTP`):
      //   جسم ردّ التصفير هو الحقيقة الوحيدة — ok وreset_amount وreset_at —
      //   لأن الدالة الحيّة قد تكون النسخة القديمة إن لم يُنفَّذ
      //   SQL_SHOP_WALLET_FULL_RESET.sql، والواجهة لا تُظهر الفرق.
      _logAdminHttp('adminResetShopBalance', res.statusCode, res.body);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = jsonDecode(res.body);
      if (body is Map) return Map<String, dynamic>.from(body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// إحصائيات قديمة (مكتملة/مرفوضة/ربح) لاسم صيدلية.
  Future<ShopOwnerStats> shopOwnerStats(String shopName) async {
    var fulfilled = 0, rejected = 0;
    var profit = 0.0;
    try {
      final orders = await fetchAllOrders();
      final allItems = await fetchAllOrderItems();
      final itemsByOrder = <String, List<Map<String, dynamic>>>{};
      for (final it in allItems) {
        final oid = it['order_id']?.toString() ?? '';
        if (oid.isEmpty) continue;
        itemsByOrder.putIfAbsent(oid, () => []).add(it);
      }
      for (final o in orders) {
        final oid = o['id']?.toString() ?? '';
        final mine = itemsByOrder[oid] ?? const [];
        final here = mine
            .where((it) => (it['shop_name']?.toString() ?? '') == shopName)
            .toList();
        if (here.isEmpty) continue;
        final status = o['status']?.toString() ?? '';
        if (status == 'accepted' ||
            status == 'delivering' ||
            status == 'delivered') {
          fulfilled++;
          if (status == 'delivered') {
            for (final m in here) {
              profit += (m['total'] is num
                  ? (m['total'] as num).toDouble()
                  : double.tryParse(m['total']?.toString() ?? '') ?? 0);
            }
          }
        } else if (status == 'rejected' || status == 'cancelled') {
          rejected++;
        }
      }
    } catch (_) {}
    return ShopOwnerStats(
      fulfilledOrders: fulfilled,
      rejectedOrders: rejected,
      profit: profit,
    );
  }

  // ==========================================================
  //  البانرات
  // ==========================================================

  Future<List<Map<String, dynamic>>> fetchBanners() async {
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}banners?select=id,title,subtitle,badge,color_hex,'
              'speed_seconds,sort_order,image_url,image_path,shop_id,'
              'target_url,link_url,is_global,is_active&order=sort_order.asc',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return List<Map<String, dynamic>>.from(jsonDecode(res.body));
      }
    } catch (_) {}
    return [];
  }

  Future<bool> addBanner({
    required String title,
    String? subtitle,
    String? badge,
    int speedSeconds = 4,
    int sortOrder = 0,
    String? imagePath,
    String? imageUrl,
    String? targetUrl,
    String? shopId,
    String? colorHex,
  }) async {
    lastAdminError = '';
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}banners'),
            headers: _headers,
            body: jsonEncode({
              'title': title,
              'subtitle': subtitle,
              'badge': badge,
              // ★ لون البانر: يُخزَّن كـ`#RRGGBB` ويولّد منه العميل كل التدرّجات،
              //   فيختلف لون كل بانر بنفس البنية البصرية.
              'color_hex': (colorHex == null || colorHex.trim().isEmpty)
                  ? null
                  : colorHex.trim(),
              'speed_seconds': speedSeconds,
              'sort_order': sortOrder,
              'image_path': imagePath,
              'image_url': imageUrl,
              'target_url': (targetUrl == null || targetUrl.trim().isEmpty)
                  ? null
                  : targetUrl.trim(),
              // ★ وجهة الصيدلية/الكوزمتك: معرّف المحل في `shops`، ويُفتح
              //   صفحته عند النقر على البانر.
              'shop_id': (shopId == null || shopId.trim().isEmpty)
                  ? null
                  : shopId.trim(),
              'is_active': true,
            }),
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('addBanner', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  Future<bool> updateBanner(
    String bannerId,
    Map<String, dynamic> values,
  ) async {
    lastAdminError = '';
    if (bannerId.isEmpty || values.isEmpty) {
      lastAdminError = 'طلب تحديث ناقص';
      return false;
    }
    try {
      final res = await _http
          .patch(
            Uri.parse('${_url}banners?id=eq.$bannerId'),
            headers: _headers,
            body: jsonEncode(values),
          )
          .timeout(const Duration(seconds: 12));
      _logAdminHttp('updateBanner id=$bannerId', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        // مع return=representation: `[]` = لم يتغيّر أي صف (RLS/فلتر).
        try {
          final updated = jsonDecode(res.body);
          if (updated is List && updated.isNotEmpty) return true;
          lastAdminError = 'لم يتغيّر أي صف — راجع سياسات الأمان';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  Future<bool> deleteBanner(String bannerId) async {
    lastAdminError = '';
    if (bannerId.isEmpty) {
      lastAdminError = 'معرّف البانر فارغ';
      return false;
    }
    try {
      final res = await _http
          .delete(
            Uri.parse('${_url}banners?id=eq.$bannerId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      // ★ حذف مباشر (لا RPC). الطلب يحمل `Prefer: return=representation`
      //   فيُعيد PostgREST مصفوفة الصفوف المحذوفة فعلاً: `[]` تعني أن
      //   RLS أو الفلتر منع الحذف رغم كود 200 ⇒ نفشل ولا نكذب.
      _logAdminHttp('deleteBanner id=$bannerId', res.statusCode, res.body);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        try {
          final deleted = jsonDecode(res.body);
          if (deleted is List && deleted.isNotEmpty) return true;
          lastAdminError =
              'منع الحذف سياسة الأمان (RLS) — شغّل SQL إصلاح البانرات';
        } catch (_) {
          lastAdminError = 'رد غير متوقع من الخادم';
        }
        return false;
      }
      _captureAdminError(res.statusCode, res.body);
      return false;
    } catch (e) {
      lastAdminError = e.toString();
      return false;
    }
  }

  // ==========================================================
  //  الإشعارات
  // ==========================================================

  /// إرسال شعار عام للجميع عبر دالة `notify_broadcast` في Supabase.
  ///
  /// عنوان خدمة البثّ على السيرفر (تعمل 24/7، فيصل الإشعار والتطبيق مغلق).
  ///
  /// المسار: `http://<vps>/push` ← nginx ← `push-api` على 127.0.0.1:3001.
  static const String pushBroadcastBase = 'http://162.35.126.155/push';

  /// سر البثّ. موجود داخل الحزمة (يستطيع أي شخص تفكيك APK وقراءته)،
  /// فالبثّ يُعتبر تحكماً إدارياً لا سراً سرياً. للربط الحقيقي انقل
  /// الطلب إلى Supabase Edge Function بدل وضع السر في التطبيق.
  static const String pushBroadcastSecret =
      'cJB6uV6ahCZc4pCj7EKgeXABLEMnVHQWmUxtqW2wcZXWm6M5';

  /// لا يخزّن التطبيق شيئاً: الدالة تتكفّل بكل شيء. إن لم تكن الدالة
  /// موجودة نرجع[row لكل حساب] مؤقت يُحذف فور عرضه (خطّ أمان).
  Future<({bool ok, int targets, int pushed, String? error})> sendBroadcast({
    required String title,
    required String body,
    String? link,
  }) async {
    lastNotificationError = null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/notify_broadcast'),
            headers: _headers,
            body: jsonEncode({
              'p_title': title,
              'p_body': body,
              'p_link': (link == null || link.trim().isEmpty)
                  ? null
                  : link.trim(),
            }),
          )
          .timeout(const Duration(seconds: 20));
      // ★ نبضة فورية بعد كتابة الشعار: بدونه ينتظر الخادم دورته التالية
      //   (حتى ٣٠ ثانية عند السكون) فيصل الشعار متأخراً عن بقية الأحداث.
      //   النبضة تجعله يفحص ويُرسل خلال أقل من ثانية. لا تُنتظر النتيجة
      //   ولا تؤثر على نجاح البثّ.
      unawaited(pokeNotifyServer('broadcast'));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is List && decoded.isNotEmpty) {
          final row = Map<String, dynamic>.from(decoded.first as Map);
          return (
            ok: true,
            targets: (row['targets'] as num?)?.toInt() ?? 0,
            pushed: (row['pushed'] as num?)?.toInt() ?? 0,
            error: null,
          );
        }
        if (decoded is Map) {
          return (
            ok: true,
            targets: (decoded['targets'] as num?)?.toInt() ?? 0,
            pushed: (decoded['pushed'] as num?)?.toInt() ?? 0,
            error: null,
          );
        }
      }
      lastNotificationError = 'HTTP ${res.statusCode}';
    } catch (e) {
      lastNotificationError = e.toString();
    }

    // ── البثّ من السيرفر: هذا ما يوصل والتطبيق مقفول ──
    // دالة notify_broadcast غير موجودة في القاعدة، فنرسل مباشرةً لخدمة
    // البثّ على السيرفر. إن نجحت ⇒ وصل everybody.
    if (pushBroadcastSecret !=
        'cJB6uV6ahCZc4pCj7EKgeXABLEMnVHQWmUxtqW2wcZXWm6M5') {
      try {
        final r = await http
            .post(
              Uri.parse(
                '$pushBroadcastBase/broadcast?secret=$pushBroadcastSecret',
              ),
              headers: const {
                'Content-Type': 'application/json; charset=utf-8',
              },
              body: jsonEncode({
                'title': title,
                'body': body,
                'link': (link == null || link.trim().isEmpty)
                    ? null
                    : link.trim(),
              }),
            )
            .timeout(const Duration(seconds: 45));
        if (r.statusCode >= 200 && r.statusCode < 300) {
          final j = jsonDecode(utf8.decode(r.bodyBytes));
          if (j is Map && j['ok'] == true) {
            return (
              ok: true,
              targets: (j['targets'] as num?)?.toInt() ?? 0,
              pushed: (j['sent'] as num?)?.toInt() ?? 0,
              error: null,
            );
          }
        }
        lastNotificationError = 'push ${r.statusCode}';
      } catch (e) {
        lastNotificationError = e.toString();
      }
    }

    // خطّ أمان: صف مؤقت لكل حساب (يُحذف فور العرض).
    final users = await fetchUsers();
    final active = users.where((u) => u['is_active'] != false).toList();
    var ok = 0;
    for (final u in active) {
      final phone = u['phone']?.toString().trim() ?? '';
      if (phone.isEmpty) continue;
      final sent = await addNotification(
        userPhone: phone,
        title: title,
        body: body,
        linkUrl: link,
        type: 'broadcast',
      );
      if (sent) ok++;
    }
    return (ok: ok > 0, targets: ok, pushed: 0, error: lastNotificationError);
  }

  /// إشعار لرقم واحد، أو إشعار عام للجميع.
  ///
  /// [sound] نغمة التنبيه: `new_order` / `accepted` / `rejected` /
  /// `replaced` / `delivered` / `alert`.
  /// [type] اسم الحدث (يُستعمل في الإحصاءات وربط الإشعار بالطلب).
  ///
  /// إن لم تُشغَّل سكربت الإشعارات بعد (الأعمدة الجديدة ناقصة) نتراجع
  /// للإرسال بدونها بدل أن يفشل الإشعار كله.
  Future<bool> addNotification({
    required String userPhone,
    required String title,
    required String body,
    String? linkUrl,
    bool isGlobal = false,
    bool isRead = false,
    String? sound,
    String? type,
    String? orderId,
    String? serial,
    String? imageUrl,
    String? brandTitle,
  }) async {
    lastNotificationError = null;
    if (!isGlobal && userPhone.isEmpty) {
      lastNotificationError = 'رقم الهاتف فارغ — لا يمكن الإرسال';
      return false;
    }
    final link = (linkUrl == null || linkUrl.trim().isEmpty)
        ? null
        : linkUrl.trim();
    final oid = (orderId == null || orderId.trim().isEmpty)
        ? null
        : orderId.trim();
    final ser = (serial == null || serial.trim().isEmpty)
        ? null
        : serial.trim();
    // ★ شعار المستقبِل نفسه: لكل زبون شعاره (صورة حسابه/صيدليته).
    final img = (imageUrl == null || imageUrl.trim().isEmpty)
        ? null
        : imageUrl.trim();
    final bTitle = (brandTitle == null || brandTitle.trim().isEmpty)
        ? null
        : brandTitle.trim();
    final full = <String, dynamic>{
      'user_phone': isGlobal ? '*' : userPhone,
      'title': title,
      'body': body,
      'is_read': isRead,
      'is_global': isGlobal,
      'link_url': link,
      'type': (type == null || type.isEmpty) ? null : type,
      'sound': (sound == null || sound.isEmpty) ? null : sound,
      'order_id': oid,
      'serial': ser,
      'image_url': img,
      'brand_title': bTitle,
    };
    final lean = Map<String, dynamic>.from(full)
      ..remove('serial')
      ..remove('order_id')
      ..remove('type')
      ..remove('sound')
      ..remove('brand_title');
    final base = <String, dynamic>{
      'user_phone': isGlobal ? '*' : userPhone,
      'title': title,
      'body': body,
      'is_read': isRead,
      'is_global': isGlobal,
      'link_url': link,
      'image_url': img,
    };

    try {
      http.Response? res;
      for (final payload in [full, lean, base]) {
        res = await http
            .post(
              Uri.parse('${_url}notifications'),
              headers: _headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 15));
        if (res.statusCode >= 200 && res.statusCode < 300) return true;
        // الإشعار موجود مسبقاً (dedupe_key) = محسوب لا مفقود.
        if (res.statusCode == 409 || res.statusCode == 422) return true;
      }
      lastNotificationError =
          'السيرفر رفض الإرسال (${res?.statusCode ?? 0}): ${res?.body ?? ''}';
      return false;
    } catch (e) {
      lastNotificationError = 'فشل الاتصال بالسيرفر: $e';
      return false;
    }
  }

  /// هل لهذا الحساب توكن جهاز مسجَّل في Firebase؟
  ///
  /// إن كان موجوداً ⇒ الإشعار في الخلفية يوصل عبر FCM من السيرفر
  /// (حتى والتطبيق مقفل)، فلا نكرّره كإشعار نظام محلي.
  Future<bool> hasFcmToken(String phone) async {
    if (phone.isEmpty) return false;
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}users?select=fcm_token&phone=eq.$phone&limit=1'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final list = jsonDecode(res.body) as List;
        if (list.isEmpty) return false;
        final t = (list.first as Map)['fcm_token']?.toString().trim() ?? '';
        return t.isNotEmpty && t != 'null';
      }
    } catch (_) {}
    return false;
  }

  /// أرقام كل حسابات المندوبين النشِطين (لإشعارهم بالطلبات الجديدة).
  Future<List<String>> fetchDriverPhones() async {
    try {
      final res = await _http
          .get(
            Uri.parse(
              '${_url}users?select=phone&is_driver=eq.true&is_active=eq.true&limit=500',
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return (jsonDecode(res.body) as List)
            .map((r) => (r as Map)['phone']?.toString().trim() ?? '')
            .where((p) => p.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  /// إشعار كل المندوبين بطلب جديد.
  ///
  /// ★ الطريق المعتمد: دالة `notify_drivers_of_new_order` تكتب الصفوف
  ///   **داخل قاعدة البيانات**. التطبيق يمرّر مُعرّف الطلب فقط، والخادم
  ///   هو من يقصّ رقم الطلب ويختار المندوبين — فلا نحتاج قراءة `users`
  ///   ولا INSERT مباشراً (كلاهما ممنوع بعد قفل الجدول بـ RLS، وهو
  ///   سبب أن المندوب لم يكن يتلقّى إشعاراً إطلاقاً).
  ///
  /// [serial] و[isDriverRequest] للبديل القديم فقط، وتبقى تواقيع
  /// الاستدعاء كما هي فلا يتأثر أي مستدعٍ.
  ///
  /// ★ لا ترمي استثناءً أبداً: تُستدعى من داخل `createOrder`، ورمي
  ///   استثناء هنا كان سيُبطل طلباً نجح فعلاً.
  Future<void> notifyDriversOfNewOrder(
    Map<String, dynamic> order, {
    required String serial,
    bool isDriverRequest = false,
  }) async {
    try {
      final orderId = order['id']?.toString().trim() ?? '';
      if (orderId.isEmpty) return;
      final type = isDriverRequest ? 'driver_request' : 'new_order';
      // ★ النبضة أولاً: الصفوف تُكتب الآن، فلا ننتظر دورة الاستطلاع
      //   لتُنبّه الخادم أن هناك طلباً جديداً.
      unawaited(pokeNotifyServer(type));

      if (await _notifyDriversViaServer(orderId: orderId, type: type)) return;

      // دالة الخادم غير موجودة بعد (٤٠٤) ⇒ نبثّ من الجهاز كما كان.
      await _notifyDriversFromDevice(order, serial: serial, type: type);
    } catch (e) {
      lastNotificationError = 'notify drivers: $e';
    }
  }

  /// ★★ نبضة لسيرفر الإشعارات: «تغيّر شيء — افحص الآن ولا تنتظر دورتك».
  ///
  ///   السيرفر يستطلع القاعدة كل ثانيتين (وأسرع بعد نبضة)، فبلا هذه
  ///   النبضة يبقى أسوأ حال للطلب الجديد ثانيتين + زمن الدورة. معها
  ///   يبدأ الإرسال فوراً: أقل من ثانية من ضغط «إرسال الطلب».
  ///
  ///   الفشل لا يُلتفت إليه: الاستطلاع وحده يلتقط
  ///   التغيير في دورته التالية، فالنبضة تسريعٌ لا الاعتماد عليها.
  ///   (المضيف والمفتاح هما بالضبط ما يعمل بهما بثّ SSE في
  ///   `RealtimeService.host` / `Secrets.realtimeApiKey`.)
  Future<void> pokeNotifyServer(String why) async {
    try {
      await _http
          .post(
            Uri.parse(
              'http://162.35.126.155/api/poke'
              '?why=${Uri.encodeQueryComponent(why)}',
            ),
            headers: <String, String>{
              'x-api-key': Secrets.realtimeApiKey,
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      // صمتٌ مقصود: لا نُنقص نجاح الطلب لأن سيرفر الإشعارات بعيد.
    }
  }

  /// ★ استدعاء دالة الخادم — ترجع `true` فقط إن كتبت الصفوف بنجاح.
  Future<bool> _notifyDriversViaServer({
    required String orderId,
    required String type,
  }) async {
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/notify_drivers_of_new_order'),
            headers: _headers,
            body: jsonEncode({
              'p_order_id': orderId,
              'p_type': type,
              'p_sound': NotifySound.newOrder.key,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['ok'] == true) return true;
        // رفض من الدالة نفسها (جلسة غير صالحة مثلاً) ⇒ لا نكرّر الخطأ.
        if (decoded is Map && decoded['error'] != null) {
          lastNotificationError = decoded['error'].toString();
          return false;
        }
        return true;
      }
      lastNotificationError = 'notify_drivers_of_new_order → ${res.statusCode}';
      return false;
    } catch (e) {
      lastNotificationError = 'notify_drivers_of_new_order: $e';
      return false;
    }
  }

  /// ★ البديل القديم: البثّ من الجهاز (نقرأ الأرقام ونكتب لكل واحد).
  ///
  /// يعمل فقط على قواعد بيانات لم تُشغَّل فيها
  /// `SQL_NOTIFY_DRIVERS_NEW_ORDER.sql`، وبعد تشغيلها يُهمَل.
  Future<void> _notifyDriversFromDevice(
    Map<String, dynamic> order, {
    required String serial,
    required String type,
  }) async {
    final owner = order['user_phone']?.toString().trim() ?? '';
    final drivers = (await fetchDriverPhones()).toSet().toList()
      // لا نُشعر صاحب الطلب نفسه إن كان مندوباً أيضاً.
      ..remove(owner);
    if (drivers.isEmpty) return;
    final label = serial.isEmpty ? '' : ' رقم $serial';
    // ★ النص المطلوب: «لديك طلب مندوب» (بلا «جديد») حين يكون طلب
    //   مندوب حر. العنوان قصير ليظهر كاملاً في شريط الإشعارات،
    //   والتفاصيل (الرقم + الدعوة للاستلام) في النص.
    final title = type == 'driver_request' ? 'لديك طلب مندوب' : 'لديك طلب جديد';
    final body = type == 'driver_request'
        ? 'طلب مندوب$label — اضغط للاستلام الآن'
        : 'لديك طلب جديد$label — اضغط للاستلام الآن';
    // إرسال متوازٍ حتى لا يتأخر الطلب الجديد أمام المندوبين.
    await Future.wait(
      drivers.map(
        (phone) => addNotification(
          userPhone: phone,
          title: title,
          body: body,
          type: type,
          sound: NotifySound.newOrder.key,
          orderId: order['id']?.toString(),
          serial: serial,
        ),
      ),
    );
  }

  /// ★ إشعارات هذا الرقم فقط — عبر دالة محمية على الخادم.
  ///
  /// كان الاستعلام `or=(user_phone.eq.X, is_global.eq.true)` يُنفَّذ
  /// بدور `anon` الذي يقرأ الجدول كاملاً ⇒ أي شخص يقدر يقرأ إشعارات
  /// غيره، والفلتر كان في جهازه فقط. الآن الخادم يتحقّق من صاحب الصف
  /// والجدول مقفل بـ RLS (الملف `SQL_READY_COPY.sql`).
  ///
  /// ★★ إصلاح «خلل التكرار» (2026-11-08، بلا تغيير DB/سيرفر/تأخير/فقد):
  ///   مصدران في نفس الـ isolate (NotificationCenter + background_poller)
  ///   قد يطلبان الإشعارات في اللحظة نفسها ⇒ طلبان متماثلان. ندمج
  ///   الطلبات **المتزامنة قيد التنفيذ** لنفس الهاتف في Future واحد فقط،
  ///   ثم نزيله فور اكتماله. لا نخزّن النتيجة زمنياً حتى لا نؤخر أي
  ///   إشعار جديد.
  final Map<String, Future<List<Map<String, dynamic>>>> _inFlightNotifications =
      <String, Future<List<Map<String, dynamic>>>>{};

  Future<List<Map<String, dynamic>>> fetchNotifications(String userPhone) {
    if (userPhone.isEmpty) return Future.value(const <Map<String, dynamic>>[]);
    final inflight = _inFlightNotifications[userPhone];
    if (inflight != null) return inflight;
    final future = _fetchNotificationsImpl(userPhone);
    _inFlightNotifications[userPhone] = future;
    return future.whenComplete(() {
      if (identical(_inFlightNotifications[userPhone], future)) {
        _inFlightNotifications.remove(userPhone);
      }
    });
  }

  Future<List<Map<String, dynamic>>> _fetchNotificationsImpl(
    String userPhone,
  ) async {
    ApiMetrics.hit('get_my_notifications');
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_my_notifications'),
            headers: _headers,
            body: jsonEncode({'p_phone': userPhone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is! List) return const [];
        return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
      }
    } catch (_) {}
    return [];
  }

  /// إشعار واحد بمعرّفه — **مع التأكد أنه لهذا الرقم** (لا تسريب).
  ///
  /// ★★ دمج الطلبات المتزامنة قيد التنفيذ لنفس (id, phone) فقط — إصلاح
  ///   تكرار آمن، بلا تخزين زمني كي لا نخفي تغيّر pushed_at/is_read.
  final Map<String, Future<Map<String, dynamic>?>> _inFlightNotificationById =
      <String, Future<Map<String, dynamic>?>>{};

  Future<Map<String, dynamic>?> notificationById(String id, String? phone) {
    if (id.isEmpty || phone == null || phone.isEmpty) return Future.value(null);
    final key = '$id|$phone';
    final inflight = _inFlightNotificationById[key];
    if (inflight != null) return inflight;
    final future = _notificationByIdImpl(id, phone);
    _inFlightNotificationById[key] = future;
    return future.whenComplete(() {
      if (identical(_inFlightNotificationById[key], future)) {
        _inFlightNotificationById.remove(key);
      }
    });
  }

  Future<Map<String, dynamic>?> _notificationByIdImpl(
    String id,
    String phone,
  ) async {
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_my_notification'),
            headers: _headers,
            body: jsonEncode({'p_id': id, 'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded.isNotEmpty) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// استبدال قسيمة التوصيل المجاني — الخصم **على الخادم**.
  ///
  /// لا يكتب التطبيق أي شيء محلياً: الخادم يسجّل الاستبدال في
  /// `reward_redemptions` **مع التاريخ والساعة ورقم الطلب**، ويعيد حساب
  /// الرصيد. هذا يمنع أي جهاز من تصفير رصيده بنفسه.
  ///
  /// يُرجع خريطة فيها `date` و`time` (بتوقيت بغداد) إن نجحت.
  Future<Map<String, dynamic>?> redeemFreeDeliveryOnServer(
    String phone, {
    String? orderId,
    String? orderNumber,
  }) async {
    if (phone.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/redeem_free_delivery'),
            headers: _headers,
            body: jsonEncode({
              'p_phone': phone,
              'p_code': '',
              'p_order_id': orderId,
              'p_order_number': orderNumber,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = jsonDecode(res.body);
      if (body is! Map) return null;
      final map = Map<String, dynamic>.from(body);
      return map['ok'] == true ? map : null;
    } catch (_) {
      return null;
    }
  }

  /// ★ سجل استخدام التوصيل المجاني لهذا الرقم (التاريخ + الساعة).
  Future<List<Map<String, dynamic>>> fetchFreeDeliveryLog(String? phone) async {
    if (phone == null || phone.isEmpty) return const [];
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_free_delivery_log'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return const [];
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const [];
      return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
    } catch (_) {
      return const [];
    }
  }

  /// ★ كل عمليات استخدام التوصيل المجاني (للأدمن).
  Future<List<Map<String, dynamic>>> fetchAllFreeDeliveryLog({
    int limit = 100,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_all_free_delivery_log'),
            headers: _headers,
            body: jsonEncode({'p_limit': limit}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return const [];
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const [];
      return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
    } catch (_) {
      return const [];
    }
  }

  /// ★ تصفير نقاط مستخدم — **الأدمن فقط**، ويتطلب كلمة مرور.
  ///
  /// الخادم يتحقق من كلمة المرور (مخزّنة مُجزّأة في جدول لا يقرأه anon).
  /// لا يوجد أي مسار آخر للتصفير.
  Future<Map<String, dynamic>?> adminResetPoints(
    String phone,
    String adminPassword,
  ) async {
    if (phone.isEmpty || adminPassword.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/admin_reset_points'),
            headers: _headers,
            body: jsonEncode({
              'p_phone': phone,
              'p_admin_password': adminPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = jsonDecode(res.body);
      if (body is Map) return Map<String, dynamic>.from(body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// ★ ملخّص النقاط من الخادم — **مصدر الحقيقة الوحيد**.
  ///
  /// التطبيق يقرأه عند كل دخول، فتُحفظ النقاط محسوبةً من الطلبات
  /// المسلَّمة فعلاً، ولا تتأثر بإعادة تثبيت التطبيق أو تبديل الحساب.
  Future<Map<String, dynamic>?> fetchRewardsSummary(String? phone) async {
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_rewards_summary'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone ?? ''}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// ★ نقطة الترحيب — يقرّر الخادم. ترجع true مرة واحدة فقط لكل حساب.
  Future<bool> grantWelcomePointsServer(String phone) async {
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/grant_welcome_points'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      return (jsonDecode(res.body) as bool?) == true;
    } catch (_) {
      return false;
    }
  }

  /// تسجيل نقطة الترحيب على السيرفر (مرة واحدة لكل مستخدم **نهائياً**).
  ///
  /// يستدعي `award_reward_record('welcome:<phone>', phone)` الذي يفرض
  /// فهرساً فريداً على `order_id`، فلا تُمنح نقطة ترحيب ثانية أبداً:
  /// لا بعد حذف التطبيق، ولا بتبديل الحساب، ولا من جهاز آخر.
  Future<RewardRecordStatus> recordWelcomePoints(
    String? phone,
    int amount,
  ) async {
    if (phone == null || phone.isEmpty || amount <= 0) {
      return RewardRecordStatus.failed;
    }
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/award_reward_record'),
            headers: _headers,
            body: jsonEncode({
              'p_order_id': 'welcome:$phone',
              'p_phone': phone,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final out =
            (jsonDecode(res.body) as String?)?.trim().toLowerCase() ?? '';
        if (out == 'awarded') return RewardRecordStatus.awarded;
        if (out == 'already') return RewardRecordStatus.already;
        return RewardRecordStatus.failed;
      }
      return RewardRecordStatus.failed;
    } catch (_) {
      return RewardRecordStatus.failed;
    }
  }

  /// إعدادات عامة من جدول `app_settings` (يضبطها الأدمن بلا تحديث التطبيق).
  ///
  /// المفاتيح المدعومة:
  ///   welcome_enabled  → هل تظهر ملاحظة الترحيب
  ///   welcome_text     → نص الملاحظة
  ///   welcome_points   → نقاط الترحيب لكل مستخدم جديد
  ///   points_per_order → نقاط كل طلب
  ///   target_points    → النقاط المطلوبة لتفعيل التوصيل المجاني
  ///   update_enabled   → إطفاء/تشغيل رسالة تحديث التطبيق
  ///   update_latest_version → رقم أحدث إصدار منشور (مثل 1.7.63)
  ///   update_message   → نص مخصص للرسالة (فارغ = النص الافتراضي)
  Future<Map<String, dynamic>?> fetchAppConfig() async {
    try {
      final res = await _http
          .get(
            Uri.parse('${_url}app_settings?select=key,value'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final rows = jsonDecode(res.body) as List;
      final map = <String, dynamic>{};
      for (final r in rows) {
        final key = (r as Map)['key']?.toString() ?? '';
        final value = r['value']?.toString() ?? '';
        if (key.isEmpty) continue;
        switch (key) {
          case 'welcome_enabled':
            map['welcome_enabled'] = value == '1' || value == 'true';
          case 'welcome_text':
            map['welcome_text'] = value;
          case 'update_enabled':
            map['update_enabled'] = value == '1' || value == 'true';
          case 'update_latest_version':
            map['update_latest_version'] = value.trim();
          case 'update_message':
            map['update_message'] = value;
        }
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  /// تحديث قيمة في `app_settings` (يستعمله الأدمن من لوحة التحكم).
  Future<bool> setAppSetting(String key, String value) async {
    if (key.isEmpty) return false;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}app_settings?on_conflict=key'),
            headers: {
              ..._headers,
              'Prefer': 'resolution=merge-duplicates,return=representation',
            },
            body: jsonEncode({'key': key, 'value': value}),
          )
          .timeout(const Duration(seconds: 12));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// حذف كل إشعارات طلب معيّن (مثلاً بعد تأكيد استلام النقاط).
  ///
  /// ★ مقصور على [userPhone]: كان الحذف بلا مُرشِّح فيمحو إشعارات
  ///   الطلب من حسابات كل المستخدمين.
  Future<int> deleteNotificationsForOrder(
    String orderId,
    String userPhone,
  ) async {
    if (orderId.isEmpty || userPhone.isEmpty) return 0;
    try {
      final q = Uri.encodeComponent(userPhone);
      await _http.delete(
        Uri.parse('${_url}notifications?order_id=eq.$orderId&user_phone=eq.$q'),
        headers: _headers,
      );
      return 1;
    } catch (_) {
      return 0;
    }
  }

  Future<int> unreadNotificationsCount(String userPhone) async {
    if (userPhone.isEmpty) return 0;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/count_my_notifications'),
            headers: _headers,
            body: jsonEncode({'p_phone': userPhone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final v = jsonDecode(res.body);
        if (v is num) return v.toInt();
      }
    } catch (_) {}
    return 0;
  }

  /// حذف الإشعار — **صف صاحب الرقم فقط**.
  ///
  /// كان الحذف `id=eq.X` بلا تحقق من الرقم ⇒ أي جهاز يقدر يحذف
  /// إشعار غيره. الآن الخادم يشترط مطابقة `user_phone`.
  Future<bool> deleteNotification(String notificationId, String? phone) async {
    if (notificationId.isEmpty || phone == null || phone.isEmpty) {
      return false;
    }
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/delete_my_notification'),
            headers: _headers,
            body: jsonEncode({'p_id': notificationId, 'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// حذف كل الإشعارات القديمة **الخاصة بالمستخدم**.
  ///
  /// ★ كان المُرشِّح يشمل `user_phone.eq.*`، فحساب واحد ينظّف
  ///   إشعارات البث العام لكل المستخدمين عند ضغطة واحدة.
  Future<void> purgeReadNotifications(String userPhone) async {
    if (userPhone.isEmpty) return;
    try {
      final q = Uri.encodeComponent(userPhone);
      await _http.delete(
        Uri.parse('${_url}notifications?is_read=eq.true&user_phone=eq.$q'),
        headers: _headers,
      );
    } catch (_) {}
  }

  /// إشعار داخلي عام عند أي تحديث.
  Future<void> broadcastUpdate({
    required String title,
    required String body,
    String? status,
    String? orderId,
    String? sound,
  }) async {
    await StatusCenter.instance.broadcast(
      title: title,
      body: body,
      status: status,
      orderId: orderId,
      sound: sound,
    );
  }

  // ==========================================================
  //  أكواد التوصيل المجاني (لا نقاط)
  // ==========================================================

  /// تسجيل طلب مُسلَّم — يُصدر كوداً عند بلوغ كل 5.
  Future<Map<String, dynamic>?> recordOrderCompletion(
    String orderId,
    String phone,
  ) async {
    if (orderId.isEmpty || phone.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/record_order_completion'),
            headers: _headers,
            body: jsonEncode({'p_order_id': orderId, 'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// سبب تعذّر المحفظة، `null` = ما زال يُحمَّل. النصّ مختلف = عطل
  /// حقيقي. بدون هذا التمييز بقي «جارِ فتح المحفظة» إلى الأبد عند
  /// الدالة غير المثبّتة: PostgREST يردّ 404 و`PGRST202`، وهو غير
  /// مثبّت لا انقطاع شبكة.
  String? lastDriverWalletError;

  /// ★ ملخّص أكواد الخصم لكل مندوب — للأدمن فقط.
  ///
  /// ★ الكود يُقرأ من دفتر المحفظة نفسه، فالأرقام التي يراها الأدمن
  ///   هي نفس ما يراه المندوب في محفظته — لا مصدران للحقيقة.
  ///
  /// ★ [credential] يُمرَّر **كما هي عليه الحال في اللوحة**: تذكرة الجلسة
  ///   إن وُجدت (وهي 64 محرفاً ستاتياً بلا أي رمز خاص)، وإلا كلمة الفتح.
  ///   التذكرة هي المطلوب الآن لأن `require_admin_password` في القاعدة
  ///   صار يقبلها قبل الكلمة — فلا يُرسَل سرّ على الشبكة بلا داعٍ.
  Future<Map<String, dynamic>?> fetchDriverCouponSummary(
    String credential,
  ) async {
    lastAdminCouponError = null;
    final cred = credential.trim();
    if (cred.isEmpty) {
      // ★ كانت تُرسل سلسلة فارغة فيردّ الخادم 403 بـ«كلمة مرور الأدمن
      //   مطلوبة» فتُعرض كنصّ خام. الفارغ خطأ جهاز، لا خطأ خادم.
      lastAdminCouponError = 'أدخل كلمة فتح اللوحة أولاً.';
      return null;
    }
    try {
      var res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_driver_coupon_summary'),
            headers: _headers,
            body: jsonEncode({'p_admin_password': cred}),
          )
          .timeout(const Duration(seconds: 15));

      // ★ 405 = الرفض للطريقة لا للمحتوى. الدالة `stable` (قارئة)، فـGET
      //   بها هو المسار المشروع نفسه الذي يعمل في `fetchOrderStatsRange`.
      //   لا إعادة محاولة على أي رمز آخر — كي لا تتحوّل كلمة المرور
      //   إلى نصّ استعلام إلا عند الضررة القصوى.
      res = await _rpcGetRetry(
        'admin_driver_coupon_summary',
        {'p_admin_password': cred},
        res,
        15,
      );

      // ★ كان `return null` صامتاً هنا ⇒ **لا بيانات ولا رسالة**، أي
      //   «الزر لا يعمل» بلا سبب. الآن كل رد غير ناجح له سبب مُعلن:
      //   404/PGRST202 = الدالة غير مثبّتة (ينقص SQL)، 401/403 = رفض،
      //   5xx = خطأ خادم. بدون هذا لا يمكن تشخيص العطل ولا إصلاحه.
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final body = utf8.decode(res.bodyBytes);
        final missing = res.statusCode == 404 && body.contains('PGRST202');
        if (missing) {
          lastAdminCouponError =
              'الدالة غير مثبّتة — شغّل SQL_ADMIN_DRIVER_COUPONS.sql';
        } else if (res.statusCode == 403) {
          // ★ 403 من القاعدة لها، لا من الشبكة: `require_admin_password`
          //   ترمي 28000 برسالتها العربية الخاصة («كلمة المرور خاطئة» أو
          //   «كلمة مرور الأدمن مطلوبة»). تلك رسالة للمستخدم أصلاً،
          //   فتُعرض كما هي بدل dump خام للـJSON.
          final why = _restUserMessage(body);
          lastAdminCouponError = AdminPasswordSession.isTicket(cred)
              ? 'انتهت جلسة اللوحة على هذا الجهاز — أعِد إدخال كلمة الفتح.'
              : (why.isEmpty ? 'رفض الخادم كلمة الفتح.' : why);
        } else if (res.statusCode == 405) {
          // ★ 405 بعد محاولة GET أيضاً = الطبقة الأمامية (وليست المنطق)
          //   هي التي رُفِض عندها المسار. أشيع سببٍ عملياً هو ما تحمله
          //   كلمة المرور من رموز خاصة في جسم الطلب؛ التذكرة ستاتية
          //   المحرّف فتزول هذه الحالة من جذورها.
          lastAdminCouponError =
              'رفض الخادم طريقة الطلب (405). '
              'أعد فتح اللوحة من جديد لتتجدّد الجلسة ثم اضغط «تحديث».'
              '${_shortBody(body)}';
        } else {
          final why = _restUserMessage(body);
          lastAdminCouponError =
              'تعذّر جلب الملخّص (HTTP ${res.statusCode}): '
              '${why.isEmpty ? _shortBody(body) : why}';
        }
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        lastAdminCouponError = 'رد غير متوقع من الخادم';
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        lastAdminCouponError = '${map['error'] ?? 'تعذّر جلب الملخّص'}';
        return null;
      }
      lastAdminCouponError = null;
      return map;
    } catch (e) {
      lastAdminCouponError = 'تعذّر الاتصال بالخادم: $e';
      return null;
    }
  }

  /// ★ رسالة الخادم المفهومة من جسم خطأ PostgREST، أو نص فارغ.
  ///
  /// الأخطاء تعود دائماً بالشكل `{"code":"28000","message":"..."}`،
  /// ورسائل دوال الأدمن مكتوبة بالعربي للمستخدم أصلاً. عرض الـJSON
  /// الخام كان يجعل اللوحة تبدو مكسورة حتى وهي تشتغل سليماً.
  String _restUserMessage(String body) {
    try {
      final v = jsonDecode(body);
      if (v is Map) {
        final m = '${v['message'] ?? ''}'.trim();
        return m;
      }
    } catch (_) {}
    return '';
  }

  String? lastAdminCouponError;

  /// ★ محفظة المندوب — مبلغ الخصم من الأكواد فقط.
  ///
  /// ★ [phone] يُرسل للمعامل لأن `app.current_phone()` غير مثبّت
  ///   عندك (تقرير قاعدة البيانات أعطى false)، والبديل الوحيد
  ///   حينها. إن ثُبِّت نظام التوكن لاحقاً تتجاهل الدالة المعامل
  ///   وتقرأ من التوكن تلقائياً — بلا تعديل هنا.
  /// ★ لا Ledger في الخدمة: القاعدة هي الدفتر، والتطبيق يعرض فقط.
  Future<Map<String, dynamic>?> fetchDriverWallet(String phone) async {
    lastDriverWalletError = null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/my_driver_wallet'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 12));

      if (res.statusCode == 404 || res.body.contains('PGRST202')) {
        lastDriverWalletError =
            'المحفظة غير مثبّتة — شغّل SQL_DRIVER_WALLET.sql';
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        lastDriverWalletError = 'تعذّر جلب المحفظة (${res.statusCode})';
        return null;
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        lastDriverWalletError = 'رد غير متوقع من الخادم';
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        lastDriverWalletError = '${map['error'] ?? 'تعذّر جلب المحفظة'}';
        return null;
      }
      // ★ المعلَّق يُدمج في نفس الخريطة: الشاشة تقرأ مصدراً واحداً، ولو
      //   فشل دمجه تبقى المحفظة الثابتة معروضة كما كانت.
      final pending = await fetchDriverPendingWallet(phone);
      if (pending != null) {
        map['pending_orders'] = pending['pending_orders'];
        map['pending_amount'] = pending['pending_amount'];
        map['pending_rows'] = pending['pending_rows'];
      }
      return map;
    } catch (_) {
      lastDriverWalletError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  /// آخر فشل في قراءة المعلَّق — **لا يُعرض للمندوب**: الفشل هنا يعني
  /// أن السطر يختفي، لا أن محفظته الفاسدة صفر. يُترك للتشخيص.
  String? lastDriverPendingError;

  /// ★ معلَّق محفظة مندوب واحد: خصم الأكواد على طلبات قبَلَها ولم تُسلَّم.
  ///
  /// تقرأ `driver_pending_wallet` من `SQL_DRIVER_PENDING_DISCOUNT.sql`؛
  /// الهوية فيها مثل `my_driver_wallet` تماماً — التوكن إن كان مثبَّتاً
  /// وإلا الرقم مع فحص أنه حساب مندوب. تُعيد null بلا رفع استثناء، فيمضي
  /// نداء المحفظة إلى عرضه العادي.
  Future<Map<String, dynamic>?> fetchDriverPendingWallet(String phone) async {
    lastDriverPendingError = null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/driver_pending_wallet'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 10));

      // نسخة القاعدة القديمة: الدالة غير موجودة إطلاقاً. الصمت هنا أفضل
      // من إظهار «معلَّق ٠» الذي يكذب على المندوب.
      if (res.statusCode == 404 || res.body.contains('PGRST202')) {
        lastDriverPendingError =
            'المعلَّق غير مثبَّت — شغّل SQL_DRIVER_PENDING_DISCOUNT.sql';
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        lastDriverPendingError = 'تعذّر جلب المعلَّق (${res.statusCode})';
        return null;
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        lastDriverPendingError = 'رد غير متوقع من الخادم';
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        lastDriverPendingError = '${map['error'] ?? 'تعذّر جلب المعلَّق'}';
        return null;
      }
      return map;
    } catch (_) {
      lastDriverPendingError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  /// رسالة آخر فشل في جلب محفظة المندوبين (للأدمن) — تُعرض في الشاشة.
  String? lastAdminDriverWalletError;

  /// ★ حصيلة آخر نجاح في [adminListDriverWallets]: إجمالي خصم المندوبين
  ///   وعدد المندوبين وسطور الدفتر والمدفوع. يُقرأ من **نفس رد الخادم**
  ///   الذي تُرسم منه البطاقات، فلا يختلف رقم الأعلى عن مجموع الأسفل.
  ///   `{}` = لم يُجلب شيء بعد (أو فشل الجلب).
  ///   ★ `total_pending` و`pending_orders` يَظهران **فقط** إن أرسلتهما
  ///   القاعدة (ملف المعلَّق); فغيابهما يعني «لا نعرف» لا «لا يوجد».
  Map<String, dynamic> lastAdminDriverWalletTotals = const {};

  /// ★ محفظة المندوبين (الأدمن): رصيد كل مندوب من الدفتر الحيّ + خصومه.
  ///
  /// تقرأ `admin_list_driver_wallets` المُثبَّتة على القاعدة، وهي
  /// محميّة بـ`admin_gate_ok()` (توكن الأدمن في `x-app-token`) — بوابة
  /// لا ترفع استثناءً، فلا يظهر «تعذّر الجلب (400)» بلا سبب.
  /// تُعيد null عند الفشل مع رسالة في [lastAdminDriverWalletError].
  Future<List<Map<String, dynamic>>?> adminListDriverWallets() async {
    lastAdminDriverWalletError = null;
    lastAdminDriverWalletTotals = const {};
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_list_driver_wallets'),
            headers: _headers,
            body: '{}',
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 404 || res.body.contains('PGRST202')) {
        lastAdminDriverWalletError =
            'غير مثبَّت — شغّل SQL_DRIVER_PENDING_DISCOUNT.sql';
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        // ★ رقم وحده كان يخفي السبب. جسم خطأ PostgREST يحمل رسالة
        //   القاعدة نفسها (النوع + النص)، وهو ما يحتاجه الأدمن ليقرر.
        final why = _restUserMessage(utf8.decode(res.bodyBytes));
        lastAdminDriverWalletError =
            'تعذّر الجلب (${res.statusCode}): '
            '${why.isEmpty ? _shortBody(utf8.decode(res.bodyBytes)) : why}';
        return null;
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        lastAdminDriverWalletError = 'رد غير متوقع من الخادم';
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        lastAdminDriverWalletError = '${map['error'] ?? 'تعذّر الجلب'}';
        return null;
      }
      final totals = <String, dynamic>{
        'total_discount':
            (map['total_discount'] is num ? (map['total_discount'] as num) : 0)
                .toDouble(),
        'total_paid':
            (map['total_paid'] is num ? (map['total_paid'] as num) : 0)
                .toDouble(),
        'total_due': (map['total_due'] is num ? (map['total_due'] as num) : 0)
            .toDouble(),
        'drivers': (map['drivers'] is num ? (map['drivers'] as num) : 0)
            .toInt(),
        'rows': (map['ledger_rows'] is num ? (map['ledger_rows'] as num) : 0)
            .toInt(),
      };
      // ★ المعلَّق يُنسخ **إن وُجد فقط**: وضعه صفراً بلا وجوده يجعل الشاشة
      //   تقول «لا معلَّق الآن» بينما الخادم القديم لم يُرسله أصلاً.
      //   غيابه = لا سطر في الشريط، وهو الصدق الوحيد الممكن.
      final tp = map['total_pending'];
      if (tp != null) {
        totals['total_pending'] = (tp is num ? tp : 0).toDouble();
      }
      final po = map['pending_orders'];
      if (po != null) {
        totals['pending_orders'] = (po is num ? po : 0).toInt();
      }
      lastAdminDriverWalletTotals = totals;
      final items = map['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      lastAdminDriverWalletError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  /// ★ تصفير محفظة مندوب (الأدمن) — تصفير حقيقي.
  ///
  /// لا يحذف شيئاً: الدالة `admin_reset_driver_wallet` تسجّل «دفعة»
  /// بقيمة المستحق في `driver_payouts` فيصبح الرصيد صفراً في كل
  /// الواجهات (محفظة المندوب نفسه تقرأ نفس الدفتر).
  ///
  /// تعمل بكلمة مرور الأدمن فقط (تُتحقق في القاعدة). تُعيد null عند
  /// التعذّر، وإلا خريطة الرد `{ok, reset, paid_now, message, ...}`.
  Future<Map<String, dynamic>?> adminResetDriverWallet(
    String phone,
    String adminPassword, {
    String? note,
  }) async {
    if (phone.isEmpty || adminPassword.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_reset_driver_wallet'),
            headers: _headers,
            body: jsonEncode({
              'p_phone': phone,
              'p_admin_password': adminPassword,
              if (note != null && note.trim().isNotEmpty) 'p_note': note.trim(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// سجل دفعات مندوب (الأدمن) — أحدثها أولاً. null عند التعذّر.
  Future<List<Map<String, dynamic>>?> adminDriverPayouts(String phone) async {
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_driver_payouts'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded['ok'] != true) return null;
      final items = decoded['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// رسالة آخر فشل في جلب محافظ الأطباء (للأدمن) — تُعرض في الشاشة.
  String? lastAdminDoctorWalletError;

  /// ★ حصيلة آخر نجاح في [adminListDoctorWallets]: الكشفيات كاملة
  ///   والاستقطاع الثابت والصافي والمدفوع والمستحق. من نفس رد الخادم
  ///   الذي تُرسم منه البطاقات. `{}` = لم يُجلب شيء بعد.
  Map<String, dynamic> lastAdminDoctorWalletTotals = const {};

  /// ★ محافظ الأطباء (الأدمن): لكل عيادة كشفياتها واستقطاعها الثابت
  ///   وصافيها ورصيدها. تقرأ `admin_list_doctor_wallets` المحمية بالأدمن.
  ///   تُعيد null عند الفشل مع رسالة في [lastAdminDoctorWalletError].
  Future<List<Map<String, dynamic>>?> adminListDoctorWallets() async {
    lastAdminDoctorWalletError = null;
    lastAdminDoctorWalletTotals = const {};
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_list_doctor_wallets'),
            headers: _headers,
            body: '{}',
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 404 || res.body.contains('PGRST202')) {
        lastAdminDoctorWalletError =
            'غير مثبَّت — شغّل SQL_DOCTOR_SECRETARY_WALLET.sql';
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final why = _restUserMessage(utf8.decode(res.bodyBytes));
        lastAdminDoctorWalletError =
            'تعذّر الجلب (${res.statusCode}): '
            '${why.isEmpty ? _shortBody(utf8.decode(res.bodyBytes)) : why}';
        return null;
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        lastAdminDoctorWalletError = 'رد غير متوقع من الخادم';
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        lastAdminDoctorWalletError = '${map['error'] ?? 'تعذّر الجلب'}';
        return null;
      }
      lastAdminDoctorWalletTotals = <String, dynamic>{
        'total_gross':
            (map['total_gross'] is num ? (map['total_gross'] as num) : 0)
                .toDouble(),
        'total_commission':
            (map['total_commission'] is num
                    ? (map['total_commission'] as num)
                    : 0)
                .toDouble(),
        'total_net': (map['total_net'] is num ? (map['total_net'] as num) : 0)
            .toDouble(),
        'total_paid':
            (map['total_paid'] is num ? (map['total_paid'] as num) : 0)
                .toDouble(),
        'total_due': (map['total_due'] is num ? (map['total_due'] as num) : 0)
            .toDouble(),
        'doctors': (map['doctors'] is num ? (map['doctors'] as num) : 0)
            .toInt(),
        'commission_percent':
            // ★ العيادات بلا نسبة: الاستقطاع ثابت 500 لكل حجز.
            (map['commission_percent'] is num
                    ? (map['commission_percent'] as num)
                    : 0)
                .toInt(),
      };
      final items = map['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      lastAdminDoctorWalletError = 'تعذّر الاتصال بالخادم';
      return null;
    }
  }

  /// ★ تصفير محفظة عيادة (الأدمن) — لا يحذف شيئاً: يحوّل
  ///   `admin_reset_doctor_wallet` الرصيد المستحق إلى «صرف» ثم ينقل
  ///   بداية الحساب إلى الآن، فتبدأ الأرقام (الكشفيات والاستقطاع والصافي)
  ///   من الصفر ولا يدخل في الحساب أي مبلغ قبل التصفير.
  ///
  /// تعمل بكلمة مرور الأدمن فقط (تُتحقق في القاعدة). تُعيد null عند
  /// التعذّر، وإلا خريطة الرد `{ok, reset, paid_now, reset_at, message, ...}`.
  Future<Map<String, dynamic>?> adminResetDoctorWallet(
    String doctorId,
    String adminPassword, {
    String? note,
  }) async {
    if (doctorId.isEmpty || adminPassword.isEmpty) return null;
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_reset_doctor_wallet'),
            headers: _headers,
            body: jsonEncode({
              'p_doctor_id': doctorId,
              'p_admin_password': adminPassword,
              if (note != null && note.trim().isNotEmpty) 'p_note': note.trim(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// سجل صرف عيادة (الأدمن) — أحدثها أولاً. null عند التعذّر.
  Future<List<Map<String, dynamic>>?> adminDoctorPayouts(
    String doctorId,
  ) async {
    try {
      final res = await _http
          .post(
            Uri.parse('${_url}rpc/admin_doctor_wallet_payouts'),
            headers: _headers,
            body: jsonEncode({'p_doctor_id': doctorId}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded['ok'] != true) return null;
      final items = decoded['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// كل أكوادي + حالة كل كود وتاريخ استعماله.
  Future<Map<String, dynamic>?> fetchMyCoupons(String? phone) async {
    if (phone == null || phone.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_my_coupons'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// تقدّمي نحو الكود القادم. مع `phone` فارغ ترجع الإعدادات فقط
  /// (يستعملها الأدمن لقراءة «كل كم طلب» و«مفعّل؟»).
  Future<Map<String, dynamic>?> fetchCouponProgress(String? phone) async {
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_coupon_progress'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// كل الأكواد (للأدمن) — مع الاستعمال وتوقيته.
  Future<List<Map<String, dynamic>>> fetchAllCoupons({int limit = 200}) async {
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_all_coupons'),
            headers: _headers,
            body: jsonEncode({'p_limit': limit}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return const [];
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const [];
      return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
    } catch (_) {
      return const [];
    }
  }

  /// تصفير حساب — الأدمن فقط بكلمة مرور.
  Future<Map<String, dynamic>?> adminResetCoupons(
    String phone,
    String adminPassword,
  ) async {
    if (phone.isEmpty || adminPassword.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/admin_reset_coupons'),
            headers: _headers,
            body: jsonEncode({
              'p_phone': phone,
              'p_admin_password': adminPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// ضبط نظام الأكواد — الأدمن فقط بكلمة مرور.
  Future<Map<String, dynamic>?> adminSetCouponConfig(
    int earnedEvery,
    bool enabled,
    String prefix,
    String adminPassword,
  ) async {
    if (adminPassword.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/admin_set_coupon_config'),
            headers: _headers,
            body: jsonEncode({
              'p_earned_every': earnedEvery,
              'p_enabled': enabled,
              'p_prefix': prefix,
              'p_admin_password': adminPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  // ==========================================================
  //  المكافآت القديمة (لم تُستخدم بعد حذف النقاط)
  // ==========================================================

  /// يسجّل أن طلباً تم استلامه ونُسبت نقاطه — **مرة واحدة فقط**.
  ///
  /// Decision "بدون تكرار" يأتي من الخادم عبر دالة `award_reward_record`
  /// (فهرس فريد على order_id)، فمحاولة من جهاز آخر تُرفض أيضاً.
  /// عدد النقاط يقرأه الخادم من `app_settings` ⇒ الأدمن يغيّره بلا تحديث.
  Future<RewardRecordStatus> awardRewardRecord(
    String orderId,
    String? phone,
  ) async {
    if (orderId.isEmpty || phone == null || phone.isEmpty) {
      return RewardRecordStatus.failed;
    }
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/award_reward_record'),
            headers: _headers,
            body: jsonEncode({'p_order_id': orderId, 'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final out =
            (jsonDecode(res.body) as String?)?.trim().toLowerCase() ?? '';
        if (out == 'awarded') return RewardRecordStatus.awarded;
        if (out == 'already') return RewardRecordStatus.already;
        return RewardRecordStatus.failed;
      }
      if (res.statusCode == 409) return RewardRecordStatus.already;
      return RewardRecordStatus.failed;
    } catch (_) {
      return RewardRecordStatus.failed;
    }
  }

  /// يقرأ الطلبات التي مُنحت نقاطها **فعلاً** من الخادم.
  ///
  /// بدون هذه الدالة كانت الشاشة تعتمد على مجموعة داخل الذاكرة فقط، وهي
  /// تبدأ فارغة عند كل فتح ⇒ يظهر زر المكافأة من جديد على كل طلب مُستلَم
  /// سابقاً (وهي "مكافأة مكررة"). هنا نقرأ الحقيقة من الخادم.
  ///
  /// نمرّ عبر دالة `get_awarded_order_ids` لا بقراءة الجدول مباشرة، حتى
  /// نمنع دور `anon` أي وصول لجدول النقاط (قراءةً أو كتابةً).
  ///
  /// ترجع مجموعة فارغة عند انقطاع الشبكة، ولا تُفقد المستخدم أي رصيد:
  /// الأرقام تُقرأ من `get_rewards_summary` وليست من هنا.
  Future<Set<String>> fetchRewardedOrderIds(String? phone) async {
    if (phone == null || phone.isEmpty) return {};
    try {
      final res = await http
          .post(
            Uri.parse('${_url}rpc/get_awarded_order_ids'),
            headers: _headers,
            body: jsonEncode({'p_phone': phone}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return {};
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return {};
      return decoded.map((e) => '$e'.trim()).where((s) => s.isNotEmpty).toSet();
    } catch (_) {
      return {};
    }
  }

  /// يحذف كل إشعارات طلب معيّن **الخاصة بالمستخدم الحالي** — يُستدعى
  /// عند تأكيد استلام النقاط، فيختفي الطلب من الجرس ولا تبقى أي
  /// إشارة قديمة.
  ///
  /// ★ الدالة القديمة `clear_order_notifications` في القاعدة تحذف
  ///   بلا مُرشِّح لرقم الهاتف ⇒ تمسح إشعارات الطلب من حسابات الآخرين،
  ///   لذلك لم نعد نستدعيها، والحذف المباشر صار مقصوراً على [userPhone].
  Future<void> clearOrderNotifications(
    String orderId, {
    String? userPhone,
  }) async {
    if (orderId.isEmpty) return;
    final phone = (userPhone ?? '').trim();
    if (phone.isEmpty) return;
    await deleteNotificationsForOrder(orderId, phone);
  }

  // ==========================================================
  //  أكواد الخصم (توصيل مجاني)
  // ==========================================================

  Future<Map<String, dynamic>?> createCoupon({
    required String code,
    String? note,
    int discountPercent = 100,
  }) async {
    try {
      final res = await _http.post(
        Uri.parse('${_url}coupons'),
        headers: _headers,
        body: jsonEncode({
          'code': code.trim().toUpperCase(),
          'note': (note == null || note.trim().isEmpty) ? null : note.trim(),
          'discount_percent': discountPercent,
          'is_active': true,
        }),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is List && body.isNotEmpty) {
          return Map<String, dynamic>.from(body.first as Map);
        }
      }
    } catch (_) {}
    return null;
  }
}

/// نتيجة إحصائيات صاحب الصيدلية.
class ShopOwnerStats {
  const ShopOwnerStats({
    required this.fulfilledOrders,
    required this.rejectedOrders,
    required this.profit,
  });

  final int fulfilledOrders;
  final int rejectedOrders;
  final double profit;
}

/// أرقام مجموعة واحدة (عدد الطلبات + إجمالي المبالغ + المبالغ المسلّمة).
class OrderCountStat {
  const OrderCountStat({
    required this.count,
    required this.total,
    required this.delivered,
  });
  final int count;
  final double total;
  final double delivered;
}

/// إحصائيات الطلبات لكل فترة: اليوم / آخر ٧ أيام / آخر ٣٠ يوماً.
class OrderPeriodStats {
  const OrderPeriodStats({
    required this.day,
    required this.week,
    required this.month,
    required this.updatedAt,
  });
  final OrderCountStat day;
  final OrderCountStat week;
  final OrderCountStat month;
  final DateTime updatedAt;
}

/// يُمرَّر التوكن الذي أثبته خادم الرموز (qrlogn) إلى طبقة الخدمة،
/// فيستخدمه `loginWithToken` مرة واحدة فقط ثم يُبطَل.
extension WaTokenBridge on SupabaseService {
  set pendingWaToken(String? value) => _pendingWaToken = value;
  String? get pendingWaToken => _pendingWaToken;
}
