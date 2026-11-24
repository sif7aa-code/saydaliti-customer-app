import '../core/utils/shop_status.dart';
import '../models/shop.dart';

/// ★ جدول أوقات الصيدليات في الذاكرة: رقم الصيدلية ← جدوله كما قرأناه من القاعدة.
///
///   لماذا خريطة وسطى؟ لأن السلة تُملأ من منتجات، والمنتج يحمل `shopId`
///   واسم الصيدلية فقط — لا وقته. بدون هذه الخريطة لا يستطيع `CartService`
///   أن يقرر وحده: الصفحات التي تمرّر `isStoreOpen: true` ثابتاً (شورتس،
///   البحث، تفاصيل منتج من قسم) كانت تضيف منتجات صيدليات مغلقة فعلاً.
///
///   الملء من `_shopFromRow` وحده (`real_data_service`)، وهي البوابة التي
///   يمر بها كل صيدلية يصل إلى شاشة زبون: فلا صفحة تنساه، ولا نسخة ثانية من
///   الجدول تعيش في مكان آخر.
///
///   ★ المجهول = لا منع: صيدليةاً لم يُقرأ سطره بعد لا نملك جدولاً له،
///   فرفضه كذبٌ على الزبون. المنع يبدأ حين يكون الجدول معروفاً.
class ShopHoursStore {
  ShopHoursStore._internal();

  static final ShopHoursStore instance = ShopHoursStore._internal();

  final Map<String, _ShopHours> _byShopId = <String, _ShopHours>{};

  int get length => _byShopId.length;

  void remember(Shop shop) {
    if (shop.id.isEmpty) return;
    _byShopId[shop.id] = _ShopHours(
      name: shop.name,
      workingHours: shop.workingHours,
      workingDays: shop.workingDays,
      manualOpen: shop.isOpen,
    );
  }

  void rememberAll(Iterable<Shop> shops) {
    for (final s in shops) {
      remember(s);
    }
  }

  /// حالة الصيدلية الآن (null إن لم يكن جدوله معروفاً بعد).
  ShopStatus? statusFor(String shopId, {DateTime? at}) {
    final h = _byShopId[shopId];
    if (h == null) return null;
    return shopStatusAt(
      workingHours: h.workingHours,
      workingDays: h.workingDays,
      manualOpen: h.manualOpen,
      at: at,
    );
  }

  /// ★ البوابة: هل يُسمح بالإضافة؟ المجهول مسموح (انظر أعلى الملف).
  bool isOpenNow(String shopId, {DateTime? at}) {
    final status = statusFor(shopId, at: at);
    if (status == null) return true;
    return status.isOpen;
  }

  /// رسالة المنع الجاهزة للعرض، أو null حين الإضافة مسموحة.
  ///
  ///   [fallbackName] اسم المنتج/الصيدلية من صف المنتج حين لم يكن الجدول
  ///   محفوظاً بعد؛ لا يُترك الزبون أمام «الصيدلية» بلا اسم.
  String? blockMessageFor(String shopId, {String? fallbackName, DateTime? at}) {
    final h = _byShopId[shopId];
    final status = statusFor(shopId, at: at);
    if (status == null || status.isOpen) return null;
    return status.blockMessage(h?.name ?? fallbackName ?? '');
  }

  /// للاختبارات فقط: لا يبقى جدول اختبار في ذاكرة الذي بعده.
  void clear() => _byShopId.clear();
}

class _ShopHours {
  const _ShopHours({
    required this.name,
    required this.workingHours,
    required this.workingDays,
    required this.manualOpen,
  });

  final String name;
  final String workingHours;
  final String workingDays;
  final bool manualOpen;
}
