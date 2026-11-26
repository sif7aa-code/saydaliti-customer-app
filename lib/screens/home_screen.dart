import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/category_item.dart';
import '../models/product.dart';
import '../models/shop.dart';
import '../services/city_store.dart';
import '../services/real_data_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/city_picker_sheet.dart';
import '../widgets/app_image.dart';
import '../widgets/category_product_section.dart';
import '../widgets/category_strip.dart';
import '../widgets/install_app_banner.dart';
import '../widgets/location_header.dart';
import '../widgets/main_search_bar.dart';
import '../widgets/tap_to_dismiss_keyboard.dart';
import 'free_driver_request_screen.dart';
import 'search_results_screen.dart';
import 'product_details_screen.dart';
import 'category_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TabRefreshTarget<HomeScreen> {
  @override
  String get tabId => 'meds';

  /// ★ نقرة زرّ «الرئيسية» في القائمة السفلية: تصعد لأول منتج (يفعلها
  ///   الـmixin فوراً) ثم تعمل نفس تحديث السحب — جلب كامل من الشبكة
  ///   وتجاويز الكاش — وتُسمع رنّة التحديث إذا نجح.
  @override
  Future<void> Function() onTabRefresh() => _onRefresh;

  List<CategoryItem> _categories = const [];
  List<Product> _allProducts = const [];

  // نتائج الاشتقاق محفوظة كحقول لا كـ getters.
  //
  // `get _sections` كان يُحسب **داخل build()**: مسح كامل للمنتجات لكل
  // قسم (٢٠ قسماً × ٢٠٠٠ منتج = ٤٠٠٠٠ استدعاء شرط) في **كل إطار**،
  // مع إظهار `closedShopIds` مرتين أخريين. الآن يُحسب مرة واحدة عند
  // [_load()] فقط.
  List<(CategoryItem, List<Product>)> _sections = const [];
  Set<String> _closedShopIds = const {};

  VoidCallback? _onCatalogChanged;

  /// ★ المدينة في الشريط الأخضر: نفس شارة دليل الأطباء — تبديل حر من أي
  ///   تبويب، والاختيار يُحفظ في [CityStore] فيراه الدليل فوراً.
  String _city = CityStore.cities.first;

  @override
  void initState() {
    super.initState();
    // تحديث مرئي عند تغيّر الكتالوج من أي مصدر (فتح تبويب، تحديث خلفي).
    // قبل هذا كانت الخدمة تحدّث كاشها بصمت ولا تتغيّر أي شاشة.
    _onCatalogChanged = () {
      if (mounted) _load();
    };
    RealDataService.instance.catalogGeneration.addListener(_onCatalogChanged!);
    _city = CityStore.instance.chosen ?? CityStore.cities.first;
    CityStore.instance.changed.addListener(_onCityChosen);
    unawaited(_syncChosenCity());
    _load();
  }

  @override
  void dispose() {
    final cb = _onCatalogChanged;
    if (cb != null) {
      RealDataService.instance.catalogGeneration.removeListener(cb);
    }
    CityStore.instance.changed.removeListener(_onCityChosen);
    super.dispose();
  }

  void _onCityChosen() {
    final chosen = CityStore.instance.chosen;
    if (!mounted || chosen == null || chosen == _city) return;
    setState(() => _city = chosen);
  }

  Future<void> _syncChosenCity() async {
    await CityStore.instance.load();
    final chosen = CityStore.instance.chosen;
    if (!mounted || chosen == null || chosen == _city) return;
    setState(() => _city = chosen);
  }

  Future<void> _openCityPicker() async {
    final picked = await showCityPicker(context, allowClose: true);
    if (picked == null || !mounted || picked == _city) return;
    setState(() => _city = picked);
    await CityStore.instance.save(picked);
  }

  Future<void> _load({bool force = false}) async {
    // force = السحب للتحديث: يجب أن يتجاوز كاش الـ 60 ثانية لكل شيء،
    // وإلا ظهرت أقسام ومنتجات قديمة لأن `fetch*` العادي يقرأ الكاش.
    if (force) {
      await RealDataService.instance.refreshAll();
    }
    // ★ مرحلتان لا انتظار واحد: البانرات والأقسام والصيدليات تُرسم حالما
    //   تصل (وهي من القرص فوراً عند المستخدم القديم)، والمنتجات — وهي
    //   الأثقل وأبطؤها — تُكمل الأقسام بعدها. السابق كان `Future.wait`
    //   واحداً على الأربعة، فتقف الشاشة كلها على أبطأ رحلة وتُرى بيضاء
    //   كأن التطبيق بطيء، مع أن ثلاثة أرباع محتواها كان جاهزاً.
    final early = await Future.wait<Object>([
      RealDataService.instance.fetchCategories(),
      RealDataService.instance.fetchAllShops(),
    ]);
    if (!mounted) return;
    final categories = early[0] as List<CategoryItem>;
    final allShops = early[1] as List<Shop>;
    setState(() {
      // ★ الرفوف الداخلية (`categories.shop_id` غير فارغ) لا تظهر في
      //   الرئيسية إطلاقاً (طلب الأدمن 2026-11-18): لكل صيدلية رفوفها
      //   داخل صفحتها وحدها. تُمرَّر القائمة الكاملة إلى
      //   `buildCategorySections` لأنها تحتاج `shopId` لتوجيه منتجات
      //   الصيدلية إلى قسم وجهها — الفلتر هنا للعرض فقط.
      // ★ صفحة الأدوية تعرض **كل المنتجات المنشورة** تحت أقسامها، حتى
      //   لو حمل القسم اسم قسم من دليل الرئيسية («أدوية العناية»،
      //   «علاجات البشرة»، «صيدليات»…) — طلب الأدمن 2026-11-21.
      _categories = categories.where((c) => (c.shopId ?? '').isEmpty).toList();
      _closedShopIds = _buildClosedShops(allShops);
      // ما دامت المنتجات لم تصل، تُبقى الأقسام التي عرضناها للتو (لا
      // تُمسح)، فلا وميض «اختفت الأقسام» عند كل تحديث خلفي.
      if (_allProducts.isEmpty) _sections = const [];
    });
    final allProducts = await RealDataService.instance.fetchProducts();
    if (!mounted) return;
    setState(() {
      _allProducts = allProducts;
      _sections = buildCategorySections(categories, allProducts, allShops);
    });
    // ★ صور المنتجات تُرسم في أول إطار: نُنقل الملفات المحفوظة منها على
    //   القرص إلى كاش الذاكرة قبل أن تُبنى البطاقات. **لا طلب إنترنت في
    //   هذا المسار إطلاقاً** — ما ليس محفوظاً يُترك ليُطلب عند ظهوره على
    //   الشاشة، فلا تُستهلك بيانات على صورة لن تُرى. الترتيب من [_sections]
    //   لا من [allProducts]، وهو ترتيب الظهور الفعلي في الأقسام.
    unawaited(
      AppImage.warmFromDisk(
        context,
        _sections.expand((s) => s.$2.map((p) => p.logoImage ?? '')),
      ),
    );
  }

  Future<void> _onRefresh() async {
    await _load(force: true);
  }

  static Set<String> _buildClosedShops(List<Shop> shops) => <String>{
    for (final s in shops)
      if (!s.isOpen) s.id,
  };

  void _openProductDetails(Product product) {
    var list = _allProducts.where((p) => p.shopId == product.shopId).toList();
    if (list.isEmpty) list = [product];
    final isOpen = !_closedShopIds.contains(product.shopId);
    final index = list.indexWhere((p) => p.id == product.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductDetailsScreen(
          products: list,
          initialIndex: index < 0 ? 0 : index,
          isStoreOpen: isOpen,
        ),
      ),
    );
  }

  void _openCategory(CategoryItem cat) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => CategoryScreen(category: cat)));
  }

  void _onCategorySelected(BuildContext context, CategoryItem cat) {
    if (cat.id == 'more') {
      _showAllCategoriesSheet(context);
      return;
    }
    _openCategory(cat);
  }

  void _showAllCategoriesSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      // كان الـ builder يعيد Padding→Column بلا أي سطح مرئي، فكانت
      // القائمة تطفو فوق الحاجب الداكن والنص الأسود عليها = شاشة شفافة.
      // لا بد من Container بلون صلب (نفس نمط login_modal_sheet.dart).
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: ConstrainedBox(
            // أقصى ارتفاع 75% من الشاشة حتى لا يطفح العمود.
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'جميع الأقسام والتصنيفات',
                          style: GoogleFonts.cairo(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                        color: AppColors.textSecondary,
                        tooltip: 'إغلاق',
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // لازم قابل للتمرير: عدد الأقسام غير محدّد.
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: _categories.length,
                    itemBuilder: (_, i) {
                      final cat = _categories[i];
                      return ListTile(
                        leading: CategoryCircle2(cat: cat),
                        title: Text(
                          cat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_left_rounded,
                          color: AppColors.textHint,
                        ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _openCategory(cat);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // ★ كل الأقسام تُعرض بالترتيب. كان الكود يأخذ `sections.sublist(1)`
    //   فقط بعد حذف القسم المميّز، فيختفي أول قسم
    //   الرئيسية، ومن ثمّ تختفي كل المنتجات إن كان له قسم واحد فقط.
    final sections = _sections;
    final screenWidth = MediaQuery.sizeOf(context).width;
    // ★ المرجع (2026-10-26): هامش البطاقات عن حافة الشاشة 17 بكسل من
    //   صورة 576 عرضها = **12 نقطة منطقية** على كل المقاسات.
    final horizontalPadding = screenWidth <= 340
        ? 10.0
        : screenWidth <= 430
        ? 12.0
        : 20.0;

    // عدد عناصر القائمة: رأس هادئ + الأقسام والبانرات.
    // `ListView` الكسول يبني ما يظهر فقط، فالبطاقات الأفقية (وطلباتها
    // الشبكية وصورها) لم تعد تُبنى كلها عند فتح الصفحة.
    final headerCount = 3;
    final itemCount = headerCount + sections.length + 1;

    return Scaffold(
      // ★ 2026-11-20 — نفس هيكل بقية التبويبات: شريط أخضر (شعار · الاسم ·
      //   المدينة · الجرس · السلة) ثم ورقة بيضاء للمحتوى. قبل هذا كانت
      //   الصفحة بيضاء من أولها مع زر سلة وحده في الزاوية، فبدت مختلفة عن
      //   دليل الأطباء والصيدليات.
      backgroundColor: AppColors.primary,
      body: TapToDismissKeyboard(
        child: Column(
          children: [
            _MedsTopBar(city: _city, onOpenCityPicker: _openCityPicker),
            Expanded(
              child: ColoredBox(
                color: Colors.white,
                child: AppRefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _onRefresh,
                  child: ListView.builder(
                    controller: tabScroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      switch (index) {
                        // 1) رأس هادئ: من أعلى الشاشة حتى نهاية شريط البحث،
                        //    على خلفية التطبيق نفسها (عاجي دافئ) بلا تدرّج رمادي
                        //    ولا ظل كبير — البطاقات تبرز بقوامها الخاص فقط.
                        case 0:
                          return Container(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Column(
                              children: [
                                const SizedBox(height: 8),
                                // ★ رسالة تثبيت التطبيق (نسخة الويب فقط):
                                //   تحثّ الزائر على إضافة «صيدليتي» للشاشة
                                //   الرئيسية — تختفي بعد الإغلاق أو التثبيت.
                                if (kIsWeb) ...[
                                  InstallAppBanner(padding: horizontalPadding),
                                  const SizedBox(height: 10),
                                ],
                                // ★ السلة والجرس انتقلا إلى الشريط الأخضر أعلاه
                                //   (2026-11-20) كبقية التبويبات، فلا يبقى زر
                                //   وحده في زاوية بيضاء.
                                _SectionPad(
                                  padding: horizontalPadding,
                                  child: MainSearchBar(
                                    onFilterTap: () =>
                                        _showAllCategoriesSheet(context),
                                    onSubmitted: (q) {
                                      final query = q.trim();
                                      if (query.isEmpty) return;
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              SearchResultsScreen(query: query),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        case 1:
                          // ★ 2026-11-19: «طلب مندوب» خرج من تبويب «خدمات» الذي
                          //   أُزيل من الشريط، فصار **بطاقة دعوة** هنا فوق
                          //   الأقسام — تفتح شاشة طلب المندوب كما هي.
                          return Padding(
                            padding: EdgeInsets.fromLTRB(
                              horizontalPadding,
                              0,
                              horizontalPadding,
                              2,
                            ),
                            child: _DriverHeroCard(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const FreeDriverRequestScreen(),
                                ),
                              ),
                            ),
                          );
                        case 2:
                          return _SectionPad(
                            padding: horizontalPadding,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: CategoryStrip(
                                categories: _categories,
                                onCategoryTap: (category) =>
                                    _onCategorySelected(context, category),
                              ),
                            ),
                          );
                      }

                      if (index == itemCount - 1)
                        return const SizedBox(height: 24);

                      // 4) كل الأقسام تُعرض كعناوين متتالية مع منتجاتها للأسفل.
                      final sectionIndex = index - headerCount;
                      if (sectionIndex < 0 || sectionIndex >= sections.length) {
                        return const SizedBox.shrink();
                      }
                      final (cat, prods) = sections[sectionIndex];
                      return CategoryProductSection(
                        category: cat,
                        products: prods,
                        closedShopIds: _closedShopIds,
                        onProductTap: _openProductDetails,
                        onViewAll: cat.id == 'all-products'
                            ? null
                            : () => _openCategory(cat),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// يوزّع منتجات الكتالوج على أقسام الصفحة الرئيسية.
///
/// ★★ **الصيدلية أولاً**: منتج صيدليةٍ مربوطٍ صراحةً بقسم
///   (`shops.category_id` أو `categories.shop_id`) يُعرض في قسم صيدليته،
///   حتى لو كان `products.category_id` يحمل قسماً آخر قديماً/افتراضياً.
///
///   هذا هو سبب اختفاء «افران ومخابز» تماماً: الصيدلية «كليجه اهلنا» مربوط
///   بالمخابز، لكن منتجاته الاثني عشر سُجّلت قسم «مطاعم» (القسم الافتراضي
///   في نموذج الإضافة وقتها)، فكانت كلها تحت المطاعم وبقي قسم المخابز
///   فارغاً فكان يُخفى عن الرئيسية بالكامل.
///
/// القواعد، بهذا الترتيب:
///  1) صيدلية له قسم صالح ⇒ كل منتجاته في قسمه.
///  2) صيدلية بلا قسم ⇒ قسم المنتج نفسه إن كان صالحاً.
///  3) قسم المنتج غير موجود/غير نشط ولا قسم للصيدلية ⇒ «منتجات أخرى».
///     **لا يُسقط أي منتج** أبداً.
///
/// الأقسام الفارغة تُخفى، وتُرتب الأقسام بترتيب شريط الأقسام نفسه.
List<(CategoryItem, List<Product>)> buildCategorySections(
  List<CategoryItem> categories,
  List<Product> allProducts, [
  List<Shop> allShops = const [],
]) {
  final categoryIds = <String>{
    for (final c in categories)
      if (c.id != 'more') c.id,
  };
  // أقسام عامة (`categories.shop_id` فارغ): تجمع منتجات عدة صيدليات.
  final globalIds = <String>{
    for (final c in categories)
      if (c.id != 'more' && (c.shopId ?? '').trim().isEmpty) c.id,
  };

  // عكسي: صيدلية ⇒ القسم الذي ينتمي إليه (الربط في الاتجاهين).
  final categoryOfShop = <String, String>{};
  for (final s in allShops) {
    final cid = s.categoryId.trim();
    if (cid.isEmpty || cid == 'null' || !categoryIds.contains(cid)) continue;
    categoryOfShop.putIfAbsent(s.id, () => cid);
  }
  for (final c in categories) {
    final owner = c.shopId?.trim() ?? '';
    if (owner.isEmpty || owner == 'null') continue;
    if (!categoryIds.contains(c.id)) continue;
    // ★ `putIfAbsent` لا كتابة: صيدلية بأقسام داخلية عدة (`categories.shop_id`)
    //   كانت آخر شريحة في القائمة تزيح قسمَ صيدليته الرئيسي فتنتقل الرئيسية
    //   كلها إليه. قسم الصيدلية المسجَّل في `shops.category_id` هو وجهه في
    //   الرئيسية، وبقية أقسامه رفوف داخل صفحته وحدها.
    categoryOfShop.putIfAbsent(owner, () => c.id);
  }

  final byCategory = <String, List<Product>>{
    for (final id in categoryIds) id: <Product>[],
  };
  final uncategorized = <Product>[];

  for (final p in allProducts) {
    final shopCategory = categoryOfShop[p.shopId];
    final direct = (p.categoryId ?? '').trim();
    // ★ نفس قاعدة صفحة القسم: اختيار الأدمن لقسم عام يعلو على قسم وجه
    //   الصيدلية، وإلا اختفى المنتج من القسم العام الذي اختاره له.
    final target = globalIds.contains(direct)
        ? direct
        : (shopCategory != null)
        ? shopCategory
        : (categoryIds.contains(direct) ? direct : null);
    if (target == null) {
      uncategorized.add(p);
    } else {
      byCategory[target]!.add(p);
    }
  }

  final sections = <(CategoryItem, List<Product>)>[];
  for (final cat in categories) {
    if (cat.id == 'more') continue;
    final list = byCategory[cat.id];
    if (list == null || list.isEmpty) continue;
    sections.add((cat, list));
  }

  if (uncategorized.isNotEmpty) {
    sections.add((
      CategoryItem(
        id: 'all-products',
        title: 'منتجات أخرى',
        icon: Icons.shopping_bag_rounded,
        color: AppColors.primary,
      ),
      uncategorized,
    ));
  }
  return sections;
}

/// دائرة قسم صغيرة للاستخدام في سلة "جميع الأقسام".
class CategoryCircle2 extends StatelessWidget {
  const CategoryCircle2({super.key, required this.cat});

  final CategoryItem cat;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: cat.color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: cat.color.withValues(alpha: 0.3)),
      ),
      child: Icon(cat.icon, color: cat.color, size: 21),
    );
  }
}

/// الشريط العلوي الأخضر لتبويب «الأدوية» — نسخة دليل الأطباء نفسها
/// (شعار · الاسم · شارة المدينة · جرس) مع سلة المنتجات في طرفه.
class _MedsTopBar extends StatelessWidget {
  const _MedsTopBar({required this.city, required this.onOpenCityPicker});

  final String city;
  final VoidCallback onOpenCityPicker;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 46,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  width: 37,
                  height: 37,
                  padding: const EdgeInsets.all(1.5),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // ★ مرن: مع أيقونة الدردشة صارت أزرار الرأس أكثر، فالاسم
                //   يقصر بـ«…» على الشاشات الضيقة (360dp) بدل تجاوز الصف.
                Expanded(
                  child: Text(
                    'اطباء ذي قار',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: onOpenCityPicker,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.location_on_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          city,
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 1),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white,
                          size: 17,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                const NotificationsBell(
                  size: 38,
                  background: Colors.transparent,
                  iconColor: Colors.white,
                ),
                const SizedBox(width: 2),
                const HeaderCartButton(
                  size: 38,
                  background: Colors.white,
                  iconColor: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ★ بطاقة «اطلب مندوب توصيل» أعلى تبويب الأدوية — بديل زرّ «خدمات»
///   الذي أُخرج من الشريط السفلي. تدرّج أخضر، أيقونة درّاجة، وزرّ أبيض
///   «اضغط هنا»؛ النقر يفتح شاشة طلب المندوب كما هي بلا أي تعديل.
class _DriverHeroCard extends StatelessWidget {
  const _DriverHeroCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: AppColors.bannerGradient2,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
                child: const Icon(
                  Icons.two_wheeler_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'اطلب مندوب توصيل',
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'يوصّل طلبك من أي صيدلية إلى بابك',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  'اضغط هنا',
                  style: GoogleFonts.cairo(
                    color: AppColors.primaryDeep,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// يحيط المحتوى بهامش أفقي آمن؛ البانر فقط يملأ عرض الصفحة كاملاً.
class _SectionPad extends StatelessWidget {
  const _SectionPad({required this.padding, required this.child});

  final double padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padding),
      child: child,
    );
  }
}
