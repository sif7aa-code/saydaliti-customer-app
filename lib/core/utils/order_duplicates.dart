import 'order_display.dart';

/// ★ **كشف الطلب المكرر عند أكثر من مندوب** — للوحة الأدمن وحدها.
///
/// ## لماذا يُكتب هذا هنا ولا يُكتب في القاعدة؟
/// صفّ `orders` يحمل **مندوباً واحداً** في كل لحظة
/// (`assigned_driver_phone` + `accepted_at`)، و«إعادة فتح للتحويل»
/// (`reopenOrder`) يُمسح فيه المندوب والوقت معاً ليدخل الطلب على
/// المندوب التالي. فلا يوجد في القاعدة سجلّ «مَن استلم هذا الطلب عبر
/// التاريخ» — والمحاولة الوحيدة لإثبات ذلك من ملف SQL تعني جدولاً
/// جديداً وتريجرًا، وهو توسيع في القاعدة لم يطلبه الأدمن.
///
/// فالمكشوف هنا هو الحالة الحقيقية التي تحدث في المنصة: **نفس الطلب
/// يُرسَل مرّتين** (إعادة إرسال بعد رفض، أو ضغطة مزدوجة)، فيُستلم
/// نسختان عند **مندوبين مختلفين** ويُحاسبان مرتين — والمقياس:
/// نفس الزبون + نفس سلة المشتريات + داخل نافذة زمنية قصيرة.
///
/// ## بصمة الطلب (لماذا هذه الحقول بالذات؟)
/// `total_amount = subtotal + delivery_fee - coupon_discount` (يُبنى
/// كذلك في `cart_screen`). لذا تُستخرج **قيمة السلة نفسها**:
///     subtotal = total_amount + coupon_discount - delivery_fee
/// فتطابق النسختان حتى لو استعملت إحداهما كود خصم أو وُضعت إحداهما
/// بلا رسوم توصيل، ولا تتطابق سلتان مختلفتان فعلاً.
/// التدوير لأقرب دينار كامل (لا فاصلة عشرية) لأن الأرقام هنا صحيحة،
/// ولأن التطابق الحرفي يُفلت نسخة اختلفت بحساب جزء من دينار.
///
/// ## حدود الأمانة في الكشف
/// - طلبان **بالفعل** لهما نفس السلة في نفس النافذة (زبون يكرر طلبه
///   حقيقياً) سيظهران: لذلك النتيجة **تنبيه للمراجعة** لا إلغاء ولا
///   حجز، والمندوب الذي استلم ثانياً هو من يُسأل.
/// - النسخ القديمة التي تبدّل مندوبها قبل هذا الكشف لا تُرى (لا سجلّ).
/// - السلة الفارغة المبلغ (`total = 0`: طلبات المندوب الحر) تُتجاهل،
///   وإلا تكررّت كل طلباتها ببعضها بلا معنى.
class DuplicateReceipt {
  const DuplicateReceipt({
    required this.orderId,
    required this.serial,
    required this.driverPhone,
    required this.driverName,
    required this.receivedAt,
    required this.hasReceiptStamp,
    required this.status,
  });

  final String orderId;
  final String serial;
  final String driverPhone;

  /// اسم المندوب المسند، أو الرقم حين لا اسم.
  final String driverName;

  /// وقت الاستلام: `accepted_at` حين وُجد، وإلا `created_at`.
  final DateTime receivedAt;

  /// هل الوقت المستعمل هو استلام فعلي مسجَّل (وليس وقت الإنشاء)؟
  final bool hasReceiptStamp;

  final String status;
}

/// مجموعة سطور متطابقة: نفس الزبون، نفس السلة، داخل النافذة الزمنية،
/// و`receipts` مرتّبة من الأقدم إلى الأحدث — أولها هو **الأول استلاماً**.
class DuplicateGroup {
  const DuplicateGroup({
    required this.customerPhone,
    required this.customerName,
    required this.basketAmount,
    required this.receipts,
  });

  final String customerPhone;
  final String customerName;

  /// قيمة السلة (بدون خصم وبدون رسوم توصيل).
  final double basketAmount;

  final List<DuplicateReceipt> receipts;

  DuplicateReceipt get firstReceived => receipts.first;

  /// من الثاني فصاعداً — وهم المطلوب تحذير الأدمن منهم.
  List<DuplicateReceipt> get laterOnes => receipts.sublist(1);

  /// عدد المندوبين المختلفين الذين استلموا هذه السلة.
  int get driverCount => receipts
      .map((r) => r.driverPhone)
      .toSet()
      .where((p) => p.isNotEmpty)
      .length;
}

/// درجة الاستعجال في مجموعة مكرَّرة — للترتيب لا للعرض وحده.
///
/// ★ الأخطر ما **دُفع فيه فعلاً**: نسخة «مكتمل» تعني أن المندوب أوصل
///   وسلّم، فالتسوية بين المندوبين معلّقة على قرار الأدمن. ثم ما هو في
///   الطريق، ثم المقبولة، ثم المتبقّية بلا مستلِم أو المرفوضة/الملغاة.
enum DuplicateUrgency { settled, onTheWay, accepted, other }

class OrderDuplicates {
  const OrderDuplicates._();

  /// ★ النافذة: ما بعد ست ساعات يُعدّ طلباً جديداً لا تكراراً للسلّة.
  static const Duration window = Duration(hours: 6);

  /// أيّ الحالات تُثقل المجموعة: «أكملها» مندوبٌ أم «في الطريق» إليها.
  static DuplicateUrgency urgency(DuplicateGroup group) {
    var top = DuplicateUrgency.other;
    void raise(DuplicateUrgency candidate) {
      // مؤشر الأصغر أخطر: «مكتمل» (0) يهزم كل ما بعده.
      if (candidate.index < top.index) top = candidate;
    }

    for (final r in group.receipts) {
      if (r.status == 'delivered') return DuplicateUrgency.settled;
      if (r.status == 'delivering') raise(DuplicateUrgency.onTheWay);
      if (r.status == 'accepted') raise(DuplicateUrgency.accepted);
    }
    return top;
  }

  /// ★ ترتيب الأخطر أولاً: الاستعجال، ثم عدد النسخ، ثم الأحدث استلاماً.
  ///
  /// بلا ترتيب المجموعات متساويات الخطر تُقرأ كما جاءت من القاعدة،
  /// فيبدو اللوحة «مخربطة» وإن كانت البيانات سليمة.
  static List<DuplicateGroup> sortGroups(List<DuplicateGroup> groups) {
    final ordered = List<DuplicateGroup>.of(groups);
    ordered.sort((a, b) {
      final byUrgency = urgency(a).index - urgency(b).index;
      if (byUrgency != 0) return byUrgency;
      final byCount = b.receipts.length - a.receipts.length;
      if (byCount != 0) return byCount;
      return b.receipts.first.receivedAt.compareTo(a.receipts.first.receivedAt);
    });
    return List<DuplicateGroup>.unmodifiable(ordered);
  }

  static String _phone(Map<String, dynamic> o) =>
      '${o['user_phone'] ?? ''}'.trim();

  /// قيمة السلة: المجموع + الخصم المطبَّق - رسوم التوصيل.
  static double _basket(Map<String, dynamic> o) {
    final total = o['total_amount'] is num
        ? (o['total_amount'] as num).toDouble()
        : double.tryParse('${o['total_amount'] ?? ''}') ?? 0;
    final fee = o['delivery_fee'] is num
        ? (o['delivery_fee'] as num).toDouble()
        : double.tryParse('${o['delivery_fee'] ?? ''}') ?? 0;
    return total + OrderDisplay.discount(o) - fee;
  }

  static DateTime? _stamp(Map<String, dynamic> o, String key) {
    final raw = '${o[key] ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return null;
    return DateTime.tryParse(raw);
  }

  /// وقت الاستلام المعتمد، مع علمٍ إن كان مسجَّلاً فعلاً.
  static (DateTime, bool) _receivedAt(Map<String, dynamic> o) {
    final accepted = _stamp(o, 'accepted_at');
    if (accepted != null) return (accepted, true);
    final created =
        _stamp(o, 'created_at') ?? DateTime.fromMillisecondsSinceEpoch(0);
    return (created, false);
  }

  /// ★ الطلبات المكررة عند أكثر من مندوب، الأخطر أولاً ثم الأحدث.
  ///
  /// الترتيب من `sortGroups`: ما دُفع فيه ثمن فعلاً (مكتمل) مقدَّم، لأنه
  /// يحتاج تسوية فوراً؛ والمرفوض/الملغى في آخر القائمة.
  ///
  /// يُغذَّى بنفس قائمة `fetchAllOrders()` التي تقرأها الشاشة أصلاً،
  /// فلا نداء شبكة جديداً ولا انتظار إضافي.
  static List<DuplicateGroup> find(List<Map<String, dynamic>> orders) {
    final byCustomer = <String, List<Map<String, dynamic>>>{};
    for (final o in orders) {
      final phone = _phone(o);
      if (phone.isEmpty) continue;
      final basket = _basket(o);
      // سلة بلا مبلغ (طلبات المندوب الحر) أو سالبة = لا معنى للتطابق.
      if (basket <= 0) continue;
      // مفتاح التقريب: الزبون + سلة بنفس القيمة لأقرب دينار.
      final key = '$phone|${basket.round()}';
      byCustomer.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(o);
    }

    final groups = <DuplicateGroup>[];
    for (final entry in byCustomer.entries) {
      final rows = entry.value;
      if (rows.length < 2) continue;

      rows.sort((a, b) {
        final (ta, _) = _receivedAt(a);
        final (tb, _) = _receivedAt(b);
        return ta.compareTo(tb);
      });

      // قطع السلسلة عند كل فجوة أكبر من النافذة: ما بعدها طلب لاحق
      // حقيقي لا تكرار لحظي.
      var start = 0;
      for (var i = 1; i <= rows.length; i++) {
        final endsChain =
            i == rows.length || _gapOverWindow(rows[i - 1], rows[i]);
        if (!endsChain) continue;
        final chain = rows.sublist(start, i);
        start = i;
        final receipts = chain.map(_receipt).toList(growable: false);
        final distinctDrivers = receipts
            .map((r) => r.driverPhone)
            .where((p) => p.isNotEmpty)
            .toSet();
        // ★ الشرط المطلوب: مكررة **عند المندوبين** — يعني مندوبان
        //   مختلفان على الأقل استلماها. نسخة عند مندوب واحد أو نسخة
        //   لم تُستلم بعد لا تُنذر.
        if (distinctDrivers.length < 2) continue;
        groups.add(
          DuplicateGroup(
            customerPhone: _phone(chain.first),
            customerName: OrderDisplay.customerName(chain.first),
            basketAmount: _basket(chain.first),
            receipts: receipts,
          ),
        );
      }
    }

    return sortGroups(groups);
  }

  static bool _gapOverWindow(
    Map<String, dynamic> previous,
    Map<String, dynamic> next,
  ) {
    final (tp, _) = _receivedAt(previous);
    final (tn, _) = _receivedAt(next);
    return tn.difference(tp) > window;
  }

  static DuplicateReceipt _receipt(Map<String, dynamic> o) {
    final (at, stamped) = _receivedAt(o);
    final phone = '${o['assigned_driver_phone'] ?? ''}'.trim();
    return DuplicateReceipt(
      orderId: '${o['id'] ?? ''}'.trim(),
      serial: OrderDisplay.serial(o),
      driverPhone: phone,
      driverName: phone.isEmpty ? 'لم يُستلَم بعد' : OrderDisplay.driverName(o),
      receivedAt: at,
      hasReceiptStamp: stamped,
      status: '${o['status'] ?? ''}'.trim(),
    );
  }

  /// «٢٧/١٠ · ٣:٤٠ مساءً» — التاريخ مع الساعة حتى يُميَّز «الأول» بوضوح.
  static String stampLabel(DuplicateReceipt r) {
    final d = r.receivedAt.toLocal();
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    final h24 = d.hour;
    final h = h24 % 12 == 0 ? 12 : h24 % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final period = h24 < 12 ? 'صباحاً' : 'مساءً';
    final prefix = r.hasReceiptStamp ? 'استلام' : 'إنشاء';
    return '$prefix $day/$month · $h:$m $period';
  }
}
