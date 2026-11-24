import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/shop_sections.dart';
import '../core/utils/shop_status.dart';
import '../models/category_item.dart';
import '../models/product.dart';
import '../models/shop.dart';
import '../services/auth_service.dart';
import '../services/cart_service.dart';
import '../services/real_data_service.dart';
import '../services/recent_view_store.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/product_card.dart';
import '../widgets/shelf_chip.dart';
import '../widgets/tap_to_dismiss_keyboard.dart';
import 'cart_screen.dart';
import 'login_screen.dart';
import 'product_details_screen.dart';

/// ★ لوحة ألوان **بروفايل الصيدلية وحده** — كل درجة هنا مأخوذة من مصدر الهوية
///   الواحد `AppColors` (الصورة المرجعية 2026-10-26: خلفية `#F7FBFE`، بطاقة
///   داخلية زمردية `#E9F7E6`، غلاف أخضر مائل للأزرق).
///   معرّفة هنا لا في `app_colors.dart` حتى ينفصل مظهر هذه الشاشة عن غيرها.
abstract final class _ShopProfile {
  static const Color page = AppColors.background;
  // ★ البطاقة الداخلية الفاتحة = الزمردي الفاتح المقاس من المرجع (#E9F7E6)
  static const Color cardTint = AppColors.surfaceTint;
  static const Color fieldBorder = AppColors.divider;
  static const Color titleNavy = AppColors.textPrimary;

  static const LinearGradient coverGradient = LinearGradient(
    colors: [AppColors.brandLight, AppColors.primary, AppColors.primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    stops: [0.0, 0.55, 1.0],
  );

  /// ظل ناعم جداً (البطاقة تُعرَّف بلونها لا بظل عريض).
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x0F15151D), blurRadius: 16, offset: Offset(0, 6)),
  ];

  static const double radius = 22;
  static const double margin = 14;
}

class ShopDetailsScreen extends StatefulWidget {
  const ShopDetailsScreen({super.key, required this.shop});

  final Shop shop;

  @override
  State<ShopDetailsScreen> createState() => _ShopDetailsScreenState();
}

class _ShopDetailsScreenState extends State<ShopDetailsScreen> {
  String _searchQuery = '';
  List<Product> _products = const [];

  /// ★ أقسام هذه الصيدلية الداخلية (`categories.shop_id`) — فارغة ما دام
  ///   الأدمن لم يُنشئ له قسماً، فلا يظهر شريط الشرائح أصلاً وتبقى الصفحة
  ///   كما كانت بالضبط.
  List<CategoryItem> _sections = const [];

  /// القسم المختار الآن؛ null = «الكل».
  String? _sectionId;

  /// يتابع التمرير فقط لتلاشي كبسولة الرجوع بهدوء عند الصعود فوق
  /// البطاقة البيضاء، فلا تغطّي نصاً ولا تُضيف شريطاً ملوّناً خلف الرأس.
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // تسجيل الصيدلية ضمن "شاهدتها مؤخراً" الحقيقية بمجرد فتحه.
    RecentViewsStore.instance.addShop(widget.shop);
    // ★ أول رسمة بمنتجات لا بشاشة فارغة: إن كان كتالوج الصيدلية في الذاكرة
    //   أصلاً — وهو الغالب بعد صفحة الصيدليات — نعرضه فوراً، ثم يأتي التحديث
    //   الشبكي خلف الصورة لا أمامها.
    final seeded = RealDataService.instance.productsForShopFromMemory(
      widget.shop.id,
    );
    if (seeded != null) _products = seeded;
    _loadProducts();
    _loadSections();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// نسبة ظهور أزرار الغلاف: تبدأ كاملة وتنصهر تدريجياً مع أول سنتيمترات من
  /// التمرير، فلا تطفو فوق البطاقة البيضاء وتحجب البحث أو أوقات العمل.
  double get _controlsFade {
    if (!_scroll.hasClients) return 1.0;
    return (1.0 - (_scroll.offset - 10) / 38).clamp(0.0, 1.0);
  }

  Future<void> _loadProducts() async {
    final products = await RealDataService.instance.fetchProducts(
      shopId: widget.shop.id,
    );
    if (!mounted) return;
    setState(() => _products = products);
  }

  /// ★ أقسام الصيدلية: قائمة الأقسام محمّلة أصلاً في الذاكرة (الشاشة الرئيسية
  ///   تجلبها قبل أي صيدلية)، فالنداء هنا لا شبكة فيه في الغالب.
  Future<void> _loadSections() async {
    final categories = await RealDataService.instance.fetchCategories();
    final sections = ShopSections.ofShop(categories, widget.shop.id);
    if (!mounted) return;
    setState(() => _sections = sections);
  }

  /// رفوف هذه الصيدلية: معرّف القسم ⇒ منتجاته. تُحسب من [ShopSections] وحدها،
  /// فلا يختلف عدد الشريحة على ما يعرضه الضغط عليها.
  Map<String, List<Product>> get _shelves => ShopSections.groupProducts(
    products: _products,
    sections: _sections,
    shopCategoryId: widget.shop.categoryId,
  );

  /// القسم المختار فعلاً: إن حذف الأدمن القسم والشاشة ما زالت مفتوحة يعود
  /// العرض إلى «الكل»، فلا تُفسّر القائمة الفارغة على أنها الصيدلية فارغ.
  String? get _selectedSectionId {
    final id = _sectionId;
    if (id == null) return null;
    if (id == ShopSections.unplacedId) return id;
    return _sections.any((c) => c.id == id) ? id : null;
  }

  List<Product> get _sectionProducts {
    final id = _selectedSectionId;
    if (id == null) return _products;
    return _shelves[id] ?? const [];
  }

  /// المنتجات المعروضة: القسم ثم البحث. البحث يبقى فوق «الكل» وفي كل قسم،
  /// فيظل «لا توجد منتجات مطابقة للبحث» صادقاً في الحالتين.
  List<Product> get _storeProducts {
    final list = _sectionProducts;
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return list;
    return list
        .where((p) => p.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _onRefresh() async {
    await _loadProducts();
    if (mounted) setState(() {});
  }

  void _openProduct(Product product) {
    // ★ التصفح بالتمرير يبقى داخل القسم المختار: من فتح «كيك» لا يهبط به
    //   تمريره إلى منتجات أقسام أخرى.
    var list = _sectionProducts
        .where((p) => p.shopId == product.shopId)
        .toList();
    if (list.isEmpty) list = [product];
    final index = list.indexWhere((p) => p.id == product.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductDetailsScreen(
          products: list,
          initialIndex: index < 0 ? 0 : index,
          isStoreOpen: _status.isOpen,
        ),
      ),
    );
  }

  /// ★ حالة الصيدلية من جدول الوقت، لا من مفتاح `is_open` الخام: بلا هذا يبقى
  ///   شريط السلة وقفل الإضافة للسلة يقولان غير ما تقوله بطاقة الصيدلية.
  ShopStatus get _status => widget.shop.statusAt();

  @override
  Widget build(BuildContext context) {
    final shop = widget.shop;
    final status = _status;
    final isOpen = status.isOpen;

    return Scaffold(
      backgroundColor: _ShopProfile.page,
      body: TapToDismissKeyboard(
        child: Stack(
          children: [
            // المحتوى القابل للتمرير: الغلاف ثم بطاقة الهوية ثم المنتجات
            AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _onRefresh,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _buildCover(shop)),
                  SliverToBoxAdapter(child: _buildIdentityCard(shop, status)),
                  SliverToBoxAdapter(child: _buildProductsHeader()),
                  if (_storeProducts.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Center(
                          child: Text(
                            _emptyListMessage,
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        _ShopProfile.margin,
                        4,
                        _ShopProfile.margin,
                        isOpen ? 90 : 30,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final product = _storeProducts[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: ProductCard(
                              product: product,
                              isStoreOpen: isOpen,
                              onTap: () => _openProduct(product),
                            ),
                          );
                        }, childCount: _storeProducts.length),
                      ),
                    ),
                ],
              ),
            ),

            // زر الرجوع (كبسولة كما في المرجع) + زر المفضلة: يبقيان ظاهرين
            // دائماً حتى لا يضيع الرجوع بعد التمرير.
            _buildTopControls(shop),
          ],
        ),
      ),

      // شريط سفلي عائم للسلة — يظهر فقط إذا كان الصيدلية مفتوحاً وهناك عناصر
      bottomSheet: !isOpen
          ? null
          : AnimatedBuilder(
              animation: CartService.instance,
              builder: (context, _) {
                final count = CartService.instance.totalItemCount;
                if (count == 0) return const SizedBox.shrink();

                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.shopping_bag_outlined,
                                color: AppColors.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '$count عناصر',
                                style: GoogleFonts.cairo(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'المجموع',
                                style: GoogleFonts.cairo(
                                  color: AppColors.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                CurrencyFormatter.format(
                                  CartService.instance.total,
                                ),
                                style: GoogleFonts.cairo(
                                  color: AppColors.primary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () {
                            void goToCart() {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const CartScreen(),
                                ),
                              );
                            }

                            if (AuthService.instance.isLoggedIn) {
                              // المستخدم مسجل دخوله: نفتح السلة مباشرة بلا خروج.
                              goToCart();
                            } else {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => LoginScreen(
                                    showBackButton: true,
                                    onLoginSuccess: goToCart,
                                  ),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: Text(
                            'عرض السلة',
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// الغلاف: صورة الصيدلية **كاملة** (BoxFit.contain) فوق تدرّج أخضر داكن، والنص
  /// على جهة البداية (يمين في RTL) كما في المرجع.
  Widget _buildCover(Shop shop) {
    final width = MediaQuery.sizeOf(context).width;
    final topInset = MediaQuery.paddingOf(context).top;
    const m = _ShopProfile.margin;
    // نسبة المرجع: ارتفاع الغلاف ≈ 0.42 من عرضه.
    final coverH = ((width - m * 2) * 0.42).clamp(150.0, 205.0).toDouble();
    final note = (shop.specialNote ?? '').trim();
    final headline = note.isEmpty ? shop.name : note;

    return Padding(
      padding: EdgeInsets.fromLTRB(m, topInset + 8, m, 0),
      child: SizedBox(
        height: coverH,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_ShopProfile.radius),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: _ShopProfile.coverGradient,
            ),
            child: Row(
              children: [
                // النص (يمين في RTL)
                Expanded(
                  flex: 45,
                  child: Padding(
                    // أعلى الغلاف فيه كبسولة الرجوع ⇒ النص يبدأ تحتها مباشرة
                    // حتى لا يلامسها أي اسم صيدلية.
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      18,
                      44,
                      6,
                      12,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 18.5,
                            fontWeight: FontWeight.w900,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          shop.categoryName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            color: Colors.white.withValues(alpha: 0.82),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // الصورة كاملة بلا قصّ ولا تمديد
                Expanded(
                  flex: 55,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: (shop.logoImage ?? '').isEmpty
                        ? Center(
                            child: Icon(
                              shop.logo,
                              color: Colors.white.withValues(alpha: 0.9),
                              size: coverH * 0.45,
                            ),
                          )
                        : AppImage(
                            shop.logoImage!,
                            // ★ الحل الجذري للقصّ: contain داخل مساحة الغلاف،
                            //   والخلفية التدرّج تملأ الفراغ حولها.
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            cacheWidth: 640,
                            loadingBuilder: (context, child, progress) =>
                                progress == null
                                ? child
                                : const AppImagePlaceholder(
                                    color: Colors.transparent,
                                  ),
                            errorBuilder: (_, _, _) => Icon(
                              shop.logo,
                              color: Colors.white.withValues(alpha: 0.9),
                              size: coverH * 0.45,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// كبسولة الرجوع + دائرة المفضلة فوق أعلى الغلاف.
  Widget _buildTopControls(Shop shop) {
    final topInset = MediaQuery.paddingOf(context).top;
    return PositionedDirectional(
      top: topInset + 20,
      start: _ShopProfile.margin + 10,
      end: _ShopProfile.margin + 10,
      // يتلاشى تدريجياً عند التمرير لأسفل بدل إضافة شريط ملوّن خلف الرأس
      child: AnimatedBuilder(
        animation: _scroll,
        builder: (context, inner) => IgnorePointer(
          ignoring: _controlsFade < 0.5,
          child: Opacity(opacity: _controlsFade, child: inner),
        ),
        child: Row(
          children: [
            // الرجوع: كبسولة بيضاء باسم الفئة كما في المرجع
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _ShopProfile.fieldBorder),
                    boxShadow: _ShopProfile.cardShadow,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_forward_rounded,
                        color: _ShopProfile.titleNavy,
                        size: 17,
                      ),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          shop.categoryName.isEmpty
                              ? 'رجوع'
                              : shop.categoryName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            color: _ShopProfile.titleNavy,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// بطاقة الهوية البيضاء: الشعار الدائري + الاسم + الحالة + أوقات العمل + البحث
  Widget _buildIdentityCard(Shop shop, ShopStatus status) {
    final isOpen = status.isOpen;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        _ShopProfile.margin,
        14,
        _ShopProfile.margin,
        0,
      ),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(_ShopProfile.radius),
        boxShadow: _ShopProfile.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 320;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _ProfileLogo(shop: shop, size: compact ? 62 : 72),
                  SizedBox(width: compact ? 10 : 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          shop.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.start,
                          style: GoogleFonts.cairo(
                            fontSize: compact ? 18 : 20,
                            fontWeight: FontWeight.w900,
                            color: _ShopProfile.titleNavy,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          shop.categoryName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StoreStatusTag(isOpen: isOpen),
                ],
              );
            },
          ),
          const SizedBox(height: 14),

          // بطاقة أوقات العمل (المساحة الزرقاء الفاتحة في المرجع)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: _ShopProfile.cardTint,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.access_time_filled_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'أوقات العمل الرسمية',
                        style: GoogleFonts.cairo(
                          color: AppColors.primary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        // ★ الوقت المحسوب من الجدول، لا نص القاعدة الخام.
                        status.windowLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          color: _ShopProfile.titleNavy,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // تنبيه إقفال السلة إذا كان الصيدلية مغلقةاً
          if (!isOpen) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.remove_shopping_cart_rounded,
                    color: AppColors.danger,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'السلة مقفلة: الصيدلية خارج أوقات العمل حالياً ولا يمكن إضافة طلبات جديدة.',
                      style: GoogleFonts.cairo(
                        color: AppColors.danger,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          // حقل البحث داخل الصيدلية (أبيض بحدود فاتحة كما في المرجع)
          TextField(
            onChanged: (v) => setState(() => _searchQuery = v),
            textAlign: TextAlign.start,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: 'ابحث في قائمة ${shop.name}...',
              hintStyle: GoogleFonts.cairo(
                color: AppColors.textHint,
                fontSize: 13,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: AppColors.textHint,
                size: 20,
              ),
              filled: true,
              fillColor: AppColors.surface,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(
                  color: _ShopProfile.fieldBorder,
                  width: 1.2,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(
                  color: AppColors.primary,
                  width: 1.4,
                ),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: _ShopProfile.fieldBorder),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// عنوان «قائمة المنتجات (n)»: النص على اليمين والأيقونة إلى يساره،
  /// وتحته شريط أقسام الصيدلية إن كانت له أقسام.
  Widget _buildProductsHeader() {
    // مرّة واحدة لكل بناء: العدد في الشريحة والمنتجات خلفها من نفس الحساب،
    // فلا تُكتب «كيك (٣)» ثم تفتح على منتجين.
    final shelves = _shelves;
    final selected = _selectedSectionId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _ShopProfile.margin + 2,
        20,
        _ShopProfile.margin,
        10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'قائمة المنتجات (${_storeProducts.length})',
                style: GoogleFonts.cairo(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: _ShopProfile.titleNavy,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.restaurant_menu_rounded,
                color: AppColors.primary,
                size: 21,
              ),
            ],
          ),
          // ★ الأقسام لا تظهر إلا إذا وُجدت فعلاً: صيدلية بلا قسم تبقى
          //   صفحته كما كانت بالضبط، بلا سطر زائد ولا فراغ إضافي.
          if (_sections.isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildSectionChips(shelves, selected),
          ],
        ],
      ),
    );
  }

  /// «الكل» ثم أقسام الصيدلية بترتيبها، ثم «بدون قسم» إن بقي منتج بلا موضع.
  /// القسم الفارغ يبقى في الشريط: الأدمن أضافه الآن، وإخفاؤه يوحي بأن
  /// إضافته لم تُقبل.
  Widget _buildSectionChips(
    Map<String, List<Product>> shelves,
    String? selected,
  ) {
    final unplaced = shelves[ShopSections.unplacedId] ?? const <Product>[];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          ShelfChip(
            label: 'الكل',
            count: _products.length,
            isSelected: selected == null,
            onTap: () => setState(() => _sectionId = null),
          ),
          for (final section in _sections)
            ShelfChip(
              label: section.title,
              count: (shelves[section.id] ?? const []).length,
              isSelected: selected == section.id,
              onTap: () => setState(() => _sectionId = section.id),
            ),
          if (unplaced.isNotEmpty)
            ShelfChip(
              label: ShopSections.unplacedLabel,
              count: unplaced.length,
              isSelected: selected == ShopSections.unplacedId,
              onTap: () => setState(() => _sectionId = ShopSections.unplacedId),
            ),
        ],
      ),
    );
  }

  /// نص «لا شيء هنا»: البحث أصدق سبب، ثم القسم الفارغ، ثم الصيدلية نفسه.
  String get _emptyListMessage {
    if (_searchQuery.trim().isNotEmpty) return 'لا توجد منتجات مطابقة للبحث';
    if (_selectedSectionId != null) return 'لا توجد منتجات في هذا القسم';
    return 'لا توجد منتجات في هذه الصيدلية';
  }
}

/// شريحة قسم داخل صفحة الصيدلية: [ShelfChip] في `widgets/shelf_chip.dart` —
/// نفس التي يراها الأدمن في شاشة منتجات الصيدلية.

class _StoreStatusTag extends StatelessWidget {
  const _StoreStatusTag({required this.isOpen});

  final bool isOpen;

  @override
  Widget build(BuildContext context) {
    final color = isOpen ? AppColors.success : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: isOpen ? AppColors.successLight : AppColors.dangerLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            isOpen ? 'مفتوح' : 'مغلق',
            style: GoogleFonts.cairo(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

/// شعار الصيدلية الدائري في صدارة بروفايل الصيدلية.
///
/// الصورة تُعرض بـ `BoxFit.contain` داخل الدائرة — لا قصّ ولا تمديد —
/// وفراغ حولها يملؤه لون فاتح من نفس الهوية.
class _ProfileLogo extends StatelessWidget {
  const _ProfileLogo({required this.shop, this.size = 72});

  final Shop shop;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasImage = shop.logoImage != null && shop.logoImage!.isNotEmpty;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
          width: 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1415151D),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: Container(
          // ★ مربّع الصورة يبقى أبيض ناصعاً (قاعدة الأدمن) لا بلون البطاقة.
          color: AppColors.imageBackground,
          child: hasImage
              ? AppImage(
                  shop.logoImage!,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  cacheWidth: 240,
                  cacheHeight: 240,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const AppImagePlaceholder(color: Colors.transparent),
                  errorBuilder: (_, _, _) => Icon(
                    shop.logo,
                    color: AppColors.primary,
                    size: size * 0.42,
                  ),
                )
              : Icon(shop.logo, color: AppColors.primary, size: size * 0.42),
        ),
      ),
    );
  }
}
