import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ★ **تذكرة لوحة التحكم** — الكلمة تُدخَل مرة، ويبقى على الجهاز بديلٌ لا
/// يعمل خارج هذا الهاتف ولا خارج هذه الجلسة.
///
/// **لماذا هذه الخدمة؟**
///
/// كان كل زر إداري يطلب كلمة المرور من جديد: إيقاف كود، حذفه، تعديل طلب،
/// تصفير رصيد… فبدأ الأدمن يتعامل معها كإجراء شكلي لا كحماية. ثم طلب
/// صراحة (2026-10-10): «لا تطلبها بعد أن أكتبها مرة واحدة، حتى لو قفلت
/// الهاتف وفتحته — إلا إذا تغيّرت كلمة السر في القاعدة».
///
/// **ما الذي تغيّر اليوم (حماية اللوحة من السرقة):**
///   • لم تعد الكلمة هي ما يُحفظ على القرص. تُرسَل الكلمة مرة واحدة إلى
///     `admin_panel_login`، فتُبدَّل في القاعدة **تذكرةً** عشوائية (64 محرفاً
///     ستاتياً) مربوطة بجلسة هذا الحساب، صالحة سبعة أيام، تسقط لحظة سحب
///     دور الأدمن، وتُبطل كلها بـ `select public.admin_device_revoke_all();`.
///   • القاعدة لا تحتفظ إلا بتجزئة التذكرة، فهي لا تُسترجع من أي جدول،
///     ولا تُطبع في أي سجل.
///   • **مفتاح anon المستخرج من الـAPK لم يعد يكفّي أحداً**: التذكرة لا تعمل
///     بلا توكن الجلسة الموقّع لصاحبها، ولا على جهاز غيره.
///   • من يفتح ملف التفضيلات على هاتف غير مقفول لا يجد كلمة اللوحة — يجد
///     تذكرة ميتة إن سحبها الأدمن من اللوحة.
///
/// **التخزين**: تمويه XOR + base64 (كما كان) — يمنع القراءة العفيفة من ملف
/// التفضيلات ولا يدّعي تشفيراً. التذكرة قصيرة العمر ومربوطة بالجلسة، فقيمة
/// ما يسرقه محدودة بزمن وبمفتاح إبطال، بخلاف الكلمة القديمة.
///
/// **تدرّج مقصود (لا كسر قبل تشغيل SQL):**
///   • `adm_gate_v2` = التذكرة — بعد تنفيذ `SQL_ADMIN_PANEL_LOCKDOWN.sql`.
///   • `adm_gate_v1` = الكلمة القديمة — يبقى يعمل **فقط** لو لم تُنفَّذ
///     SQL بعد، وبمجرد صدور أول تذكرة يُمحى من القرص نهائياً.
///   • القيمة القديمة ترحل مع الجديدة: لا يُطلب من الأدمن إعادة كتابة
///     شيئاً عند الانتقال.
///
/// **ما لم يتغيّر**: كل عملية إدارية ما زالت تُفحص في القاعدة، وكلمة/تذكرة
/// خاطئة ⇒ العملية لا تُنفَّذ إطلاقاً؛ وتُمسح الحافظة عند تسجيل الخروج.
class AdminPasswordSession {
  AdminPasswordSession._();

  static String? _cached;

  /// ★ هل القيمة المستعادة جاءت من القرص (لم تُكتب في هذا الفتح)؟
  ///
  /// تُستعمل مرة واحدة فقط: أول دخول للوحة يتحقق منها في الخادم بصمت،
  /// فلو تغيّرت كلمة اللوحة في القاعدة أو انتهت التذكرة تُنسى وتُطلب.
  static bool _fromDisk = false;

  /// ★ هل ما في الحافظة **تذكرة** (وليس كلمة اللوحة)؟
  static bool _isTicket = false;

  static const String _ticketKey = 'adm_gate_v2';
  static const String _legacyKey = 'adm_gate_v1';

  /// قناع التمويه — لا يعني تشفيراً، وغايته ألّا تُقرأ القيمة عياناً
  /// من ملف التفضيلات على الجهاز.
  static const List<int> _mask = [0x5a, 0x37, 0x6c, 0x19, 0x4e, 0x71, 0xb3];

  /// ★ شكل التذكرة التي تصدرها القاعدة: تجزئتا uuid ملتحمتان — 64 محرفاً
  ///   ستاتياً. التمييز بهذا الشكل (لا بالطول) حتى لا تُحسب كلمة طويلة
  ///   تذكرةً فتُرفض عند البوابة القديمة.
  static final RegExp _ticketShape = RegExp(r'^[0-9a-fA-F]{64}$');

  /// هل هذه القيمة تذكرة جلسة أم كلمة اللوحة القديمة؟
  static bool isTicket(String v) => _ticketShape.hasMatch(v.trim());

  static String? get cached => _cached;

  /// ★ التذكرة الحية إن كانت في الحافظة، وإلا `null` (كلمة قديمة أو لا شيء).
  static String? get cachedTicket => _isTicket ? _cached : null;

  /// هل احتُفظ بقيمة جاهزة (تذكرة أو كلمة انتقالياً)؟
  static bool get hasPassword => (_cached ?? '').isNotEmpty;

  /// كلمة/تذكرة محفوظة لكنها **لم تُتحقق** من القاعدة في هذا الفتح.
  static bool get needsServerCheck => _fromDisk && hasPassword;

  /// هل ما في الحافظة تذكرة جلسة (أم كلمة اللوحة)؟
  static bool get holdsTicket => _isTicket && hasPassword;

  /// ★ تُحفظ للبقية — وفي القرص حتى تنجو من إغلاق التطبيق.
  ///
  ///   تمرّر الشاشة هنا **ما أعادتْه القاعدة**: تذكرة عند نجاح
  ///   `admin_panel_login`، أو الكلمة نفسها في الفترة الانتقالية التي لم
  ///   تُنفَّذ فيها SQL بعد. فلا يحمل الجهاز كلمة اللوحة متى أمكن الاستغناء.
  static void remember(String value) {
    final v = value.trim();
    _cached = v.isEmpty ? null : v;
    _isTicket = v.isNotEmpty && isTicket(v);
    _fromDisk = false; // كُتبت الآن: موثوقة لهذا الفتح.
    unawaited(_persist(_cached, _isTicket));
  }

  /// ★ تُستخدم للعمليات اللاحقة بعد أول إدخال واحد.
  ///
  /// إن كانت محفوظة نعيد تجربة المحاولة بها تلقائياً، والنتيجة الفاشلة
  /// تُبطلها — حمايةً لانتهاء التذكرة أو لتغيّر كلمة المرور في القاعدة.
  ///
  /// تُعيد true إذا استُخدمت المحفوظة (لا داعي لطلبها من المستخدم).
  static Future<bool> tryUseCached(
    Future<bool> Function(String password) send,
  ) async {
    final p = _cached;
    if (p == null || p.isEmpty) return false;
    if (await send(p)) return true;
    clear();             // فشلت: انتهت أو تغيّرت ⇒ نُمسحها من كل مكان
    return true;
  }

  /// ★ تُمسح عند تسجيل الخروج، وعند أي رفض من الخادم لقيمة محفوظة.
  static void clear() {
    _cached = null;
    _fromDisk = false;
    _isTicket = false;
    unawaited(_persist(null, false));
  }

  /// ★ يُستدعى مرة واحدة في `main()` قبل `runApp`: يُرجع ما حفظناه من فتح
  ///   سابق، فيُفتح التطبيق بلا سؤال — حتى بعد قفل الهاتف وفتحه.
  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // (1) التذكرة أولاً: هي الوضع الطبيعي بعد تشغيل SQL.
      final sealedTicket = prefs.getString(_ticketKey) ?? '';
      if (sealedTicket.isNotEmpty) {
        final t = _open(sealedTicket);
        if (t.isNotEmpty && isTicket(t)) {
          _cached = t;
          _isTicket = true;
          _fromDisk = true;
          // لا نُبقي كلمة اللوحة على القرص ما دمنا لسنا بحاجة إليها.
          await prefs.remove(_legacyKey);
          return;
        }
        // قيمة تالفة/لا معنى لها: نمسحها ولا نعلّق عليها.
        await prefs.remove(_ticketKey);
      }

      // (2) الوضع الانتقالي: لم تُنفَّذ SQL بعد ⇒ الكلمة القديمة تعمل.
      final sealedLegacy = prefs.getString(_legacyKey) ?? '';
      if (sealedLegacy.isEmpty) return;
      final p = _open(sealedLegacy);
      if (p.isNotEmpty) {
        _cached = p;
        _isTicket = false;
        _fromDisk = true;
      }
    } catch (_) {}
  }

  /// بعد تحقق ناجح من الخادم في هذا الفتح: لم يعد بحاجة لفحص صامت.
  static void markVerified() => _fromDisk = false;

  /// ★★ تُستبدل الكلمة بالتذكرة (بعد `admin_panel_login` ناجح).
  ///
  ///   تُكتب التذكرة في `adm_gate_v2` ويُمحى `adm_gate_v1` من القرص في نفس
  ///   اللحظة — فهذا هو المقصود كله: أن يختفي من الجهاز ما يشبه كلمة اللوحة.
  static void promoteToTicket(String ticket) {
    final t = ticket.trim();
    if (!isTicket(t)) return; // لا نكتب شيئاً غير تذكرة صحيحة الشكل.
    _cached = t;
    _isTicket = true;
    _fromDisk = false;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_ticketKey, _seal(t));
        await prefs.remove(_legacyKey);
      } catch (_) {}
    }());
  }

  static Future<void> _persist(String? value, bool asTicket) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = asTicket ? _ticketKey : _legacyKey;
      final otherKey = asTicket ? _legacyKey : _ticketKey;
      if (value == null || value.isEmpty) {
        await prefs.remove(_ticketKey);
        await prefs.remove(_legacyKey);
        return;
      }
      await prefs.setString(key, _seal(value));
      // ★ لا تبقى النسختان معاً: لو حذفنا هذا السطر صار جهاز يحمل تذكرة
      //   يحمل معها الكلمة القديمة في ملف واحد — والهدف هو زوال الكلمة.
      await prefs.remove(otherKey);
    } catch (_) {}
  }

  static String _seal(String p) {
    final b = utf8.encode(p);
    final out = Uint8List(b.length);
    for (var i = 0; i < b.length; i++) {
      out[i] = b[i] ^ _mask[i % _mask.length];
    }
    return base64.encode(out);
  }

  static String _open(String s) {
    try {
      final b = base64.decode(s);
      final out = Uint8List(b.length);
      for (var i = 0; i < b.length; i++) {
        out[i] = b[i] ^ _mask[i % _mask.length];
      }
      return utf8.decode(out);
    } catch (_) {
      return '';
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _cached = null;
    _fromDisk = false;
    _isTicket = false;
  }
}
