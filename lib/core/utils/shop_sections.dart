import '../../models/category_item.dart';
import '../../models/product.dart';

/// ★ أقسام الصيدلية الواحد — مصدر القاعدة الوحيد.
///
/// القسم «عام» (`categories.shop_id` فارغ) يظهر في كل المنصات، والقسم
/// «قسم صيدلية» (`categories.shop_id` = معرّف الصيدلية) هو الرف الداخلي لذلك
/// الصيدلية: «حلويات» و«كيك» و«مشروبات» داخل صفحة حلويات واحدة.
///
/// لا عمود جديد في القاعدة ولا جدول جديد: الفرق بين القسمين هو عمود موجود
/// أصلاً (`categories.shop_id`)، والمنتج يُنقل بكتابة `category_id` وحده.
abstract final class ShopSections {
  /// مفتاح [groupProducts] لمنتج لا موضع له في أي شريحة معروضة.
  static const String unplacedId = 'unplaced';

  /// عنوان الشريحة الأخيرة؛ تظهر وحدها إن وُجد منتج بلا قسم في صيدلية له أقسام.
  static const String unplacedLabel = 'بدون قسم';

  /// أقسام هذه الصيدلية الخاصة، بنفس ترتيب قائمة الأقسام (وهي مرتّبة أصلاً
  /// `sort_order` ثم الأقدم) فلا تُرتَّب هنا مرتين.
  ///
  /// قسم بلا معرّف أو «المزيد» لا يُعرض: شريحة لا تفتح على شيء يظنّها الزبون
  /// عطلاً في الصيدلية.
  static List<CategoryItem> ofShop(
    List<CategoryItem> categories,
    String shopId,
  ) {
    if (shopId.isEmpty) return const [];
    return [
      for (final c in categories)
        if ((c.shopId ?? '').trim() == shopId &&
            c.id.isNotEmpty &&
            c.id != 'more')
          c,
    ];
  }

  /// القسم الذي يستقبل منتجات الصيدلية التي لم يسندها الأدمن إلى قسم: قسم
  /// الصيدلية نفسه (`shops.category_id`) ما دام واحداً من شرائح الصفحة، وإلا
  /// null فيُعرض «بدون قسم».
  ///
  /// لا تُختار أول شريحة بالنيابة عنه: ترتيب الأقسام قرره الأدمن، فجعله
  /// مصباً لكل غير المُصنَّف يعني شريحة تحمل ما لا يشبهها.
  static String? headId({
    required String? shopCategoryId,
    required List<CategoryItem> sections,
  }) {
    final own = (shopCategoryId ?? '').trim();
    if (own.isEmpty || own == 'null') return null;
    return sections.any((c) => c.id == own) ? own : null;
  }

  /// توزيع منتجات صيدلية واحدة على شرائح صفحته.
  ///
  ///  1) منتج أسنده الأدمن إلى قسم من أقسام صيدليته ⇒ في ذلك القسم.
  ///  2) وكل منتج آخر ⇒ [headId] إن كان، وإلا «بدون قسم» [unplacedId].
  ///
  /// لا يُسقط شيء: الشريحة تُبنى من هذه الخريطة، و«الكل» في الشاشة يبنيها من
  /// قائمة المنتجات كاملة لا منها.
  ///
  /// بلا أقسام ⇒ خريطة فارغة، فتبقى صفحة الصيدلية كما هي اليوم بالضبط: لا شريط
  /// شرائح ولا فلترة. أما الأقسام الفارغة فتبقى في الخريطة بقائمة فارغة،
  /// فإضافة الأدمن لها تُرى ولا تُخبأ.
  static Map<String, List<Product>> groupProducts({
    required List<Product> products,
    required List<CategoryItem> sections,
    required String? shopCategoryId,
  }) {
    if (sections.isEmpty) return const {};
    final owned = <String>{for (final c in sections) c.id};
    final head = headId(shopCategoryId: shopCategoryId, sections: sections);
    final grouped = <String, List<Product>>{
      for (final c in sections) c.id: <Product>[],
    };
    for (final p in products) {
      final direct = (p.categoryId ?? '').trim();
      final target = owned.contains(direct) ? direct : (head ?? unplacedId);
      grouped.putIfAbsent(target, () => <Product>[]).add(p);
    }
    return grouped;
  }
}
