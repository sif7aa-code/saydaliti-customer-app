import 'account_name.dart';

/// يعرض رقم الطلب التسلسلي بشكل موحّد: #1، #2، ...
///
/// يفضّل `serial_number` (تسلسل قاعدة البيانات) وعند غيابه يعود إلى
/// `order_number` القديم، ومعه اسم الزبون والمندوب بأمان دون أخطاء.
class OrderDisplay {
  const OrderDisplay._();

  /// وسم الطلب المُرسل (مرجع داخلي فقط).
  /// الرقم التسلسلي الحقيقي (#1، #2) يأتي من تسلسل قاعدة البيانات.
  static String newOrderTag() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    return '#${ms.toRadixString(36).toUpperCase()}';
  }

  static String serial(Map<String, dynamic> order) {
    final raw = order['serial_number'];
    if (raw is num) return '#${raw.toInt()}';
    final s = raw?.toString().trim() ?? '';
    if (s.isNotEmpty && s != 'null') {
      if (int.tryParse(s) != null) return '#$s';
      return s.startsWith('#') ? s : '#$s';
    }
    final legacy = order['order_number']?.toString().trim() ?? '';
    if (legacy.isEmpty || legacy == 'null') return '#---';
    return legacy.startsWith('#') ? legacy : '#$legacy';
  }

  /// ★ اسم الزبون الحقيقي، فرقمه الثابت — لا «null» ولا لقب عام.
  ///
  ///   كان الفراغ يُعرض بكلمة «زبون»: خانتان في اللوحة تحملان الاسم
  ///   نفسه، فلا يعرف المندوب أي زبون هي. الرقم هو الهويّة الثابتة.
  static String customerName(Map<String, dynamic> order) {
    return AccountName.real(
      name: order['user_name'],
      phone: order['user_phone'],
    );
  }

  /// اسم المندوب المسند: يُعرض رقم الهاتف إن لم يوجد اسم.
  static String driverName(Map<String, dynamic> order) {
    final p = order['assigned_driver_phone']?.toString().trim() ?? '';
    if (p.isEmpty || p == 'null') return 'لم يُعيَّن بعد';
    return p;
  }

  /// ★ مبلغ كود الخصم المطبَّق على الطلب (0 إن لم يُطبَّق كود).
  ///
  /// ★ `coupon_discount` و`coupon_code` كانا **يُكتبان ولا يُقرآن**
  ///   إطلاقاً: البحث في `lib\` كان يعطي مواضع الكتابة في
  ///   `supabase_service` وحده. النتيجة: المندوب يطلب مبلغاً أقل من
  ///   مجموع الأصناف بلا تفسير، فيصير نزاع عند الباب.
  static double discount(Map<String, dynamic> order) {
    final v = order['coupon_discount'];
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  /// ★ نصّ كود الخصم، أو '' إن لم يُطبَّق.
  static String couponCode(Map<String, dynamic> order) {
    final c = order['coupon_code']?.toString().trim() ?? '';
    return (c.isEmpty || c == 'null') ? '' : c;
  }

  /// ★ السعر **بعد** الخصم = ما دفعه الزبون فعلاً.
  ///
  ///   هو `total_amount` المحفوظ في الصف نفسه: السلة تُرسل المبلغ
  ///   بعد طرح الكود (`cart_screen` ⇒ `finalTotal = الإجمالي − الخصم`)،
  ///   فالحفظ موجود سلفاً ولا يحتاج عموداً جديداً.
  static double priceAfterDiscount(Map<String, dynamic> order) =>
      _num(order['total_amount']);

  /// ★ السعر **قبل** الخصم، اشتقاقاً: المدفوع + مبلغ الكود المحفوظ.
  ///
  ///   ★ لماذا لا يُخزَّن رقماً ثانياً في القاعدة؟
  ///     عمودان لنفس الحقيقة = باب نزاع حين يختلفان (تسوية، تصفير
  ///     محفظة، تعديل أدمن). المبلغ المطبَّق محفوظ وحده في
  ///     `coupon_discount`، فجمعُه على المدفوع يعطي الأصلي بالضبط.
  ///     يشترط فقط أن يكون `coupon_discount` هو المطبَّق لا المعلن —
  ///     انظر `appliedDiscount` في `cart_screen`.
  static double priceBeforeDiscount(Map<String, dynamic> order) {
    final paid = priceAfterDiscount(order);
    final d = discount(order);
    return d <= 0 ? paid : paid + d;
  }

  static double _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  /// ★ هل لهذا الطلب كود خصم مطبَّق؟
  static bool hasDiscount(Map<String, dynamic> order) =>
      discount(order) > 0 || couponCode(order).isNotEmpty;

  /// ★ ملاحظة الخصم — نصٌّ واحد للزبون وآخر للمندوب.
  ///
  /// [showCode] للزبون فقط: اسم الكود ملكه (هو من نسخه)، أما
  /// المندوب فحاجته **المبلغ** لا الاسم، واسم الكود تفصيل تجاري
  /// بين الأدمن والزبون.
  ///
  /// ★ 2026-10-29 (طلب الأدمن): الجملة تبدأ بالنص الحرفي
  ///   «تم تطبيق كود خصم» في الحالتين، ثم يُذكَر اسم الكود للزبون
  ///   بعده — فلا يفقد الزبون اسمه، وتبقى الجملة التي طلبها ظاهرة
  ///   كما هي حرفياً.
  static String discountNote(
    Map<String, dynamic> order, {
    required bool showCode,
  }) {
    if (!hasDiscount(order)) return '';
    final code = couponCode(order);
    final amount = discount(order);
    final head = (showCode && code.isNotEmpty)
        ? 'تم تطبيق كود خصم $code'
        : 'تم تطبيق كود خصم';
    if (amount <= 0) return '$head على هذا الطلب';
    return '$head — خصم ${_money(amount)}';
  }

  /// مبلغ بفواصل الآلاف، بلا استيراد `CurrencyFormatter` تفادياً
  /// للتبعية الدائرية بين `utils` و`core`.
  static String _money(double v) {
    final s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
    return s.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(\D|$))'),
      (m) => '${m[1]},',
    );
  }
}
