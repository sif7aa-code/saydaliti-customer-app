import 'account_name.dart';
import 'password_reset.dart';

/// ★ كل حقول الدخول والتسجيل **إجبارية** — والمصدر واحد.
///
///   الطلب (2026-10-30): «اجعل جميع الحقول إجبارياً عند تسجيل الدخول
///   وإنشاء حساب». الحقول كانت مبعثرة في ثلاث شاشات (كلمة مرور / كود
///   واتساب / إنشاء حساب)، وكل شاشة لها `validator` مكتوب داخلها:
///   الرقم كان يقبل أي أحد عشر رقماً، وكلمة المرور في التسجيل تُقبل
///   بأربعة محارف بينما الاستعادة في القاعدة تشترط ستة، وحقل الاسم
///   كان يقبل «حساب» اسماً — وهو اللقب العام الذي يرفضه الأدمن في كل
///   مكان آخر (`AccountName`).
///
///   هنا تُكتب الحجج مرة واحدة والشاشات تستدعيها فقط، فلا تُصلح شاشة
///   وتبقى أخرى. الدوال صرفة بلا ويجلات ولا شبكة، فتُختبر مباشرة في
///   `test/auth_fields_test.dart`.
class AuthFields {
  const AuthFields._();

  /// طول الرقم المحفوظ في `users.phone` (١١ رقماً، دائماً).
  static const int phoneLength = 11;

  /// بادئة رقم الموبايل. تُشترط عند **إنشاء الحساب** لا عند الدخول:
  /// من كان له حساب قديم بصيغة أخرى يجب ألا يجده هذا الحقل مقفولاً
  /// أمامه، فالقاعدة هي المرجع هناك لا الواجهة.
  static const String mobilePrefix = '07';

  /// الاسم: لا يُقبل فراغ ولا حرفان — ولا لقب عام.
  static const int nameMinLength = 3;
  static const int nameMaxLength = 40;

  /// كلمة المرور في التسجيل = نفس حدود الاستعادة (`PasswordReset`):
  /// ما يُسجَّل اليوم هو ما سيُستعاد غداً، فلا معنى لقبول كلمة لن
  /// يقبلها حساب صاحبه بعد أسبوع حين ينساها.
  static const int passwordMinLength = PasswordReset.minLength;

  /// تطبيع للقيس فقط: الأرقام تبقى وكل ما عداها يذهب.
  static String digits(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

  /// نص نظيف: الفراغ وحده حقل فارغ — «   » لا يُحسب محتوى.
  static String trim(String raw) => raw.trim();

  // ── رقم الهاتف ───────────────────────────────────────────────────────

  /// يعيد رسالة الخطأ كما تُعرض تحت الحقل، أو `null` إن لم يكن خلل.
  /// [requireMobilePrefix] = `true` في التسجيل فقط (انظر [mobilePrefix]).
  static String? phoneError(String raw, {bool requireMobilePrefix = false}) {
    final d = digits(raw);
    if (d.isEmpty) return 'أدخل رقم الهاتف';
    if (d.length != phoneLength) {
      return 'يجب أن يكون الرقم 11 رقماً بالضبط';
    }
    if (requireMobilePrefix && !d.startsWith(mobilePrefix)) {
      return 'رقم الهاتف يبدأ بـ07 مثل 07800000000';
    }
    return null;
  }

  // ── كلمة المرور ──────────────────────────────────────────────────────

  /// كلمة المرور عند **الدخول**: إجبارية بلا حدّ طول — القاعدة هي من
  /// يقرر صحتها، ومن كانت كلمته أربعة محارف في حساب قديم يدخل بها
  /// اليوم. الرسالة الوحيدة: لا يُترك الحقل فارغاً.
  static String? loginPasswordError(String raw) {
    if (trim(raw).isEmpty) return 'أدخل كلمة المرور';
    return null;
  }

  /// كلمة المرور عند **إنشاء الحساب**: إجبارية + نفس حدود الاستعادة.
  /// الطول يُقاس بايتاً لا محرفاً: bcrypt يقصّ فوق ٧٢ بايت بصمت،
  /// فالتسجيل بكلمة عربية طويلة كان يحفظ نصفها ويُرفض عند الدخول.
  static String? passwordError(String raw) {
    if (raw.isEmpty) return 'أدخل كلمة المرور';
    if (raw.length < passwordMinLength) {
      return 'كلمة المرور $passwordMinLength محارف على الأقل';
    }
    if (PasswordReset.byteLength(raw) > PasswordReset.maxLength) {
      return 'كلمة المرور طويلة — الحد ${PasswordReset.maxLength} بايت';
    }
    return null;
  }

  /// تطابق «تأكيد كلمة المرور» — للحقول التي فيها حقل تأكيد.
  static String? confirmError(String password, String confirmation) {
    if (trim(confirmation).isEmpty) return 'أعد كتابة كلمة المرور';
    if (password != confirmation) return 'كلمتا المرور غير متطابقتين';
    return null;
  }

  // ── اسم الحساب ───────────────────────────────────────────────────────

  /// الاسم إجباري عند التسجيل، ولا يُقبل لقب عام («حساب» / «زبون» /
  /// «مندوب»): هذا الحقل هو ما يظهر في كل لوحة وواجهة من بعده،
  /// فاللقب فيه يعني أن الحساب بلا اسم إلى الأبد.
  static String? nameError(String raw) {
    final s = trim(raw);
    if (s.isEmpty) return 'أدخل اسم الصيدلية أو اسمك';
    if (AccountName.isGeneric(s)) {
      return 'اكتب اسمه الحقيقي، لا لقباً مثل «حساب» أو «زبون»';
    }
    if (s.runes.length < nameMinLength) {
      return 'الاسم $nameMinLength محارف على الأقل';
    }
    if (s.runes.length > nameMaxLength) {
      return 'الاسم طويل — الحد $nameMaxLength محرفاً';
    }
    return null;
  }

  // ── كود واتساب ───────────────────────────────────────────────────────

  /// الكود لا يُترك فارغاً، ويُقبل بطوله الكامل فقط — وإلا ضاع انتظار
  /// الشبكة على طلب مرفوض سلفاً. [codeLength] من خدمة واتساب.
  static String? codeError(String raw, {required int codeLength}) {
    final d = digits(raw);
    if (d.isEmpty) return 'أدخل كود التحقق';
    if (d.length != codeLength) return 'أدخل الكود كاملاً ($codeLength أرقام)';
    return null;
  }
}
