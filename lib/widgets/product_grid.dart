import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../models/product.dart';
import '../services/cart_service.dart';
import 'app_image.dart';
import 'prescription_pill.dart';
import 'shop_gate.dart';

/// ★ نسبة عرض صورة المنتج إلى ارتفاعها داخل بطاقة الشبكة (2026-10-26:
///   1.05 → 0.82 تعني صورة أطول بطلب الأدمن). **مصدر واحد**: ارتفاع
///   الخلية يُشتقّ منها فلا تفيض البطاقة على أي عرض.
const double _kTileImageAspect = 0.82;

/// شبكة منتجات مرنة: عدد الأعمدة يزداد مع اتساع الشاشة حتى تستفيد الواجهة
/// من العرض الكامل على جميع الهواتف. البطاقة العمودية تميّز السعر بصرياً
/// وتفصل المنتج عن بروفايلات الصيدليات.
class ProductGrid extends StatelessWidget {
  const ProductGrid({
    super.key,
    required this.products,
    required this.onProductTap,
    this.closedShopIds = const <String>{},
  });

  final List<Product> products;
  final ValueChanged<Product> onProductTap;
  final Set<String> closedShopIds;

  void _addToCart(BuildContext context, Product product, bool isOpen) {
    // ★ البوابة الوحيدة: وقت الصيدلية الآن هو الحكم، والنص يقول متى يفتح.
    if (ShopGate.refuseIfNeeded(
      context,
      shopId: product.shopId,
      shopName: product.shopName,
      fallbackOpen: isOpen,
    )) {
      return;
    }

    final block = CartService.instance.addToCart(product);
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
                  'تمت إضافة "${product.name}" إلى السلة',
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 720
            ? 4
            : width >= 500
                ? 3
                : 2;
        final cellWidth = (width - 12 * (columns - 1)) / columns;
        // ارتفاع ثابت لكل خلية يتناسب مع العرض حتى لا تفيض البطاقة على
        // أي هاتف (ضيق أو واسع).
        final mainAxisExtent = cellWidth / _kTileImageAspect + 116;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
            mainAxisExtent: mainAxisExtent,
          ),
          itemCount: products.length,
          itemBuilder: (context, index) {
            final product = products[index];
            final isStoreOpen = ShopGate.isOpen(
              shopId: product.shopId,
              fallbackOpen: !closedShopIds.contains(product.shopId),
            );
            return _ProductTile(
              product: product,
              isStoreOpen: isStoreOpen,
              onTap: () => onProductTap(product),
              onAdd: () => _addToCart(context, product, isStoreOpen),
            );
          },
        );
      },
    );
  }
}

/// بطاقة منتج عمودية فاخرة مع تمييز واضح للسعر.
class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.isStoreOpen,
    required this.onTap,
    required this.onAdd,
  });

  final Product product;
  final bool isStoreOpen;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final hasDiscount = product.discountPercent > 0;
    final hasImage = product.logoImage != null && product.logoImage!.isNotEmpty;

    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        // ★ 14 = نصف قطر البطاقة المقاس من الصورة المرجعية، والحدّ رمادي
        //   رفيع ثابت (المرجع لا يلوّن حدّ البطاقة بالأخضر).
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.divider, width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // صورة المنتج على خلفية بيضاء نقية: البطاقة كلها بيضاء.
            // ★ 2026-10-26: النسبة 1.05 → 0.82 تعني صورة أطول داخل نفس
            //   عرض البطاقة (≈145 بدل ≈113 على شبكة من عمودين)، بطلب
            //   الأدمن تكبير صور المنتجات.
            AspectRatio(
              aspectRatio: _kTileImageAspect,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                    ),
                  ),
                  if (hasImage)
                    Padding(
                      // ★ `contain` + هامش: أي صورة (كبيرة أو صغيرة أو غير
                      //   متناسقة الأبعاد) تظهر كاملة بلا قصّ ولا خروج عن
                      //   حدود البطاقة، وبلا ملامسة لحافة الإطار.
                      padding: const EdgeInsets.all(8),
                      child: AppImage(
                        product.logoImage!,
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        filterQuality: FilterQuality.high,
                        cacheWidth: 380,
                        cacheHeight: 380,
                        loadingBuilder: (context, child, progress) =>
                            progress == null
                                ? child
                                : const AppImagePlaceholder(
                                    color: AppColors.surface,
                                  ),
                        errorBuilder: (_, _, _) => Center(
                          child: Icon(
                            product.logo ?? Icons.fastfood_rounded,
                            color: AppColors.primary,
                            size: 40,
                          ),
                        ),
                      ),
                    )
                  else
                    Center(
                      child: Icon(
                        product.logo ?? Icons.fastfood_rounded,
                        color: AppColors.primary,
                        size: 40,
                      ),
                    ),
                  if (hasDiscount)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          // ★ بيضاوية مسطّحة مثل المرجع: بلا إطار أبيض ولا ظل.
                          color: AppColors.danger,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          'خصم ${product.discountPercent.toInt()}٪',
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 11.5,
                            height: 1.1,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  if (product.requiresPrescription)
                    const Positioned(
                      bottom: 8,
                      left: 8,
                      child: PrescriptionPill(),
                    ),
                ],
              ),
            ),
            // بيانات المنتج مع سعر بارز
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        color: isStoreOpen
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.storefront_rounded,
                          size: 11,
                          color: isStoreOpen
                              ? AppColors.primary
                              : AppColors.textHint,
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            product.shopName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              color: AppColors.textSecondary,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                CurrencyFormatter.format(product.price),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.cairo(
                                  // ★ السعر أخضر #15A065 — مقاس من نص السعر
                                  //   في المرجع (عينة #1A9F60).
                                  color: isStoreOpen
                                      ? AppColors.primary
                                      : AppColors.textHint,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  height: 1.1,
                                ),
                              ),
                              if (product.oldPrice != null &&
                                  product.oldPrice! > product.price)
                                Text(
                                  CurrencyFormatter.format(product.oldPrice!),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.cairo(
                                    color: AppColors.textHint,
                                    fontSize: 9.5,
                                    decoration: TextDecoration.lineThrough,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        _QuickAddButton(
                          isStoreOpen: isStoreOpen,
                          onTap: onAdd,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAddButton extends StatelessWidget {
  const _QuickAddButton({
    required this.isStoreOpen,
    required this.onTap,
  });

  final bool isStoreOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            // ★ دائرة/كبسولة خضراء مسطّحة (بلا ظل) بلون زر المرجع.
            gradient: isStoreOpen ? AppColors.buttonGradient : null,
            color: isStoreOpen ? null : AppColors.surfaceTint,
            borderRadius: BorderRadius.circular(17),
            border: isStoreOpen ? null : Border.all(color: AppColors.divider),
          ),
          child: Icon(
            isStoreOpen
                ? Icons.add_shopping_cart_rounded
                : Icons.lock_outline_rounded,
            color: isStoreOpen ? Colors.white : AppColors.textHint,
            size: 17,
          ),
        ),
      ),
    );
  }
}