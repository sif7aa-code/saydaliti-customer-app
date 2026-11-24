/// ★ حالة الصيدلية محسوبة من الوقت الحقيقي — لا من مفتاح «مفتوح دائماً».
///
///   المشروع كان يقرأ `shops.is_open` كما هي، فيبقى أي صيدلية مفتوحاً إلى أن
///   يضغط الأدمن مفتاحه بنفسه: الأدمن يضبط «٩:٠٠ – ٢٣:٠٠» ويحفظ، فيُقال
///   «حُفظت أوقات العمل» بينما الساعة لا يُنظر إليها في أي مكان.
///
///   هنا صار الوقت هو القرار: `working_hours` (نص «HH:mm - HH:mm» الذي تكتبه
///   شاشة الأدمن) + `working_days` تُقارَن بالساعة الآن. وأما `is_open`
///   فبقي **إيقافاً يدوياً** فوق الجدول: إيقاف = مغلق مهما قال الوقت،
///   وتشغيل = لا يتدخل (الوقت هو الذي يقرر).
///
///   قواعد ثابتة لا تستثنى:
///   • نافذة تعبر منتصف الليل (٢٢:٠٠ – ٠٣:٠٠) مفتوحة في الطَرَفين.
///   • «٢٤ ساعة» = مفتوح طوال اليوم — وهذا مسموح لأنه قرار الأدمن الصريح،
///     لا نتيجة غياب الفحص.
///   • نص وقت لا يُفهم (صيدلية قديم بلا أوقات) = لا تقييد زمني، فالقرار
///     يرجع إلى `is_open` وحده. لا نختلق وقتاً لم يضبطه أحد.
library;

import 'shop_display.dart';

/// أسماء الأيام السبعة بترتيب `DateTime.weekday` (الاثنين = ١ … الأحد = ٧).
const List<String> _dayNames = <String>[
  'الاثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
  'السبت',
  'الأحد',
];

/// أرقام عربية (٠–٩) إلى أرقام عادية قبل أي تحليل.
final RegExp _arabicDigits = RegExp(r'[٠-٩]');

String _asciiDigits(String s) => s.replaceAllMapped(
  _arabicDigits,
  (m) => String.fromCharCode(
    0x30 + m[0]!.codeUnitAt(0) - 0x0660,
  ),
);

int? _weekdayByName(String name) {
  final n = name.replaceAll(' ', '').replaceAll('ال', '').trim();
  for (var i = 0; i < _dayNames.length; i++) {
    final clean = _dayNames[i].replaceAll('ال', '');
    if (n == clean || n == _dayNames[i]) return i + 1;
  }
  return null;
}

/// سبب الإغلاق — حتى تقول الرسالة الزبون السبب الصحيح لا «مغلق» وحدها.
enum ShopClosedReason {
  /// الأدمن أوقف الصيدلية يدوياً (`is_open = false`).
  manual,

  /// داخل يوم عمل لكن قبل ساعة الفتح.
  beforeOpening,

  /// داخل يوم عمل لكن بعد ساعة الإغلاق.
  afterClosing,

  /// اليوم نفسه عطلة في جدول الأيام.
  holiday,
}

class ShopSchedule {
  const ShopSchedule({
    required this.manualOpen,
    required this.hoursKnown,
    required this.allDay,
    required this.openMinutes,
    required this.closeMinutes,
    required this.openDays,
    required this.hoursText,
    required this.daysText,
  });

  /// «مفتوح طوال اليوم» ليست خياراً في الواجهة، بل نصاً يفهمه المحلّل
  /// («٢٤ ساعة»). أما أي نص لا يُفهم فيترك القرار للإدارة وحدها.
  ///   (صيدليات قديمة أُنشئت قبل شاشة الأوقات، و`real_data_service` تضع
  ///   «يومياً» في خانة `working_hours` نفسها عند غياب العمود.)

  /// هل أوقفها الأدمن يدوياً؟ (تشغيل = لا يتدخل، والوقت يقرر)
  final bool manualOpen;

  /// هل فُهم نص الوقت؟ بلا هذا لا يوجد تقييد زمني إطلاقاً.
  final bool hoursKnown;

  /// «٢٤ ساعة» صريحة من الأدمن.
  final bool allDay;

  final int openMinutes;
  final int closeMinutes;

  /// أيام العمل (قيم `DateTime.weekday`)، والمجموعة الكاملة = كل الأيام.
  final Set<int> openDays;

  final String hoursText;
  final String daysText;

  static const Set<int> _everyDay = <int>{1, 2, 3, 4, 5, 6, 7};

  /// منتصف الليل لا يُعتبر «صفر» يوم: النافذة التي تعبره تبدأ من يوم الفتح.
  bool get spansMidnight =>
      hoursKnown && !allDay && closeMinutes <= openMinutes;

  /// هل اليوم يوم عمل؟
  bool worksOn(int weekday) => openDays.contains(weekday);

  factory ShopSchedule.parse({
    required String workingHours,
    required String workingDays,
    required bool manualOpen,
  }) {
    final raw = _asciiDigits(workingHours).trim();

    // «٢٤ ساعة» — قرار صريح بالبقاء مفتوحاً طوال اليوم.
    if (raw.contains('24') && raw.contains('ساع')) {
      return ShopSchedule(
        manualOpen: manualOpen,
        hoursKnown: true,
        allDay: true,
        openMinutes: 0,
        closeMinutes: 0,
        openDays: _everyDay,
        hoursText: workingHours,
        daysText: workingDays,
      );
    }

    final sides = raw.split(RegExp(r'\s*[–—-]\s*|\s+-\s+'));
    final open = sides.isNotEmpty ? _parseClock(sides[0]) : null;
    final close = sides.length > 1 ? _parseClock(sides[1]) : null;

    return ShopSchedule(
      manualOpen: manualOpen,
      hoursKnown: open != null && close != null,
      allDay: false,
      openMinutes: open ?? 0,
      closeMinutes: close ?? 0,
      openDays: _parseDays(workingDays),
      hoursText: workingHours,
      daysText: workingDays,
    );
  }

  /// «09:00» / «9 ص» / «09:00 م» / «12:30 ص» → دقائق من منتصف الليل.
  static int? _parseClock(String side) {
    final s = side.trim();
    final m = RegExp(r'^(\d{1,2})\s*[:\u066A]\s*(\d{2})?').firstMatch(s);
    if (m == null) return null;
    var hour = int.tryParse(m.group(1)!) ?? -1;
    final minute = int.tryParse(m.group(2) ?? '00') ?? 0;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

    final pm = s.contains('م') || s.toLowerCase().contains('pm');
    final am = s.contains('ص') || s.toLowerCase().contains('am');
    if (pm && !am) {
      if (hour < 12) hour += 12;
    } else if (am && !pm) {
      if (hour == 12) hour = 0;
    }
    // بلا «ص/م» الرقم يبقى كما هو: «13:00» صيغة أربع وعشرين ساعة.
    return hour * 60 + minute;
  }

  /// «يومياً» / «السبت - الخميس» / «الجمعة فقط» / قائمة أيام بفواصل.
  static Set<int> _parseDays(String days) {
    final s = _asciiDigits(days).trim();
    if (s.isEmpty || s.contains('يوميا') || s.contains('يومياً')) {
      return _everyDay;
    }
    if (s.contains('كل الأيام') || s.contains('الاسبوع كله')) {
      return _everyDay;
    }

    // «عطلة أسبوعية» بلا يوم محدد: لا نختلق يوم إغلاق لا نعرفه،
    // فيبقى القرار للساعات وحدها (كل الأيام).
    if (s.contains('عطلة') && _weekdayByName(s) == null) return _everyDay;

    // «الجمعة فقط» ونظائرها: يوم واحد بعينه.
    if (s.contains('فقط')) {
      final only = _weekdayByName(s.replaceAll('فقط', ''));
      if (only != null) return <int>{only};
    }

    // «السبت - الخميس»: مدى يشمل الطرفين ويدور على نهاية الأسبوع.
    final range = RegExp(r'^(.*?)[–—-](.*)$').firstMatch(s);
    if (range != null) {
      final from = _weekdayByName(range.group(1)!);
      final to = _weekdayByName(range.group(2)!);
      if (from != null && to != null) {
        final out = <int>{};
        var cur = from;
        for (var i = 0; i < 7; i++) {
          out.add(cur);
          if (cur == to) break;
          cur = cur == 7 ? 1 : cur + 1;
        }
        return out;
      }
    }

    // قائمة أيام: «السبت، الأحد» / «السبت,الأحد»
    final parts = s.split(RegExp(r'[،,;/]'));
    final listed = <int>{};
    for (final p in parts) {
      final w = _weekdayByName(p);
      if (w != null) listed.add(w);
    }
    return listed.isEmpty ? _everyDay : listed;
  }
}

class ShopStatus {
  const ShopStatus({
    required this.isOpen,
    required this.schedule,
    required this.at,
    this.opensAt,
    this.closesAt,
    this.reason,
  });

  final bool isOpen;
  final ShopSchedule schedule;

  /// اللحظة التي حُسبت منها الحالة (تُحفظ لعرض «بعد كم»).
  final DateTime at;

  /// متى يفتح القادم — null حين لا يوجد إغلاق أو الإيقاف يدوي.
  final DateTime? opensAt;

  /// متى يغلق اليوم — null حين الصيدلية مغلقة أو مفتوح طوال اليوم.
  final DateTime? closesAt;

  /// سبب الإغلاق (null = مفتوح).
  final ShopClosedReason? reason;

  bool get isManualClosed => reason == ShopClosedReason.manual;

  /// ★ سطر نافذة العمل للعرض: الوقت محسوب من الجدول لا نصُّ القاعدة الخام.
  ///   مفتوحاً «09:00 ص – 11:00 م» (مع الأيام إن لم تكن كلها)، ومغلقاً
  ///   الحالة مع موعد الفتح القادم. يفهمه الزبون بينما «يومياً» في خانة
  ///   الساعة لا معنى له.
  String get windowLine {
    if (!isOpen) return stateLine;
    if (schedule.allDay) return 'مفتوح طوال اليوم';
    // لا تقييد زمنياً مضبوطاً: نعرض ما كتبه الأدمن ولا نختلق نافذة.
    if (!schedule.hoursKnown) {
      final raw = schedule.hoursText.trim();
      return raw.isEmpty ? 'مفتوح الآن' : raw;
    }
    final window =
        '${formatClock(schedule.openMinutes)} – '
        '${formatClock(schedule.closeMinutes)}';
    return schedule.openDays.length == 7
        ? window
        : '$window • ${schedule.daysText}';
  }

  /// ★ سطر قصير للبطاقات: «مفتوح • يغلق 11:00 م» / «مغلق • يفتح غداً 09:00 ص»
  String get stateLine {
    if (isOpen) {
      if (schedule.allDay) return 'مفتوح • طوال اليوم';
      final c = closesAt;
      if (c == null) return 'مفتوح';
      return 'مفتوح • يغلق ${formatClock(_minutesOf(c))}';
    }
    if (isManualClosed) return 'مغلق • موقوف يدوياً';
    final o = opensAt;
    if (o == null) return 'مغلق';
    return 'مغلق • يفتح ${_dayWord(o)} ${formatClock(_minutesOf(o))}';
  }

  /// ★ رسالة المنع التي يراها الزبون عند الضغط على «أضف إلى السلة»:
  ///   السبب + متى يفتح فعلاً، لا «مغلق» مبهمة.
  String blockMessage(String shopName) {
    final shop = _shopName(shopName);
    if (isManualClosed) {
      return '$shop موقوف حالياً بإرادته، فلا يمكن إضافة منتجاته للسلة';
    }
    final o = opensAt;
    if (o == null) {
      return '$shop مغلق حالياً ولا يمكن إضافة منتجاته للسلة';
    }
    final when = '${_dayWord(o)} ${formatClock(_minutesOf(o))}';
    return '$shop مغلق الآن — يفتح $when (${_gap(at, o)})';
  }

  /// سطر العدّ الحقيقي: «يفتح بعد ساعتين و١٥ دقيقة» / «يغلق بعد ٤٠ دقيقة».
  String countdownLine() {
    if (isOpen) {
      final c = closesAt;
      if (c == null || schedule.allDay) return 'مفتوح طوال اليوم';
      return 'مفتوح الآن • يغلق بعد ${_gap(at, c)}';
    }
    final o = opensAt;
    if (isManualClosed) return 'مغلق الآن • موقوف يدوياً';
    if (o == null) return 'مغلق الآن';
    return 'مغلق الآن • يفتح بعد ${_gap(at, o)}';
  }

  static String _shopName(String name) => shopDisplayName(name);

  static int _minutesOf(DateTime d) => d.hour * 60 + d.minute;

  /// «اليوم» / «غداً» / «بعد يومين» / اسم اليوم — محسوباً من [at] لا من
  /// ساعة الجهاز، حتى تبقى الاختبارات ثابتة على لحظة واحدة.
  String _dayWord(DateTime day) {
    final today = _dateOnly(at);
    final target = _dateOnly(day);
    final diff = target.difference(today).inDays;
    if (diff <= 0) return 'اليوم';
    if (diff == 1) return 'غداً';
    if (diff == 2) return 'بعد يومين';
    return _dayNames[day.weekday - 1];
  }

  /// مدة عربية مقروءة بين لحظتين (بالدقيقة، بلا ثوانٍ تتحرك في النص).
  static String _gap(DateTime from, DateTime to) {
    var minutes = to.difference(from).inMinutes;
    if (minutes < 1) return 'دقيقة واحدة';
    final hours = minutes ~/ 60;
    minutes = minutes % 60;
    final parts = <String>[];
    if (hours > 0) parts.add(_countWord(hours, 'ساعة', 'ساعتان', 'ساعات'));
    if (minutes > 0) parts.add(_countWord(minutes, 'دقيقة', 'دقيقتان', 'دقائق'));
    if (parts.isEmpty) return 'دقيقة واحدة';
    return parts.join(' و');
  }

  /// واحد/اثنان/٣-١٠/١١+ — صيغ العدّ العربية المعتادة.
  static String _countWord(int n, String one, String two, String few) {
    if (n == 1) return one;
    if (n == 2) return two;
    if (n >= 3 && n <= 10) return '$n $few';
    return '$n $one';
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}

/// «09:00 ص» من دقائق اليوم — صيغة واحدة في كل التطبيق.
String formatClock(int minutes) {
  final m = minutes % 1440;
  final h24 = m ~/ 60;
  final mm = m % 60;
  final period = h24 < 12 ? 'ص' : 'م';
  var h12 = h24 % 12;
  if (h12 == 0) h12 = 12;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(h12)}:${two(mm)} $period';
}

/// ★ الحساب الوحيد: أين يقف الصيدلية الآن من جدوله؟
///
///   [workingHours]/[workingDays] كما خزّنتهما شاشة الأدمن،
///   [manualOpen] = عمود `is_open` (إيقاف يدوي فوق الجدول).
///   [at] تُمرَّر في الاختبارات؛ في التطبيق هي ساعة الهاتف.
ShopStatus shopStatusAt({
  required String workingHours,
  String workingDays = 'يومياً',
  bool manualOpen = true,
  DateTime? at,
}) {
  final now = at ?? DateTime.now();
  final schedule = ShopSchedule.parse(
    workingHours: workingHours,
    workingDays: workingDays,
    manualOpen: manualOpen,
  );

  ShopStatus open(ShopSchedule s) =>
      ShopStatus(isOpen: true, schedule: s, at: now, closesAt: _closesAt(s, now));

  if (!schedule.manualOpen) {
    return ShopStatus(
      isOpen: false,
      schedule: schedule,
      at: now,
      reason: ShopClosedReason.manual,
    );
  }

  // بلا وقت مفهوم: لا نُغلق صيدليةً لم يضبط أحدٌ جدولاً له.
  if (!schedule.hoursKnown) return open(schedule);
  if (schedule.allDay) return open(schedule);

  final minutes = now.hour * 60 + now.minute;
  final weekday = now.weekday;

  final inTodayWindow =
      schedule.worksOn(weekday) && _inWindow(schedule, minutes);
  if (inTodayWindow) return open(schedule);

  // النافذة التي عبرت منتصف الليل: فتحت أمس وما زالت مستمرة.
  if (schedule.spansMidnight && minutes < schedule.closeMinutes) {
    final yesterday = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 1));
    if (schedule.worksOn(yesterday.weekday)) return open(schedule);
  }

  ShopClosedReason reason;
  if (!schedule.worksOn(weekday)) {
    reason = ShopClosedReason.holiday;
  } else if (minutes < schedule.openMinutes) {
    reason = ShopClosedReason.beforeOpening;
  } else {
    reason = ShopClosedReason.afterClosing;
  }

  return ShopStatus(
    isOpen: false,
    schedule: schedule,
    at: now,
    reason: reason,
    opensAt: _nextOpening(schedule, now),
  );
}

bool _inWindow(ShopSchedule s, int minutes) {
  if (s.spansMidnight) {
    return minutes >= s.openMinutes || minutes < s.closeMinutes;
  }
  return minutes >= s.openMinutes && minutes < s.closeMinutes;
}

/// نهاية نافذة الفتح الجارية (null حين الصيدلية مفتوح طوال اليوم).
DateTime? _closesAt(ShopSchedule s, DateTime now) {
  if (!s.hoursKnown || s.allDay) return null;
  final midnight = DateTime(now.year, now.month, now.day);
  final minutes = now.hour * 60 + now.minute;
  final closeH = s.closeMinutes ~/ 60;
  final closeM = s.closeMinutes % 60;

  if (s.spansMidnight) {
    // بعد ساعة الفتح → الإغلاق صبيحة الغد؛ وقبلها (استمرار بالليل) → اليوم.
    if (minutes >= s.openMinutes) {
      return midnight
          .add(const Duration(days: 1))
          .copyWith(hour: closeH, minute: closeM);
    }
    return midnight.copyWith(hour: closeH, minute: closeM);
  }
  return midnight.copyWith(hour: closeH, minute: closeM);
}

/// أول لحظة فتح قادمة ضمن أيام العمل (حتى ثمانية أيام قُدُماً).
DateTime? _nextOpening(ShopSchedule s, DateTime now) {
  if (!s.hoursKnown || s.allDay) return null;
  final midnight = DateTime(now.year, now.month, now.day);
  final openH = s.openMinutes ~/ 60;
  final openM = s.openMinutes % 60;
  for (var i = 0; i <= 8; i++) {
    final day = midnight.add(Duration(days: i));
    if (!s.worksOn(day.weekday)) continue;
    final start = day.copyWith(hour: openH, minute: openM);
    if (start.isAfter(now)) return start;
  }
  return null;
}
