import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/shop_display.dart';
import '../models/product.dart';
import '../services/cart_service.dart';
import '../services/real_data_service.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/image_viewer.dart';
import '../widgets/shop_gate.dart';

/// شاشة تفاصيل المنتج مع إمكانية التنقل بالسحب بين منتجات الصيدلية نفسه.
class ProductDetailsScreen extends StatefulWidget {
  const ProductDetailsScreen({
    super.key,
    required this.products,
    required this.initialIndex,
    this.isStoreOpen = true,
    this.showPharmacyInfo = true,
  });

  final List<Product> products;
  final int initialIndex;
  final bool isStoreOpen;

  /// ★ false inside home directory sections: the product stands alone —
  ///   no pharmacy name, status pill, or "swipe between shop products" hint.
  final bool showPharmacyInfo;

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _currentIndex = widget.initialIndex;
  bool _isFavorite = false;

  /// نسخة قابلة للتحديث من قائمة منتجات الصيدلية (السحب يجلب أحدث نسخة
  /// من الاسم/السعر/الصورة بدل الاعتماد على ما مرّرته الشاشة السابقة).
  late List<Product> _products = List<Product>.of(widget.products);

  Product get _current => _products[_currentIndex];

  /// السحب للتحديث: يُسقط كاش الكتالوج ثم يجلب منتجات الصيدلية من
  /// الشبكة، ويُبقي المنتج الحالي معروضاً (ويتبعه إن تغيّر ترتيبه).
  Future<void> _refresh() async {
    final cur = _current;
    try {
      await RealDataService.instance.refreshProducts();
      final fresh = await RealDataService.instance.fetchProducts(
        shopId: cur.shopId,
      );
      if (!mounted || fresh.isEmpty) return;
      final idx = fresh.indexWhere((p) => p.id == cur.id);
      if (idx < 0) return;
      setState(() {
        _products = fresh;
        _currentIndex = idx;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpToPage(idx);
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// ★ حالة صيدلية هذا المنتج **الآن** من وقته، لا من معلومة التقطتها
  ///   الشاشة قبل دقائق: [ProductDetailsScreen.isStoreOpen] تبقى مجرد
  ///   وصف بديل يُرجع إليه حين لا يكون جدول الصيدلية مسجَّلاً بعد.
  bool get _storeOpen => ShopGate.isOpen(
    shopId: _current.shopId,
    fallbackOpen: widget.isStoreOpen,
  );

  void _addToCart() {
    if (ShopGate.refuseIfNeeded(
      context,
      shopId: _current.shopId,
      shopName: _current.shopName,
      fallbackOpen: widget.isStoreOpen,
    )) {
      return;
    }

    final block = CartService.instance.addToCart(_current);
    if (block != null) {
      ShopGate.showBlocked(context, block);
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'تمت إضافة "${_current.name}" إلى السلة',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.surfaceTint,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.arrow_forward_rounded,
              color: AppColors.textPrimary,
              size: 20,
            ),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          // عدّاد الصفحات بلا معنى لمنتجٍ وحده.
          if (widget.products.length > 1)
            Text(
              '${_currentIndex + 1} / ${widget.products.length}',
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          IconButton(
            icon: Icon(
              _isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: _isFavorite ? AppColors.favorite : AppColors.textPrimary,
            ),
            onPressed: () => setState(() => _isFavorite = !_isFavorite),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _products.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (context, index) {
          return _ProductDetailsView(
            product: _products[index],
            onRefresh: _refresh,
            isStoreOpen: ShopGate.isOpen(
              shopId: _products[index].shopId,
              fallbackOpen: widget.isStoreOpen,
            ),
            showPharmacyInfo: widget.showPharmacyInfo,
            onShopTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    shopDisplayName(_products[index].shopName),
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                  ),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: CartService.instance,
        builder: (context, _) {
          final p = _current;
          return SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 270;
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'السعر',
                              style: GoogleFonts.cairo(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Wrap(
                              spacing: 6,
                              runSpacing: 1,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  CurrencyFormatter.format(p.price),
                                  style: GoogleFonts.cairo(
                                    color: AppColors.primary,
                                    fontSize: compact ? 16 : 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                if (p.oldPrice != null && p.oldPrice! > p.price)
                                  Text(
                                    CurrencyFormatter.format(p.oldPrice!),
                                    style: GoogleFonts.cairo(
                                      color: AppColors.textHint,
                                      fontSize: 11,
                                      decoration: TextDecoration.lineThrough,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _addToCart,
                        icon: Icon(
                          _storeOpen
                              ? Icons.add_shopping_cart_rounded
                              : Icons.lock_outline_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _storeOpen
                              ? (compact ? 'أضف' : 'أضف إلى السلة')
                              : 'مغلق',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 12 : 18,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ProductAvailabilityPill extends StatelessWidget {
  const _ProductAvailabilityPill({required this.isStoreOpen});

  final bool isStoreOpen;

  @override
  Widget build(BuildContext context) {
    final color = isStoreOpen ? AppColors.success : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isStoreOpen
                ? Icons.check_circle_rounded
                : Icons.lock_outline_rounded,
            color: color,
            size: 15,
          ),
          const SizedBox(width: 4),
          Text(
            isStoreOpen ? 'متوفر الآن' : 'الصيدلية مغلقة',
            style: GoogleFonts.cairo(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductDetailsView extends StatelessWidget {
  const _ProductDetailsView({
    required this.product,
    required this.isStoreOpen,
    required this.showPharmacyInfo,
    required this.onShopTap,
    required this.onRefresh,
  });

  final Product product;
  final bool isStoreOpen;
  final bool showPharmacyInfo;
  final VoidCallback onShopTap;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final hasDiscount = product.discountPercent > 0;
    // ★ 2026-10-26: صورة أكبر في صفحة المنتج (0.72 → 0.86 من عرض الشاشة،
    //   والحد الأعلى 330 → 400) بطلب الأدمن. الشاشة قابلة للتمرير فالتكبير
    //   لا يضغط أي عنصر.
    final imageHeight = (MediaQuery.sizeOf(context).width * 0.86)
        .clamp(280.0, 400.0)
        .toDouble();

    return AppRefreshIndicator(
      onRefresh: onRefresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // صورة المنتج: بعرض كامل بلا حواف ولا إطار، والصورة تظهر كاملة
            // على خلفية موحّدة اللون.
            Container(
              margin: EdgeInsets.zero,
              height: imageHeight,
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.zero,
                color: AppColors.imageBackground,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  product.logoImage != null && product.logoImage!.isNotEmpty
                      ? TappableImage(
                          url: product.logoImage,
                          title: product.name,
                          // ★ الصورة تظهر **كاملة**: `contain` + هامش داخلي،
                          //   فلا تُقصّ من أي جهة ولا تلامس حافة الإطار.
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: AppImage(
                              product.logoImage!,
                              fit: BoxFit.contain,
                              alignment: Alignment.center,
                              filterQuality: FilterQuality.high,
                              // ★ ٨٠٠ = أعلى دلو: يُلغي التحويل على الخادم
                              //   ويطلب **الأصل** كاملاً لهذه الصورة الكبيرة،
                              //   فلا قصّ من أي جهة وبلا ضبابية على شاشة ٣×.
                              cacheWidth: 800,
                              errorBuilder: (_, _, _) => Center(
                                child: Icon(
                                  product.logo ?? Icons.fastfood_rounded,
                                  color: AppColors.primary,
                                  size: 64,
                                ),
                              ),
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            product.logo ?? Icons.fastfood_rounded,
                            color: AppColors.primary,
                            size: 64,
                          ),
                        ),
                  if (hasDiscount)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.warning.withValues(alpha: 0.28),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Text(
                          'خصم ${product.discountPercent.toInt()}٪',
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showPharmacyInfo) ...[
                    Text(
                      product.shopName,
                      style: GoogleFonts.cairo(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    product.name,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // تسلسل سعر واضح: الحالي أولاً، ثم المقارنة والحالة.
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'السعر الآن',
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            CurrencyFormatter.format(product.price),
                            style: GoogleFonts.cairo(
                              color: AppColors.primary,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      if (product.oldPrice != null &&
                          product.oldPrice! > product.price)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'بدلاً من',
                              style: GoogleFonts.cairo(
                                color: AppColors.textHint,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              CurrencyFormatter.format(product.oldPrice!),
                              style: GoogleFonts.cairo(
                                color: AppColors.textHint,
                                fontSize: 13,
                                decoration: TextDecoration.lineThrough,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      if (showPharmacyInfo)
                        _ProductAvailabilityPill(isStoreOpen: isStoreOpen),
                    ],
                  ),
                  // ★ دواء يتطلب وصفة: يُعلَن للزبون قبل الإضافة — عند
                  //   الطلب سيُطلب منه إرفاق صورة الوصفة.
                  if (product.requiresPrescription) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.warning.withValues(alpha: 0.40),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.medical_information_rounded,
                            color: AppColors.warning,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'هذا الدواء يتطلب وصفة طبية — ستُطلب منك صورة '
                              'الوصفة عند إتمام الطلب',
                              style: GoogleFonts.cairo(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (product.specialNote != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.local_offer_rounded,
                            color: AppColors.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              product.specialNote!,
                              style: GoogleFonts.cairo(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (showPharmacyInfo) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceTint.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.swipe_rounded,
                            color: AppColors.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'اسحب يميناً أو يساراً للتنقل بين منتجات الصيدلية',
                              style: GoogleFonts.cairo(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
