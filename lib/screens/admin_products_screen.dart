import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/shop_sections.dart';
import '../services/doctor_directory_service.dart';
import '../services/real_data_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/admin_image_uploader.dart';
import '../widgets/app_image.dart';
import '../widgets/shelf_chip.dart';
import 'admin_shops_screen.dart';

/// إدارة منتجات صيدلية معيّن: إضافة منتج بصورة من المعرض
/// (تُضغط وتُحفظ محلياً فقط لتقليل مساحة التخزين)، تفعيل/إطفاء، حذف.
class AdminProductsScreen extends StatefulWidget {
  const AdminProductsScreen({super.key, this.shopId});

  /// فارغ = كل الصيدليات.
  final String? shopId;

  @override
  State<AdminProductsScreen> createState() => _AdminProductsScreenState();
}

class _AdminProductsScreenState extends State<AdminProductsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _shops = [];
  List<Map<String, dynamic>> _categories = [];

  /// ★ أقسام الرئيسية (دليل الأقسام): تُعرض في ورقة النقل حتى ينقل
  ///   الأدمن منتجاً إلى قسمٍ يظهر في الرئيسية لا في صفحة الأدوية.
  List<DoctorCategory> _doctorCats = const [];

  /// ★ القسم الذي تُعرض منتجاته الآن؛ null = كل منتجات الصيدلية.
  String? _sectionFilter;

  /// وضع «كل الصيدليات»: الشاشة تُفتح من زر «الصيدليات» في اللوحة فتعرض
  /// منتجات الجميع مع اسم صيدلية كل منتج ونقلٍ مباشر إلى أقسام الرئيسية.
  bool get _allShops => (widget.shopId ?? '').trim().isEmpty;

  /// اسم صيدلية المنتج في وضع «كل الصيدليات».
  String _shopNameOf(Map<String, dynamic> p) {
    final direct = p['shop_name']?.toString().trim() ?? '';
    if (direct.isNotEmpty) return direct;
    final id = p['shop_id']?.toString() ?? '';
    for (final s in _shops) {
      if (s['id']?.toString() == id) {
        return s['name']?.toString() ?? 'صيدلية';
      }
    }
    return 'صيدلية';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait<Object>([
      SupabaseService.instance.fetchProducts(shopId: widget.shopId),
      SupabaseService.instance.fetchShops(),
      SupabaseService.instance.fetchCategories(),
      DoctorDirectoryService.instance.fetchCategories(force: true),
    ]);
    // تبقى شاشات التطبيق الأخرى منسجمة فوراً مع أي تعديل يتم هنا:
    // تُلغي الذاكرة الوسيطة فيعيد الجميع الجلب الطازج من قاعدة البيانات.
    //
    // `await` إجباري: بدونه كانت [_load] تقرأ من كاش لم يُلغَ بعد،
    // فيبقى المنتج الجديد مخفياً على شاشات المستخدمين. وكلمة `await`
    // وحدها لا تكفي لأن clearCache تحذف الكاش ولا تخبر الشاشات، فنُعلمها.
    await RealDataService.instance.clearCache();
    _bumpCatalog();
    if (!mounted) return;
    setState(() {
      _products = results[0] as List<Map<String, dynamic>>;
      _shops = results[1] as List<Map<String, dynamic>>;
      _categories = results[2] as List<Map<String, dynamic>>;
      _doctorCats = results[3] as List<DoctorCategory>;
      _loading = false;
    });
  }

  void _bumpCatalog() {
    final n = RealDataService.instance.catalogGeneration;
    n.value++;
  }

  /// الأقسام المتاحة لمنتج هذه الصيدلية.
  ///
  /// القاعدة: قسم خاص بصيدلية (`shop_id` = معرّف الصيدلية) أو قسم عام
  /// (`shop_id` فارغ). أي قسم يخصّ صيدليةً أخرى **لا يظهر**، ولا يصلح
  /// أن يُربط منتجنا به — وهذا ما كان يجعل المنتج يختفي من أقسامه.
  ///
  /// ★ استثناء مهم: القسم الذي هذه الصيدلية نفسه منتمٍ إليه
  ///   (`shops.category_id`) يظهر دائماً، فإلا لم يستطع الأدمن اختيار
  ///   القسم الجديد الذي أنشأه لهذه الصيدلية.
  List<Map<String, dynamic>> get _categoriesForThisShop {
    final shopId = widget.shopId;
    final own = _ownShopCategoryId;
    return _categories.where((c) {
      if (c['is_active'] == false) return false;
      if (shopId == null || shopId.isEmpty) return true; // كل الصيدليات
      if (c['id']?.toString() == own) return true;
      final owner = c['shop_id']?.toString().trim();
      if (owner == null || owner.isEmpty || owner == 'null') {
        return true; // قسم عام
      }
      return owner == shopId;
    }).toList();
  }

  /// معرّف القسم الذي ينتمي إليه هذه الصيدلية (`shops.category_id`).
  String? get _ownShopCategoryId {
    final shopId = widget.shopId;
    if (shopId == null || shopId.isEmpty) return null;
    for (final s in _shops) {
      if (s['id']?.toString() == shopId) {
        final cat = s['category_id']?.toString().trim();
        if (cat == null || cat.isEmpty || cat == 'null') return null;
        return cat;
      }
    }
    return null;
  }

  /// القسم الافتراضي: قسم الصيدلية نفسه أولاً (حتى لا يُربط منتجه
  /// بالقسم القديم)، ثم أول قسم عام، ثم null.
  String? get _defaultCategoryId {
    final list = _categoriesForThisShop;
    if (list.isEmpty) return null;
    final own = _ownShopCategoryId;
    if (own != null) {
      for (final c in list) {
        if (c['id']?.toString() == own) return own;
      }
    }
    if (list.length == 1) return list.first['id']?.toString();
    return list.first['id']?.toString();
  }

  /// ★ أقسام هذه الصيدلية الداخلية (`categories.shop_id` = معرّفه): وهي التي
  ///   تختارها شريحة الزبون داخل صفحة الصيدلية. قسم الصيدلية الرئيسي داخلها إذا
  ///   كان مربوطاً به في الاتجاهين، فيبقى «الوجه» رفّاً كبقية الرفوف.
  List<Map<String, dynamic>> get _shelvesOfThisShop {
    final shopId = (widget.shopId ?? '').trim();
    if (shopId.isEmpty) return const [];
    return _categories
        .where(
          (c) =>
              c['is_active'] != false &&
              (c['shop_id']?.toString().trim() ?? '') == shopId,
        )
        .toList(growable: false);
  }

  /// اسم القسم كما يراه الأدمن؛ null لمنتج بلا قسم.
  String? _categoryName(String? categoryId) {
    final id = (categoryId ?? '').trim();
    if (id.isEmpty || id == 'null') return null;
    for (final c in _categories) {
      if (c['id']?.toString() == id) {
        return c['name_ar']?.toString() ?? c['name_en']?.toString() ?? 'قسم';
      }
    }
    return null;
  }

  /// الرفّ الذي يستقبل منتجات الصيدلية التي لم تُصنَّف: قسم الصيدلية نفسه إذا
  /// كان واحداً من أقسامه — وهي نفس قاعدة شاشة الزبون في
  /// `ShopSections.headId`، فلا يختلف عدد الشريحة هنا عن عدد المنتجات التي
  /// يراها الزبون تحتها.
  String? get _headShelfId {
    final own = _ownShopCategoryId;
    if (own == null) return null;
    return _shelvesOfThisShop.any((c) => c['id']?.toString() == own)
        ? own
        : null;
  }

  /// رفّ صفّ منتج: قسمه إن كان من أقسام صيدليته، وإلا رأس الرف، وإلا
  /// «بدون قسم».
  String _shelfOfRow(Map<String, dynamic> p) {
    final direct = (p['category_id']?.toString() ?? '').trim();
    if (_shelvesOfThisShop.any((c) => c['id']?.toString() == direct)) {
      return direct;
    }
    return _headShelfId ?? ShopSections.unplacedId;
  }

  /// عدد منتجات رفّ كما يراهم الزبون.
  int _shelfCount(String shelfId) =>
      _products.where((p) => _shelfOfRow(p) == shelfId).length;

  /// القسم المختار فعلاً: إن حذف القسم والشاشة مفتوحة يعود العرض إلى كل
  /// المنتجات، فلا تُفسَّر القائمة الفارغة على أنها الصيدلية فارغ.
  String? get _shelfFilter {
    final id = _sectionFilter;
    if (id == null) return null;
    if (id == ShopSections.unplacedId) return id;
    return _shelvesOfThisShop.any((c) => c['id']?.toString() == id) ? id : null;
  }

  /// المنتجات المعروضة في القائمة بعد فلترة القسم. القسم بلا منتجات يبقى
  /// ظاهراً في الشرائح بعدد صفر، فلو اختفى القسم عند كل نقل ظهر للأدمن أن
  /// إضافته لم تُحفظ.
  List<Map<String, dynamic>> get _visibleProducts {
    final filter = _shelfFilter;
    if (filter == null) return _products;
    return _products
        .where((p) => _shelfOfRow(p) == filter)
        .toList(growable: false);
  }

  /// رسالة القائمة الفارغة: «الصيدلية بلا منتجات» غير «القسم بلا منتجات» —
  /// لو اتحدتا ظنّ الأدمن أن النقل حذف المنتج.
  String get _emptyListMessage {
    if (_products.isEmpty) {
      return _allShops
          ? 'لا توجد منتجات في أي صيدلية'
          : 'لا توجد منتجات لهذه الصيدلية';
    }
    return 'لا منتجات في هذا القسم · اضغط سطر القسم على أي بطاقة لنقل منتج إليه';
  }

  void _showMessage(String msg, bool ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? AppColors.success : AppColors.danger,
          // ★ 6 ثوانٍ: الرسالة صارت سطرين (نتيجة العملية + العدد الجديد).
          duration: const Duration(seconds: 6),
        ),
      );
  }

  /// ★ العدد الجديد بعد أي تغيير على المنتجات (إضافة/تعديل/إطفاء/حذف).
  ///
  /// يُقرأ من **الخادم بعد العملية**، ومن نفس مصدر عدّاد بطاقة
  /// «أصحاب الصيدليات»: منتجات هذه الصيدلية التي `is_active = true` — أي
  /// المعروضة للزبائن. فلو أُطفئ منتج نقص الرقم، ولو حُذف نقص، ولو أُضيف
  /// زاد؛ وهذا ما يجعل الرقمين (الرسالة والبطاقة) لا يتناقضان أبدًا.
  /// يُستعمل مع [_withCount] فقط عند نجاح العملية.
  Future<String> _freshActiveCount() async {
    try {
      final list = await SupabaseService.instance.fetchProducts(
        shopId: widget.shopId,
        activeOnly: true,
      );
      return '${list.length}';
    } catch (_) {
      return '؟';
    }
  }

  /// يلصق العدد الجديد في آخر رسالة نجاح.
  Future<String> _withCount(String msg) async {
    final scoped = (widget.shopId ?? '').trim().isNotEmpty;
    final label = scoped
        ? 'عدد منتجات الصيدلية المعروضة الآن'
        : 'عدد المنتجات المعروضة الآن في كل الصيدليات';
    return '$msg · $label ${await _freshActiveCount()}';
  }

  Future<void> _addProduct() async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final oldPriceCtrl = TextEditingController();
    final serialCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    // ★ حقيبة الصور المرفوعة في هذا النموذج: تُلغيها إذا أُلغي الحفظ.
    final uploads = AdminUploads();
    String? newImageUrl;
    var shopId = widget.shopId ?? '';
    String? shopName;
    var categoryId = _defaultCategoryId;
    // ★ يتطلب وصفة طبية: يمنع إرسال الطلب بلا صورة وصفة مرفقة.
    var requiresRx = false;

    final picked = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'إضافة منتج جديد',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                AdminImageUploader(
                  folder: 'products',
                  height: 130,
                  uploads: uploads,
                  placeholder:
                      'اضغط لاختيار صورة المنتج (تُرفع للسيرفر وتظهر للجميع)',
                  onChanged: (url) => newImageUrl = url,
                ),
                const SizedBox(height: 16),

                // قائمة الصيدليات المنسدلة: أي منتج يُنسَب لصيدليته نحن نختاره.
                DropdownButtonFormField<String>(
                  initialValue: shopId.isEmpty ? null : shopId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'الصيدلية',
                    prefixIcon: const Icon(Icons.storefront_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  items: [
                    for (final s in _shops)
                      DropdownMenuItem(
                        value: s['id']?.toString(),
                        child: Text(
                          s['name']?.toString() ?? 'صيدلية',
                          style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                  onChanged: (v) => setSheetState(() {
                    shopId = v ?? '';
                    shopName = null;
                  }),
                ),
                const SizedBox(height: 12),

                // قائمة الأقسام المنسدلة: نربط المنتج بقسمه للظهور في
                // أقسام الصفحة الرئيسية. لا نعرض إلا أقسام هذه الصيدلية
                // (أو العامة) حتى لا يُربط المنتج بقسم صيدلية آخر.
                DropdownButtonFormField<String?>(
                  initialValue:
                      _categoriesForThisShop.any(
                        (c) => c['id']?.toString() == categoryId,
                      )
                      ? categoryId
                      : _defaultCategoryId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'القسم *',
                    prefixIcon: const Icon(Icons.category_outlined, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  items: [
                    for (final c in _categoriesForThisShop)
                      DropdownMenuItem<String?>(
                        value: c['id']?.toString(),
                        child: Text(
                          c['name_ar']?.toString() ??
                              c['name_en']?.toString() ??
                              'قسم',
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                  // القسم إجباري: منتج بلا قسم لا يظهر ضمن أي قسم، وهو
                  // سبب «المنتج الجديد ما ظهر بالأقسام».
                  onChanged: _categoriesForThisShop.isEmpty
                      ? null
                      : (v) => setSheetState(() => categoryId = v),
                ),
                if (_categoriesForThisShop.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'لا يوجد قسم لهذه الصيدلية. أضف قسماً من «إدارة الأقسام» أولاً.',
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                TextField(
                  controller: nameCtrl,
                  textAlign: TextAlign.right,
                  maxLength: 30,
                  decoration: InputDecoration(
                    labelText: 'اسم المنتج',
                    prefixIcon: const Icon(
                      Icons.shopping_bag_outlined,
                      size: 20,
                    ),
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: priceCtrl,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.right,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: 'السعر الحالي (دينار)',
                    prefixIcon: const Icon(Icons.payments_outlined, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: oldPriceCtrl,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.right,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: 'السعر السابق قبل الخصم (اختياري)',
                    hintText: 'اتركه فارغاً إن لم يوجد خصم',
                    prefixIcon: const Icon(
                      Icons.local_offer_outlined,
                      size: 20,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // معاينة نسبة الخصم المحسوبة تلقائياً.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: oldPriceCtrl,
                  builder: (context, oldVal, _) {
                    final now = double.tryParse(priceCtrl.text.trim());
                    final before = double.tryParse(oldVal.text.trim());
                    if (now == null ||
                        before == null ||
                        before <= 0 ||
                        before <= now) {
                      return const SizedBox.shrink();
                    }
                    final pct = ((before - now) / before * 100).round();
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.success.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.percent_rounded,
                            color: AppColors.success,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'خصم $pct٪ على السعر',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w900,
                              fontSize: 12.5,
                              color: AppColors.success,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: serialCtrl,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.right,
                  decoration: InputDecoration(
                    labelText: 'الرقم التسلسلي (اختياري)',
                    prefixIcon: const Icon(Icons.qr_code_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // ★ ملاحظات المنتج: تُحفظ في products.special_note
                //   وتصل **لكل الزبائن** عامة للقراءة — تظهر في صفحة
                //   المنتج وكروت الأقسام. اختياري: فارغ = لا سطر عند
                //   الزبون (نرسل null لا نصاً فارغاً).
                TextField(
                  controller: noteCtrl,
                  textAlign: TextAlign.right,
                  maxLines: 3,
                  minLines: 1,
                  maxLength: 140,
                  decoration: InputDecoration(
                    labelText: 'ملاحظات المنتج (اختياري)',
                    hintText: 'مثال: وزن ٥٠٠غ — يُقدَّم بارداً — الصورة للزينة',
                    helperText: 'تظهر للجميع في صفحة المنتج وبطاقاته',
                    counterText: '',
                    prefixIcon: const Icon(Icons.notes_rounded, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // ★ يتطلب وصفة طبية: الزبون لا يستطيع طلبه إلا بإرفاق
                //   صورة وصفة، وتظهر الوصفة للصيدلي والأدمن فقط.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.30),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.medical_information_rounded,
                        size: 20,
                        color: AppColors.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'يتطلب وصفة طبية',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Switch(
                        value: requiresRx,
                        onChanged: (v) => setSheetState(() => requiresRx = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
                    final old = double.tryParse(oldPriceCtrl.text.trim());
                    final badOld =
                        old != null &&
                        (old <= 0 || (price > 0 && old <= price));
                    // القسم إجباري: بدونه لا يظهر المنتج في أي قسم.
                    final noCategory =
                        categoryId == null || categoryId.toString().isEmpty;
                    if (name.isEmpty || price <= 0 || badOld || noCategory) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(
                            badOld
                                ? 'السعر السابق يجب أن يكون أكبر من السعر الحالي'
                                : noCategory
                                ? 'اختر قسماً للمنتج'
                                : 'أدخل اسم المنتج وسعراً صحيحاً',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: AppColors.danger,
                        ),
                      );
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(
                    'إضافة المنتج',
                    style: GoogleFonts.cairo(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked != true) {
      // ★ أُلغيت النافذة: كل صورة رفعها هذا النموذج تُمسح من السحابة،
      //   فلا يبقى ملف يتيم بلا أي منتج يشير إليه.
      uploads.discard();
      return;
    }
    final name = nameCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
    final old = double.tryParse(oldPriceCtrl.text.trim());
    final serial = serialCtrl.text.trim();
    final note = noteCtrl.text.trim();
    if (shopName == null || shopName!.isEmpty) {
      for (final s in _shops) {
        if (s['id']?.toString() == shopId) {
          shopName = s['name']?.toString();
          break;
        }
      }
    }
    final ok = await SupabaseService.instance.addProduct(
      name: name,
      price: price,
      oldPrice: (old != null && old > price) ? old : null,
      shopId: shopId.isEmpty ? null : shopId,
      shopName: shopName,
      categoryId: categoryId,
      imagePath: newImageUrl,
      imageUrl: newImageUrl,
      serialNumber: serial.isEmpty ? null : serial,
      specialNote: note,
      requiresPrescription: requiresRx,
    );
    if (!mounted) return;
    // ★ الحفظ في القاعدة هو الذي يقرر مصير الصورة المرفوعة: نجح
    //   فالصورة لازمة لصف صار، وفشل فتُمسح من السحابة مع القاعدة.
    if (ok) {
      uploads.keep();
    } else {
      uploads.discard();
    }
    final addMsg = ok
        ? await _withCount('تمت إضافة المنتج')
        : 'تعذر إضافة المنتج';
    if (!mounted) return;
    _showMessage(addMsg, ok);
    // `_load()` تنتظر الآن `clearCache` وتُعلم الشاشات ⇒ يظهر المنتج
    // فوراً في أقسامه على أجهزة المستخدمين.
    if (ok) await _load();
  }

  /// تعديل السعر/الخصم/الاسم — يسري على كل المستخدمين فوراً.
  Future<void> _editProduct(Map<String, dynamic> p) async {
    final nameCtrl = TextEditingController(text: p['name']?.toString() ?? '');
    final priceCtrl = TextEditingController(
      text: ((p['price'] as num?) ?? 0).toStringAsFixed(0),
    );
    final oldCtrl = TextEditingController(
      text: p['old_price'] == null
          ? ''
          : (p['old_price'] as num).toStringAsFixed(0),
    );
    // ★ ملاحظات المنتج: كانت تُكتب عند الإضافة فقط ولا يمكن تعديلها
    //   بعدها. نصدها من نفس العمود العام للقراءة.
    final noteCtrl = TextEditingController(
      text: p['special_note']?.toString() ?? '',
    );

    // قسم المنتج: قبل الإصلاح لم يكن بالإمكان إعادة ربط منتج أُضيف
    // بقسم خطأ إلا بتعديل قاعدة البيانات يدوياً.
    var editCategoryId = p['category_id']?.toString();
    if (!_categoriesForThisShop.any(
      (c) => c['id']?.toString() == editCategoryId,
    )) {
      editCategoryId = _defaultCategoryId;
    }

    var editRx = p['requires_prescription'] == true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: Text(
            'تعديل: ${p['name']}',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 15),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  textAlign: TextAlign.right,
                  decoration: const InputDecoration(
                    labelText: 'اسم المنتج',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: priceCtrl,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'السعر الحالي',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: oldCtrl,
                  textAlign: TextAlign.right,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'السعر السابق (فارغ = بدون خصم)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: editCategoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'القسم',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in _categoriesForThisShop)
                      DropdownMenuItem<String?>(
                        value: c['id']?.toString(),
                        child: Text(
                          c['name_ar']?.toString() ??
                              c['name_en']?.toString() ??
                              'قسم',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _categoriesForThisShop.isEmpty
                      ? null
                      : (v) => editCategoryId = v,
                ),
                const SizedBox(height: 10),
                // ★ ملاحظات المنتج — عامة للقراءة: يراها كل زبون في
                //   صفحة المنتج وكروت الأقسام. مسح الحقل يُلغيها (null).
                TextField(
                  controller: noteCtrl,
                  textAlign: TextAlign.right,
                  maxLines: 3,
                  minLines: 1,
                  maxLength: 140,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات المنتج (تظهر للجميع)',
                    hintText: 'اتركه فارغاً لإلغائها',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 4),
                // ★ وصفة طبية: تبدأ من قيمة المنتج الحالية.
                Row(
                  children: [
                    const Icon(
                      Icons.medical_information_rounded,
                      size: 18,
                      color: AppColors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'يتطلب وصفة طبية',
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Switch(
                      value: editRx,
                      onChanged: (v) => setDialogState(() => editRx = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ للجميع'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    final name = nameCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim());
    final old = double.tryParse(oldCtrl.text.trim());
    if (name.isEmpty || price == null || price <= 0) {
      _showMessage('أدخل اسماً وسعراً صحيحاً', false);
      return;
    }
    final ok = await SupabaseService.instance.updateProduct(
      p['id'].toString(),
      {
        'name': name,
        'price': price,
        'old_price': (old != null && old > price) ? old : null,
        // إعادة ربط القسم إن تغيّر.
        'category_id': ?editCategoryId,
        // ★ الملاحظات: الحقل الفارغ = null لا «''»، حتى لا يظهر
        //   للزبون شريط ملاحظات أجوف فوق السعر.
        'special_note': noteCtrl.text.trim().isEmpty
            ? null
            : noteCtrl.text.trim(),
        // ★ وصفة طبية: عمود جديد في القاعدة — إن لم يُشغَّل سكربتها
        //   يرفض التحديث كله برسالة واضحة بدل صمت.
        'requires_prescription': editRx,
      },
    );
    if (!mounted) return;

    // ★★★ نشر السعر صار **داخل القاعدة** (تريجر `trg_products_price_cascade`
    //   على `products.price` — ملف `SQL_PRICE_LIVE_FOR_ALL.sql`): في نفس
    //   لحظة الحفظ يأخذ كل بند في طلبٍ جارٍ السعرَ الجديد، ويُعاد حساب
    //   إجمالي الطلب من بنوده، ويُشعر صاحبه بنغمة «تغيّر سعر». والمهمّ أن
    //   النشر يعمل **مهما كان مصدر التغيير** — لوحتك، شاشة التاجر، أو
    //   تصحيح يدوي في pgAdmin.
    //   ★ حُذف النداء الذي كان هنا (`propagateProductPriceToOpenOrders`)
    //   لأنه كان يعيد الكتابة بعد نجاح الحفظ، فيُدخل إشعاراً ثانياً على
    //   الطلب نفسه، ويترك السعر معلّقاً إن أُغلق الجهاز قبل أن تكتمل
    //   الحلقة. والدالة باقية في الخدمة لمن يريد النشر اليدوي.
    final priceChanged = ((p['price'] as num?) ?? 0) != price;
    if (ok) {
      await _load();
    }

    var msg = ok
        ? (priceChanged
              ? 'تم التحديث — السعر $price نافذ فوراً على الكتالوج والطلبات الجارية'
              : 'تم التحديث وسري على الجميع')
        : 'تعذر التحديث';
    if (ok) msg = await _withCount(msg);
    if (!mounted) return;
    _showMessage(msg, ok);
  }

  /// ★ شريط أقسام الصيدلية فوق القائمة: «الكل» ثم رفوفاً بعدادها ثم «بدون قسم»
  ///   إن بقي منتج بلا رفّ. لا يظهر الشريط ما دام الصيدلية بلا أقسام، فتبقى
  ///   الشاشة كما كانت بالضبط.
  Widget _buildShelfFilter() {
    final shelves = _shelvesOfThisShop;
    final selected = _shelfFilter;
    final unplaced = _shelfCount(ShopSections.unplacedId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ShelfChip(
              label: 'الكل',
              count: _products.length,
              isSelected: selected == null,
              onTap: () => setState(() => _sectionFilter = null),
            ),
            for (final c in shelves)
              ShelfChip(
                label: _categoryName(c['id']?.toString()) ?? 'قسم',
                count: _shelfCount(c['id'].toString()),
                isSelected: selected == c['id']?.toString(),
                onTap: () =>
                    setState(() => _sectionFilter = c['id']?.toString()),
              ),
            if (unplaced > 0)
              ShelfChip(
                label: ShopSections.unplacedLabel,
                count: unplaced,
                isSelected: selected == ShopSections.unplacedId,
                onTap: () =>
                    setState(() => _sectionFilter = ShopSections.unplacedId),
              ),
          ],
        ),
      ),
    );
  }

  /// سطر القسم على بطاقة المنتج: يريه أين يستقر الآن، والضغط عليه يفتحه
  /// مباشرة — فـ«نقل منتج إلى قسم» لا تنتظر أن يفتح الأدمن نافذة التعديل.
  Widget _buildShelfLine(Map<String, dynamic> p) {
    // ★ منتج نُقل إلى قسم دليل الرئيسية: يُعرض باسم ذلك القسم لا «بدون قسم».
    final direct = (p['category_id']?.toString() ?? '').trim();
    final directName = _categoryName(direct);
    final isDirectory =
        directName != null &&
        _doctorCats.any((d) => d.label.trim() == directName.trim());

    String name;
    if (_allShops) {
      // وضع كل الصيدليات: لا رفوف لصيدلية واحدة، فنُظهر قسم المنتج نفسه.
      name = directName == null
          ? ShopSections.unplacedLabel
          : (isDirectory ? '$directName · الرئيسية' : directName);
    } else {
      final shelfId = _shelfOfRow(p);
      name = shelfId == ShopSections.unplacedId
          ? ShopSections.unplacedLabel
          : (_categoryName(shelfId) ?? ShopSections.unplacedLabel);
      if (isDirectory) name = '$directName · الرئيسية';
    }
    return InkWell(
      onTap: () => _moveToSection(p),
      borderRadius: BorderRadius.circular(8),
      // ★ في وضع «كل الصيدليات» يحتاج الزر أن يُرى: خلفية فاتحة وحدّ
      //   كبسولي بدل نص صغير، ونصّه يسمّي الوجهة صراحة.
      child: _allShops
          ? Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.surfaceTint,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.drive_file_move_rounded,
                    size: 13,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'نقل إلى قسم رئيسي',
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_left_rounded,
                    size: 14,
                    color: AppColors.primary,
                  ),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  const Icon(
                    Icons.category_rounded,
                    size: 12,
                    color: AppColors.textHint,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '· نقل',
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      color: AppColors.textHint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// قسم المنتجات المطابق لاسم قسم في دليل الرئيسية — يُنشأ تلقائياً إن
  /// لم يوجد. المطابقة بالاسم هي نفس قاعدة عرض منتجات القسم في الرئيسية،
  /// فمنتجات هذا القسم تظهر هناك ولا تظهر كشريحة في صفحة الأدوية.
  Future<String?> _ensureCategoryForLabel(String label) async {
    final name = label.trim();
    if (name.isEmpty) return null;
    var cats = await SupabaseService.instance.fetchCategories();
    for (final c in cats) {
      if ((c['name_ar']?.toString().trim() ?? '') != name) continue;
      final id = c['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      if (c['is_active'] == false) {
        await SupabaseService.instance.updateCategory(id, {'is_active': true});
      }
      return id;
    }
    final ok = await SupabaseService.instance.addCategory(name: name);
    if (!ok) return null;
    cats = await SupabaseService.instance.fetchCategories();
    for (final c in cats) {
      if ((c['name_ar']?.toString().trim() ?? '') == name) {
        return c['id']?.toString();
      }
    }
    return null;
  }

  String? _categoryIdForLabel(String label) {
    final name = label.trim();
    for (final c in _categories) {
      if ((c['name_ar']?.toString().trim() ?? '') == name) {
        return c['id']?.toString();
      }
    }
    return null;
  }

  int _countForCategoryId(String? id) => id == null
      ? 0
      : _products
            .where((p) => (p['category_id']?.toString() ?? '') == id)
            .length;

  Widget _sheetGroup(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
    child: Text(
      text,
      style: GoogleFonts.cairo(
        fontSize: 11.5,
        fontWeight: FontWeight.w900,
        color: AppColors.textHint,
      ),
    ),
  );

  Future<String?> _askNewDirectorySection() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'قسم جديد في الرئيسية',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textAlign: TextAlign.right,
          maxLength: 30,
          decoration: InputDecoration(
            labelText: 'اسم القسم',
            hintText: 'مثال: العناية بالبشرة',
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(
              'إنشاء ونقل',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return (name == null || name.isEmpty) ? null : name;
  }

  /// ★ نقل منتج إلى قسم: يكتب `category_id` وحده — لا السعر ولا الصورة ولا
  ///   أي عمود آخر.
  ///
  ///   الورقة تعرض مجموعتين: أقسام صيدليته (صفحة الأدوية)، وأقسام الرئيسية
  ///   (دليل الأقسام) مع خيار إنشاء قسم دليل جديد. اختيار قسم دليل يجهّز
  ///   قسم المنتجات المطابق لاسمه تلقائياً ثم ينقل إليه.
  Future<void> _moveToSection(Map<String, dynamic> p) async {
    final shelves = _shelvesOfThisShop.isNotEmpty
        ? _shelvesOfThisShop
        : _categoriesForThisShop;
    final current = _shelfOfRow(p);
    // قسم المنتج الفعلي: لتأشير القسم الذي هو فيه الآن بين أقسام الرئيسية.
    final directId = (p['category_id']?.toString() ?? '').trim();
    final picked = await showModalBottomSheet<({String mode, String value})>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Text(
                _allShops ? 'نقل إلى دليل قسم رئيسي' : 'نقل إلى قسم',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                p['name']?.toString() ?? 'منتج',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              if (!_allShops && shelves.isNotEmpty) ...[
                _sheetGroup('أقسام صفحة الأدوية'),
                for (final c in shelves)
                  ListTile(
                    onTap: () => Navigator.pop(ctx, (
                      mode: 'category',
                      value: c['id']?.toString() ?? '',
                    )),
                    leading: Icon(
                      c['id']?.toString() == current
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: c['id']?.toString() == current
                          ? AppColors.primary
                          : AppColors.textHint,
                    ),
                    title: Text(
                      _categoryName(c['id']?.toString()) ?? 'قسم',
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    trailing: Text(
                      '${_shelfCount(c['id'].toString())}',
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textHint,
                      ),
                    ),
                  ),
                const Divider(height: 18),
              ],
              _sheetGroup('أقسام الرئيسية (دليل الأقسام)'),
              // ★ زر الإنشاء أولاً: أنشئ قسماً رئيسياً وانقل إليه بضغطة
              //   واحدة، بدل النزول آخر القائمة للبحث عنه.
              ListTile(
                onTap: () => Navigator.pop(ctx, (mode: 'new', value: '')),
                leading: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: AppColors.primary,
                ),
                title: Text(
                  'إنشاء قسم رئيسي جديد...',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
              for (final d in _doctorCats)
                ListTile(
                  onTap: () =>
                      Navigator.pop(ctx, (mode: 'directory', value: d.label)),
                  leading: Icon(
                    _categoryIdForLabel(d.label) == directId
                        ? Icons.check_circle_rounded
                        : Icons.public_rounded,
                    color: _categoryIdForLabel(d.label) == directId
                        ? AppColors.primary
                        : AppColors.textHint,
                  ),
                  title: Text(
                    d.label,
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    'يظهر في الرئيسية · لا في صفحة الأدوية',
                    style: GoogleFonts.cairo(
                      fontSize: 10.5,
                      color: AppColors.textHint,
                    ),
                  ),
                  trailing: Text(
                    '${_countForCategoryId(_categoryIdForLabel(d.label))}',
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800,
                      color: AppColors.textHint,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;

    String? targetId;
    var targetLabel = '';
    if (picked.mode == 'category') {
      targetId = picked.value;
    } else {
      var label = picked.value;
      if (picked.mode == 'new') {
        final name = await _askNewDirectorySection();
        if (name == null || !mounted) return;
        label = name;
      }
      final labelText = label.trim();
      if (labelText.isEmpty) return;
      final cats = await DoctorDirectoryService.instance.fetchCategories(
        force: true,
      );
      if (!cats.any((c) => c.label.trim() == labelText)) {
        final added = await DoctorDirectoryService.instance.addCategory(
          labelText,
        );
        if (!mounted) return;
        if (!added) {
          _showMessage(
            SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر إنشاء القسم'
                : SupabaseService.instance.lastAdminError,
            false,
          );
          return;
        }
      }
      targetLabel = labelText;
      targetId = await _ensureCategoryForLabel(labelText);
      if (!mounted) return;
      if (targetId == null) {
        _showMessage(
          SupabaseService.instance.lastAdminError.isEmpty
              ? 'تعذر تجهيز قسم المنتجات'
              : SupabaseService.instance.lastAdminError,
          false,
        );
        return;
      }
    }
    if (targetId.isEmpty || targetId == current) return;
    final ok = await SupabaseService.instance.updateProduct(
      p['id'].toString(),
      {'category_id': targetId},
    );
    if (!mounted) return;
    if (ok) await _load();
    if (!mounted) return;
    final name = targetLabel.isNotEmpty
        ? targetLabel
        : (_categoryName(targetId) ?? 'القسم');
    _showMessage(
      ok
          ? 'نُقل «${p['name']}» إلى $name · '
                'عدد منتجات القسم الآن ${_countForCategoryId(targetId)}'
          : (SupabaseService.instance.lastAdminError.isEmpty
                ? 'تعذر النقل'
                : SupabaseService.instance.lastAdminError),
      ok,
    );
  }

  Future<void> _toggleActive(Map<String, dynamic> product) async {
    final wasOn = product['is_active'] == true;
    final ok = await SupabaseService.instance.updateProduct(
      product['id'].toString(),
      {'is_active': !wasOn},
    );
    if (!mounted) return;
    final toggleMsg = ok ? await _withCount('تم تحديث الحالة') : 'تعذر التحديث';
    if (!mounted) return;
    _showMessage(toggleMsg, ok);
    if (ok) _load();
  }

  Future<void> _deleteProduct(Map<String, dynamic> product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'حذف المنتج',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'هل تريد حذف "${product['name']}"؟',
          style: GoogleFonts.cairo(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: GoogleFonts.cairo()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(
              'حذف',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await SupabaseService.instance.deleteProduct(
      product['id'].toString(),
    );
    if (!mounted) return;
    String msg;
    if (ok) {
      msg = await _withCount('تم حذف المنتج');
    } else {
      msg = SupabaseService.instance.lastDeleteError.isEmpty
          ? 'تعذر حذف المنتج'
          : SupabaseService.instance.lastDeleteError;
    }
    if (!mounted) return;
    _showMessage(msg, ok);
    if (ok) {
      // ★ الحذف فوراً وبلا كاش: يُقصى المعرّف من نسخ المنتجات على الجهاز
      //   (الكتالوج + نسخ الصيدليات) قبل أي رسم، فلو كان الجهاز نفسه يفتح
      //   واجهة الزبون لم يظهر له المنتج المحذوف لحظةً واحدة.
      // `deletionConfirmed: true` — ردّ السيرفر بالنجاح وصل قبل هذه
      //   السطور، فلا حاجة لانتظار فحص [recheckDeletedProduct] ليُحرَّر
      //   ملف صورة المنتج من القرص.
      await RealDataService.instance.purgeProductFromCaches(
        product['id'].toString(),
        deletionConfirmed: true,
      );
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _allShops ? 'كل المنتجات' : 'منتجات الصيدلية',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          // ★ في وضع «كل الصيدليات» تبقى إدارة الصيدليات نفسها (إضافة/
          //   حذف) على بعد ضغطة، فلا يُفقد مسارها بعد تحويل الزر إليها.
          if (_allShops)
            TextButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AdminShopsScreen(),
                  ),
                );
                if (mounted) _load();
              },
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              icon: const Icon(Icons.storefront_rounded, size: 18),
              label: Text(
                'الصيدليات',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                ),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProduct,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: Text(
          'منتج جديد',
          style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ★ شريط الأقسام أعلى القائمة، لا داخلها: يبقى مرئياً أثناء
                //   التمرير، فلا يُضطر الأدمن أن يصعد كل مرة ليبدّل الرف.
                if (_shelvesOfThisShop.isNotEmpty) _buildShelfFilter(),
                Expanded(
                  child: AppRefreshIndicator(
                    color: AppColors.primary,
                    onRefresh: _load,
                    child: _visibleProducts.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              const SizedBox(height: 140),
                              const Icon(
                                Icons.inventory_2_outlined,
                                size: 64,
                                color: AppColors.textHint,
                              ),
                              const SizedBox(height: 12),
                              Center(
                                child: Text(
                                  _emptyListMessage,
                                  style: GoogleFonts.cairo(
                                    color: AppColors.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(16),
                            itemCount: _visibleProducts.length,
                            itemBuilder: (_, i) {
                              final p = _visibleProducts[i];
                              final image =
                                  p['image_path']?.toString() ??
                                  p['logo_image']?.toString() ??
                                  '';
                              final price = (p['price'] is num)
                                  ? (p['price'] as num).toDouble()
                                  : (double.tryParse(
                                          p['price']?.toString() ?? '',
                                        ) ??
                                        0);
                              final active = p['is_active'] == true;
                              return Card(
                                elevation: 1.5,
                                margin: const EdgeInsets.only(bottom: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  // الضغط على المنتج يفتح التعديل (سري للجميع).
                                  onTap: () => _editProduct(p),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Row(
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: image.isEmpty
                                              ? Container(
                                                  width: 56,
                                                  height: 56,
                                                  color: AppColors.surfaceTint,
                                                  child: const Icon(
                                                    Icons
                                                        .image_not_supported_outlined,
                                                    color: AppColors.textHint,
                                                    size: 26,
                                                  ),
                                                )
                                              : AppImage(
                                                  image,
                                                  width: 56,
                                                  height: 56,
                                                  fit: BoxFit.cover,
                                                ),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                p['name']?.toString() ?? 'منتج',
                                                style: GoogleFonts.cairo(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppColors.textPrimary,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                CurrencyFormatter.format(price),
                                                style: GoogleFonts.cairo(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w900,
                                                  color: AppColors.primary,
                                                ),
                                              ),
                                              // ★ اسم الصيدلية في وضع «كل
                                              //   الصيدليات» — أي منتج لأي صيدلية.
                                              if (_allShops)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 3,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      const Icon(
                                                        Icons
                                                            .storefront_rounded,
                                                        size: 12,
                                                        color:
                                                            AppColors.textHint,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Flexible(
                                                        child: Text(
                                                          _shopNameOf(p),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              GoogleFonts.cairo(
                                                                fontSize: 10.5,
                                                                color: AppColors
                                                                    .textSecondary,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              // ★ سطر القسم + «نقل» — دائماً في
                                              //   وضع كل الصيدليات، وللصيدلية
                                              //   التي لها أقسام في وضعها.
                                              if (_allShops ||
                                                  _shelvesOfThisShop.isNotEmpty)
                                                _buildShelfLine(p),
                                              if (p['serial_number']
                                                      ?.toString()
                                                      .isNotEmpty ==
                                                  true)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 3,
                                                      ),
                                                  child: Text(
                                                    'رقم تسلسلي: ${p['serial_number']}',
                                                    style: GoogleFonts.cairo(
                                                      fontSize: 10.5,
                                                      color: AppColors.textHint,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Switch(
                                          value: active,
                                          activeThumbColor: AppColors.success,
                                          onChanged: (_) => _toggleActive(p),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                            color: AppColors.danger,
                                          ),
                                          onPressed: () => _deleteProduct(p),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}
