import 'package:flutter/foundation.dart';

/// عدّاد تشخيصي لعدد طلبات القراءة في التطبيق — لمقارنة «قبل/بعد» فقط.
///
/// ★ لماذا ملف مستقل؟
///   طلب صاحب الصيدلية (2026-11-08) كان: «قارن عدد استدعاءات API قبل وبعد
///   التحسين». ولأن كل دوال الشبكة تبتلع أخطاءها وتعيد قيماً افتراضية،
///   فإن عدّاد `RequestHealth` الحالي يقيس **الفاشل** فقط. هذا العدّاد
///   يقيس **الكل** حسب الاسم الدلالي للدالة، فيُقرأ في وضع التطوير
///   ويُصفَّر بين قياسين.
///
/// ★ لا يؤثر على أي منطق: كتابة رقم في `Map` فحسب، ولا طبع إلا في
///   `kDebugMode`. لا يُستدعى من واجهة المستخدم ولا يغيّر أي قرار.
abstract final class ApiMetrics {
  ApiMetrics._();

  /// اسم الطلب الدلالي ⇒ عدد مرات تنفيذه منذ آخر [reset].
  static final Map<String, int> counts = <String, int>{};

  /// يسجّل طلباً واحداً.
  static void hit(String name) {
    counts[name] = (counts[name] ?? 0) + 1;
  }

  /// يصفّر العدادات قبل بدء قياس جديد.
  static void reset() => counts.clear();

  /// ملخّص نصّي: `get_my_notifications=12, products=3, ...`
  static String summary() {
    final keys = counts.keys.toList()..sort();
    return keys.map((k) => '$k=${counts[k]}').join(', ');
  }

  /// يطبع الملخّص في وضع التطوير فقط.
  static void log([String tag = 'ApiMetrics']) {
    if (kDebugMode) debugPrint('$tag: ${summary()}');
  }
}
