/// منطق «تغيير اسم الصيدلية» من لوحة الأدمن — دوال صرفة بلا شبكة ولا ويجت.
///
/// ★ لماذا ملف مستقل؟ لأن الاسم في القاعدة **أربع نسخ** (`shops.name`،
///   `products.shop_name`، `order_items.shop_name`، `shop_earnings.shop_name`)،
///   والتعديل الآمن كله يحدث في دالة `admin_rename_shop` (انظر
///   `SQL_ADMIN_RENAME_SHOP.sql`). دور التطبيق أن يمنع الاسم الفارغ
///   والمكرر قبل الإرسال، ثم يفسّر ردّ الدالة بالعربية — وهذا التفسير
///   يقيم هنا ليُختبَر بلا شبكة.
class ShopRename {
  const ShopRename._();

  /// الحد الأقصى لحقل «اسم الصيدلية» — نفس قيمة `maxLength` عند إنشاء الصيدلية.
  static const int maxNameLength = 30;

  /// مفتاح عدّاد سطور الطلبات في ردّ الدالة — حرفياً كما تعيده القاعدة.
  static const String orderItemsKey = 'order_items';

  /// تنظيف الاسم: طرفان محذوفان ومسافات متكررة مضغوطة.
  ///
  /// تُستعمل **قبل** الإرسال و**قبل** المقارنة بالاسم الحالي. القاعدة تضغط
  /// المسافات هي الأخرى، لكن المقارنة ههنا هي التي تمنع نداءً فارغاً:
  /// «محل دوا» و«محل  دوا » اسم واحد، فلا يجوز أن يخرج الأدمن برسالة
  /// «تم التغيير» وهو لم يتغيّر شيء.
  static String clean(String raw) => raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// `null` = الاسم صالح للإرسال، وإلا رسالة عربية تُعرض فوراً.
  static String? validate(String proposed, {required String current}) {
    final name = clean(proposed);
    if (name.isEmpty) return 'اكتب اسم الصيدلية أولاً';
    if (name.length > maxNameLength) {
      return 'الاسم طويل — الحد $maxNameLength حرفاً';
    }
    if (name == clean(current)) return 'الاسم كما هو، لم يتغيّر';
    return null;
  }

  /// هل الاسم نفسه حرفياً؟ (لإخفاء زر «حفظ» وتقليل النداءات الفارغة)
  static bool isSameAsCurrent(String proposed, String current) =>
      clean(proposed) == clean(current);

  /// سطر النجاح — **يقول الحصيلة** كما هي في ردّ الدالة: كم منتجاً
  /// وكم سطراً وكم قسماً تبعت الاسم الجديد.
  static String resultLine(
    Map<String, dynamic> res, {
    required String oldName,
  }) {
    final name = (res['name'] ?? '').toString();
    final parts = <String>['من «$oldName» إلى «$name»'];
    final products = _int(res, 'products');
    final items = _int(res, orderItemsKey);
    final sections = _int(res, 'sections');
    if (products > 0) parts.add('$products منتجاً');
    if (items > 0) parts.add('$items سطر طلب');
    if (sections > 0) parts.add('$sections قسم');
    if (items == 0 && products == 0 && sections == 0) {
      parts.add('لا سطور ولا منتجات له');
    }
    return 'تم تغيير الاسم — ${parts.join(' · ')}';
  }

  /// رسالة الفشل بالعربية من رمز الدالة (أو من HTTP عند تعذّر الاتصال).
  static String failureLine(Map<String, dynamic> res) {
    final code = (res['error'] ?? '').toString();
    switch (code) {
      case 'NOT_ADMIN':
      case 'NO_SESSION':
      case 'FORBIDDEN':
      case 'NOT_DRIVER':
        return 'هذه العملية من داخل اللوحة وبعد الدخول بحساب أدمن';
      case 'DUP_NAME':
        final by = (res['taken_by'] ?? '').toString();
        return by.isEmpty
            ? 'هذا الاسم لصيدلية أخرى — اختر اسماً مختلفاً'
            : 'هذا الاسم لصيدلية أخرى («$by») — اختر اسماً مختلفاً';
      case 'EMPTY_NAME':
        return 'اكتب اسماً غير فارغ';
      case 'TOO_LONG':
        return 'الاسم أطول من 60 حرفاً';
      case 'NOT_FOUND':
        return 'الصيدلية غير موجودة — حدّث قائمة الصيدليات';
      case 'BAD_ARGUMENT':
        return 'معرّف الصيدلية غير صالح';
      case 'HTTP_404':
        return 'دالة تغيير الاسم غير منصّبة بعد — شغّل SQL_ADMIN_RENAME_SHOP.sql';
      case 'EXCEPTION':
        return 'تعذّر الاتصال بالسيرفر';
      default:
        return code.isEmpty ? 'تعذر تغيير الاسم' : 'تعذر تغيير الاسم ($code)';
    }
  }

  static int _int(Map<String, dynamic> res, String key) =>
      (res[key] as num?)?.toInt() ?? 0;
}
