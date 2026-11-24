/// ★ المال **المعلَّق** في محفظة المندوب — مصدر واحد للقراءة والعرض.
///
/// «معلَّق» هو خصم كود على طلب **قبَله** المندوب ولم يُسلَّمه بعد. القاعدة
/// تحسبه حيّاً من جدول الطلبات ولا تكتبه في الدفتر، والدفتر وحده هو المال
/// الثابت المستحق الدفع — فلو سُمِّي هذا المال «رصيداً» لقرأه كل مجمع في
/// القاعدة بلا تمييز وصار واجب الدفع قبل وصول الطلب للزبون.
///
/// لذلك تُقرأ من هنا دائماً بلفظين منفصلين:
///   · **ثابت** (رصيد / مستحق) — من الدفتر، ويُدفع.
///   · **معلَّق** — من الطلبات المقبولة، ويُثبَّت عند التسليم ولا يُدفع بعد.
///
/// `known` مضروبة لأن نسخة القاعدة القديمة لا تُرسل الحقول أصلاً: عرض
/// «معلَّق ٠» هناك يوحي بأنه لا عمل قائم، والحقيقة أن الخادم لم يُخبرنا.
/// فلا تُرسم أي كلمة عند `known == false` — السطر يختفي بلا كذب.
library;

import 'package:saydaliti/core/utils/currency_formatter.dart';

/// ★ محلّل ردّ المعلَّق: يقرأ الحقول كما هي، ويمنع الأخطاء الأربعة
///   المعروفة — الغائب يُقرأ «لا نعرف»، والسالب صفر، والنص الرقمي رقم،
///   وعدّاد البطاقة لا يُخلط بعدّاد المعلَّق.
class DriverWalletPending {
  const DriverWalletPending({
    required this.known,
    required this.amount,
    required this.orders,
    required this.rows,
  });

  /// بلا معلَّق: الحصيلة الثابتة وحدها مسموح بعرضها.
  static const DriverWalletPending none = DriverWalletPending(
    known: false,
    amount: 0,
    orders: 0,
    rows: <Map<String, dynamic>>[],
  );

  /// هل أرسل الخادم حقول المعلَّق في هذا الرد أصلاً؟
  final bool known;

  /// مجموع خصم الطلبات المقبولة غير المسلَّمة (دينار، بلا سالب).
  final double amount;

  /// عددها.
  final int orders;

  /// تفصيلها: `{order_label, coupon_code, amount, status_label, from_wheel, note}`.
  final List<Map<String, dynamic>> rows;

  /// فيه مال معلَّق فعلاً؟ السالب لا يُعرض ولو جاء من قاعدة مكسورة.
  bool get hasMoney => known && amount > 0;

  /// هل فيه سطور معلَّقة تُعرض؟ (قد يكون المبلغ صفراً وكود نسبته صفر).
  bool get hasRows => known && rows.isNotEmpty;

  /// ★ من ردّ الخادم مباشرة — بطاقة مندوب أو حافظة محفظة.
  ///
  /// يقبل `null` وخريطة ناقصة بلا استثناء: هذه القراءة تُجرى على ردود
  /// قد تكون من نسخة SQL قديمة، فالكسر هنا يعني شاشة فارغة للأدمن.
  factory DriverWalletPending.from(Map<String, dynamic>? m) {
    if (m == null) return none;
    final hasAmt = m.containsKey('pending_amount');
    final hasRowsKey = m.containsKey('pending_rows');
    final hasTotal = m.containsKey('total_pending');
    if (!hasAmt && !hasRowsKey && !hasTotal) return none;

    final raw = m['pending_rows'] ?? m['pending'];
    final list = raw is List
        ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];

    // العدّ: حقل المعلَّق نفسه، وإلا عدد السطور المرسلة. حقل `orders` في
    // البطاقة هو عدد طلبات **الدفتر** فلا يُخلط به أبداً.
    final count = _int(m['pending_orders']) ?? list.length;

    return DriverWalletPending(
      known: true,
      amount: _nonNeg(_num(m['pending_amount'] ?? m['total_pending'])),
      orders: count < 0 ? 0 : count,
      rows: list,
    );
  }

  /// صيغة العدد بالعربية: «طلب» / «طلبان» / «طلبات».
  String get ordersWord => orders == 1
      ? 'طلب'
      : orders == 2
      ? 'طلبان'
      : 'طلبات';

  /// سطر واحد مختصر للحصيلة العلوية: «معلَّق ٣٠٬٠٠٠ · طلبان».
  /// يُرجع `null` لو لا شيء يُقال — فيُتخطّى السطر في الواجهة.
  String? get totalsLabel {
    if (!known) return null;
    if (amount <= 0 && orders <= 0) return 'لا معلَّق الآن';
    return 'معلَّق ${CurrencyFormatter.format(amount)} · $orders $ordersWord';
  }

  /// ★ تفصيل سطر معلَّق واحد، مُجهَّز للعرض مباشرة.
  static PendingRow row(Map<String, dynamic> r) {
    final wheel =
        r['from_wheel'] == true ||
        '${r['kind'] ?? ''}'.contains('wheel') ||
        '${r['source'] ?? ''}'.contains('wheel');
    final code = '${r['coupon_code'] ?? ''}'.trim();
    return PendingRow(
      label: '${r['order_label'] ?? '—'}',
      code: code.isEmpty || code == '—' ? null : code,
      amount: _nonNeg(_num(r['amount'])),
      status: '${r['status_label'] ?? ''}'.trim(),
      fromWheel: wheel,
      note: '${r['note'] ?? ''}'.trim(),
    );
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}');
  }

  static double _nonNeg(double? v) {
    if (v == null) return 0;
    return v < 0 ? 0 : v;
  }

  static int? _int(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}');
  }
}

/// ★ سطر معلَّق واحد بعد تنظيفه — نفس الحقول في شاشة المندوب ولوحة الأدمن.
class PendingRow {
  const PendingRow({
    required this.label,
    required this.code,
    required this.amount,
    required this.status,
    required this.fromWheel,
    required this.note,
  });

  /// «#١٣» أو الوسم النصي، كما أرسلته القاعدة.
  final String label;

  /// كود الخصم، أو `null` لو لم يُرسل.
  final String? code;
  final double amount;

  /// «مقبول» / «قيد التوصيل» — من القاعدة، فلا نصّ في الواجهة.
  final String status;

  /// هل هو كود عجلة الحظ؟ تُعرَض به كلمة «عجلة».
  final bool fromWheel;

  /// ملاحظة القاعدة («يُضاف إلى رصيدك عند تسليم الطلب»).
  final String note;
}
