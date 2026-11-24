/// ★ وقت الطلب: «كم صارله» و«كم مضى عليه» — **مصدر واحد** للمندوب وللزبون.
///
/// لا تنسيق وقت للطلب مبعثراً في الشاشات: كانت بطاقة المندوب تعرض أوقات
/// الاستلام والتوصيل والاكتمال فقط، وشاشة تتبع الزبون تعرض تاريخ الإنشاء
/// كاملاً، فلا أحد منهما يعرف **كم مرّ** على الطلب. هذا الملف هو المكان
/// الوحيد الذي يُحسب فيه المرور، فيُستعمل من الطرفين بنصٍّ واحد.
///
/// القراران:
///   · الطلب **حيّ** (pending / accepted / delivering / rejected):
///     «منذ …» محسوب من `created_at` إلى الآن، ويتحرّك مع ساعة الواجهة.
///   · الطلب **مُسلَّم**: الوقت يتوقف عند `delivered_at` ويتغيّر لفظه
///     إلى «استغرق …» — فعدّاد حيّ بعد التسليم كذبٌ («منذ ٣ أيام» لطلب
///     وصل منذ ثلاث أيام ويوحي أنه متأخر).
///
/// لا `import 'package:flutter/…'` هنا: الصيغة دالة خالصة تُختبر بلا
/// واجهة، والويجت المتحرّك في `widgets/order_elapsed_text.dart`.
class OrderElapsed {
  const OrderElapsed._();

  /// كم مرة في الثانية تُعاد قراءة الساعة — نفس وتيرة الويجت.
  static const Duration tick = Duration(seconds: 30);

  /// لحظة إنشاء الطلب، أو `null` لو غابت أو فُسد النص.
  static DateTime? placedAt(Map<String, dynamic> order) =>
      _local(order['created_at']);

  /// لحظة التسليم، أو `null` ما لم يُسلَّم الطلب.
  static DateTime? deliveredAt(Map<String, dynamic> order) =>
      _local(order['delivered_at']);

  /// المدة نفسها، متوقفة عند التسليم إن كان. `null` = لا تاريخ إنشاء.
  static Duration? span(Map<String, dynamic> order, {DateTime? now}) {
    final start = placedAt(order);
    if (start == null) return null;
    final end = deliveredAt(order) ?? now ?? DateTime.now();
    if (end.isBefore(start)) return Duration.zero;
    return end.difference(start);
  }

  /// مدة بصيغة عربية صحيحة العدد: «دقيقتين»، «٧ ساعات»، «يومين»…
  /// بلا كلمة «منذ» حتى تُستعمل في «منذ …» وفي «استغرق …» معاً.
  static String passedLabel(Duration d) {
    final minutes = d.inMinutes;
    if (minutes < 1) return 'لحظة';
    if (minutes < 60) return _minutes(minutes);
    final hours = d.inHours;
    if (hours < 24) return _hours(hours);
    return _days(hours ~/ 24);
  }

  /// ★ المدة **بالساعة والدقيقة معاً**: «ساعتين و15 دقيقة».
  ///
  /// [passedLabel] تكتفي بالساعة («٣ ساعات») لأن سطر المندوب والزبون ضيّق.
  /// الأدمن في «مراقبة الطلبات» يقارن طلبات بعضّها بجانب بعض، فثلاثة طلبات
  /// «منذ ٣ ساعات» يفصل بينها ثلث ساعة وتبدو كنفس الوقت. فوق اليوم الواحد
  /// تُرجع الأيام مع بقيّة الساعات — «٢٤٠ ساعة» رقم لا يقرؤه أحد.
  static String passedPrecise(Duration d) {
    final total = d.inMinutes;
    if (total < 1) return 'لحظة';
    final hours = total ~/ 60;
    final minutes = total % 60;
    if (hours < 24) {
      if (hours == 0) return _minutes(minutes);
      if (minutes == 0) return _hours(hours);
      return '${_hours(hours)} و${_minutes(minutes)}';
    }
    final days = hours ~/ 24;
    final rest = hours % 24;
    if (rest == 0) return _days(days);
    return '${_days(days)} و${_hours(rest)}';
  }

  static String _hours(int h) {
    if (h == 1) return 'ساعة واحدة';
    if (h == 2) return 'ساعتين';
    if (h <= 10) return '$h ساعات';
    return '$h ساعة';
  }

  static String _minutes(int m) {
    if (m == 1) return 'دقيقة واحدة';
    if (m == 2) return 'دقيقتين';
    if (m <= 10) return '$m دقائق';
    return '$m دقيقة';
  }

  static String _days(int days) {
    if (days == 1) return 'يوم واحد';
    if (days == 2) return 'يومين';
    if (days <= 10) return '$days أيام';
    return '$days يوماً';
  }

  /// ★ النص المعروض للبطاقة والشاشة: «منذ …» أو «استغرق …».
  ///
  /// يُرجع '' لو لا وقت إنشاء: يُخفى السطر كله بدل شرطة لا تُخبر بشيء،
  /// ف«منذ» على تاريخ مجهول كذبٌ آخر.
  static String label(Map<String, dynamic> order, {DateTime? now}) {
    final s = span(order, now: now);
    if (s == null) return '';
    return '${head(order)} ${passedLabel(s)}';
  }

  /// [label] بالدقائق معها — للشاشة التي تقارن طلبات بجانب بعضها.
  static String labelPrecise(Map<String, dynamic> order, {DateTime? now}) {
    final s = span(order, now: now);
    if (s == null) return '';
    return '${head(order)} ${passedPrecise(s)}';
  }

  /// ★ بادئة [label]: «منذ» للحيّ، «استغرق» للمُسلَّم.
  static String head(Map<String, dynamic> order) =>
      deliveredAt(order) != null ? 'استغرق' : 'منذ';

  /// ★ تسمية السطر التي تناسب حالة الطلب: «كم مضى عليه» وهو ينتظر،
  ///   «مدة الطلب» وهو مُسلَّم — فلا تُكتب العبارة بمطابقة بادئة.
  static String counterLabel(Map<String, dynamic> order) =>
      deliveredAt(order) != null ? 'مدة الطلب' : 'كم مضى عليه';

  /// المدة وحدها بلا بادئة، أو '' لو لا وقت إنشاء.
  static String passed(Map<String, dynamic> order, {DateTime? now}) {
    final s = span(order, now: now);
    if (s == null) return '';
    return passedLabel(s);
  }

  /// ★ ساعة الطلب بصيغة واحدة لكل الشاشات: «3:20 مساءً».
  ///
  /// كانت `formatTime` معرّفة في شاشة المندوب وتستوردها شاشة الأدمن؛
  /// صارت هنا ليكون وقت الطلب ومضيه من مصدر واحد لا من ملف شاشة.
  /// تُرجع '—' للوقت الغائب أو المفسود، فلا يظهر 'null' للزبون.
  static String clock(Object? raw) {
    final dt = _local(raw);
    if (dt == null) return '—';
    final h24 = dt.hour;
    final h = h24 % 12 == 0 ? 12 : h24 % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${h24 < 12 ? 'صباحاً' : 'مساءً'}';
  }

  /// تاريخ UTC من القاعدة إلى توقيت الهاتف.
  static DateTime? _local(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    if (s.isEmpty || s == 'null') return null;
    final dt = DateTime.tryParse(s);
    if (dt == null) return null;
    // نص بلا منطقة زمن = يُفترض UTC (هذا ما ترسله Supabase غالباً).
    return dt.toLocal();
  }
}
