import 'dart:convert';

/// منطق «استعادة كلمة المرور» — دوال صرفة بلا شبكة ولا ويجت.
///
/// ★ لماذا ملف مستقل؟ لأن الكتابة كلها تحدث داخل القاعدة في دالة
///   `reset_password_reason` (انظر `SQL_FIX_PASSWORD_RESET.sql`)،
///   ولا يملك التطبيق منها إلا أمرين: أن يمنع إرسال كلمة مرور لن تقبلها
///   القاعدة، وأن **يشرح** سبب الرفض بالعربية. الشرح هو ما كان مفقوداً:
///   كانت `resetPassword` تعيد `false` لكل الأعطال بلا تمييز، فالزبون يسمع
///   «تعذّر الحفظ» ولا يعرف هل أرسل الكود أصلاً، ولا هل الرقم مسجّل،
///   ولا هل الكلمة قصيرة. هنا يصير لكل رمز رسالة، وتُختبَر بلا شبكة.
class PasswordReset {
  const PasswordReset._();

  /// الحد الأدنى — نفس ما تشترطه القاعدة، وإلا يُرفض الطلب عند أول حرف.
  static const int minLength = 6;

  /// ★ الحد الأقصى ٧٢ **بايتاً** لا ٧٢ محرفاً: bcrypt يقصّ كلمة المرور فوق
  ///   ٧٢ بايت بصمت، فكلمة من ٨٠ حرفاً كانت تُحفظ بأول ٧٢ منها فقط — ويدخل
  ///   الزبون «كلمته الكاملة» فيُرفض. والمحارف العربية بايتان لكل حرف، لذا
  ///   المقياس هنا بايتٌ لا حرف: ٤٠ حرفاً عربيّاً = ٨٠ بايت = مقطوعة.
  static const int maxLength = 72;

  /// عدد البايتات بعد ترميز UTF-8 — هو ما يقيسه bcrypt.
  static int byteLength(String password) => utf8.encode(password).length;

  /// تطبيع الرقم: الأرقام كما هي، بلا مسافات ولا شرطات ولا بادئات.
  ///
  /// لا قصر على ١١ هنا عمداً: من يقصّ «9647857683066» إلى آخر ١١ يحوّله
  /// إلى رقم آخر لا يطابق آخر ٩ أرقام للتوكن، فتُرفض استعادة سليمة
  /// بـ«PHONE_MISMATCH». الأفضل أن يمرّ كما هو ويقع الرفض في `validate`
  /// حيث يُقال للزبون «أدخل رقم هاتف صحيح (١١ رقماً)».
  static String digits(String raw) => raw.replaceAll(RegExp(r'[^0-9]'), '');

  /// `null` = صالح للإرسال، وإلا رسالة عربية تُعرض قبل أي رحلة شبكة.
  static String? validate(
    String password,
    String confirmation, {
    required String phone,
  }) {
    if (digits(phone).length != 11) return 'أدخل رقم هاتف صحيح (١١ رقماً)';
    if (password.isEmpty) return 'اكتب كلمة المرور الجديدة';
    if (password.length < minLength) {
      return 'كلمة المرور $minLength محارف على الأقل';
    }
    if (byteLength(password) > maxLength) {
      return 'كلمة المرور طويلة — الحد $maxLength بايت';
    }
    if (password != confirmation) return 'كلمتا المرور غير متطابقتين';
    return null;
  }

  /// سطر النجاح: **اسم الحساب نفسه** لا لقب عام، لأن الزبون يحتاج أن
  /// يتأكد أن الكلمة تغيّرت لحسابه هو لا لحساب آخر.
  static String successLine(Map<String, dynamic> res, {required String phone}) {
    final name = (res['name'] ?? '').toString().trim();
    final stored = (res['phone'] ?? '').toString().trim();
    final who = name.isNotEmpty
        ? name
        : (stored.isNotEmpty ? stored : digits(phone));
    return 'تم تغيير كلمة مرور $who — سجّل الدخول بها الآن';
  }

  /// رسالة الفشل بالعربية من رمز الدالة (أو من HTTP عند تعذّر الاتصال).
  static String failureLine(Map<String, dynamic> res) {
    final code = (res['error'] ?? '').toString();

    // أي ردّ HTTP: 404 يعني الدالة غير منصّبة بعد، وغيره رقم حالة يُقال
    // كما هو لأنه دليل خدمة العملاء.
    if (code.startsWith('HTTP_')) {
      if (code == 'HTTP_404') {
        return 'دالة استعادة كلمة المرور غير منصّبة بعد — '
            'شغّل SQL_FIX_PASSWORD_RESET.sql';
      }
      return 'تعذّر الحفظ على السيرفر (رمز ${code.substring(5)}) — '
          'أعد المحاولة بعد قليل';
    }

    switch (code) {
      // ── ما قبل الإرسال: في المتابعة أو في الرقم ──────────────────────
      case 'PW_SHORT':
        return 'كلمة المرور $minLength محارف على الأقل';
      case 'PW_LONG':
        return 'كلمة المرور طويلة — الحد $maxLength بايت';
      case 'BAD_PHONE':
        return 'أدخل رقم هاتف صحيح (١١ رقماً)';

      // ── التأكيد بالكود: لا تُقبل كتابة بلا دليل من خادم واتساب ───────
      case 'MISSING_TOKEN':
      case 'BAD_TOKEN':
      case 'BAD_PAYLOAD':
      case 'BAD_CLAIMS':
      case 'BAD_SIGNATURE':
        return 'لم يتم تأكيد الرقم بعد — أرسل الكود وأكّده ثم احفظ';
      case 'TOKEN_EXPIRED':
        return 'انتهت صلاحية الكود — أرسل كوداً جديداً';
      case 'TOKEN_REPLAYED':
        return 'هذا الكود استُخدم من قبل — أرسل كوداً جديداً';
      case 'PHONE_MISMATCH':
        return 'الكود اكتمل لرقم غير هذا الرقم — أعد المحاولة برقمك';

      // ── الحساب نفسه ─────────────────────────────────────────────────
      case 'NO_ACCOUNT':
        return 'لا يوجد حساب بهذا الرقم — سجّل حساباً جديداً أولاً';
      case 'ACCOUNT_DISABLED':
        return 'الحساب موقوف — راجع خدمة العملاء لرفعه';
      case 'AMBIGUOUS_PHONE':
        return 'الرقم مطابق لأكثر من حساب — راجع خدمة العملاء';

      // ── بيئة الخادم: لا ذنب للزبون فيها، لكن يجب أن تُقال ────────────
      case 'NOT_CONFIGURED':
        return 'خادم التحقق غير مضبوط — راجع خدمة العملاء';
      case 'NO_HASH_TRIGGER':
      case 'HASH_NOT_WRITTEN':
      case 'NOT_UPDATED':
      case 'TOKEN_STATE_FAILED':
        return 'تعذّر الحفظ على السيرفر — أعد المحاولة بعد قليل';
      case 'LOCKED':
        final left = (res['retry_after'] ?? '').toString().trim();
        return left.isEmpty
            ? 'المحاولات موقوفة مؤقتاً — حاول بعد قليل'
            : 'كثرت المحاولات على هذا الرقم — حاول بعد $left';

      // ── المسار القديم: الدالة ما زالت تُرجع boolean ──────────────────
      case 'LEGACY_FUNCTION':
        return 'دالة استعادة كلمة المرور قديمة — شغّل SQL_FIX_PASSWORD_RESET.sql';
      case 'BAD_RESPONSE':
        return 'ردّ غير متوقع من السيرفر — أعد المحاولة بعد قليل';
      case 'EXCEPTION':
        return 'تعذّر الاتصال بالسيرفر — تأكد من الشبكة وأعد المحاولة';
      default:
        return code.isEmpty
            ? 'تعذّر تغيير كلمة المرور'
            : 'تعذّر تغيير كلمة المرور ($code)';
    }
  }
}
