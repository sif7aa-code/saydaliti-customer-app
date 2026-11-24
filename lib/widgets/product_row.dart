import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../models/product.dart';
import '../services/cart_service.dart';
import 'app_image.dart';
import 'prescription_pill.dart';
import 'shop_gate.dart';
import 'soft_press.dart';

/// شريط منتجات أفقي (يملأ عرض الصفحة للتمرير يميناً ويساراً)
/// ببطاقات عمودية فاخرة: صورة بخلفية متدرجة، شارة خصم،
/// اسم المنتج وصيدليته، السعر وزر إضافة سريع للسلة.
class ProductRow extends StatelessWidget {
  const ProductRow({
    super.key,
    required this.products,
    this.closedShopIds = const <String>{},
    this.onProductTap,
  });

  final List<Product> products;
  final Set<String> closedShopIds;
  final ValueChanged<Product>? onProductTap;

  void _addToCart(BuildContext context, Product product, bool isOpen) {
    // ★ البوابة الوحيدة (وقت الصيدلية الآن)، و`isOpen` مجرد وصف من الشاشة
    //   تُرجع إليه الأمور حين لا يكون جدول الصيدلية معروفاً بعد.
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
          content: Text(
            'تمت إضافة "${product.name}" إلى السلة',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700, fontSize: 13),
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
    if (products.isEmpty) return const SizedBox.shrink();

    // ★ المرجع (2026-10-26): بطاقتان تملأان عرض الصفحة (هامش 16 عن الحافة
    //   + فراغ 10 بينهما). القياسات المقيسة من الصورة (÷1.6): عرض البطاقة
    //   166، منطقة الصورة 86، محتوى البطاقة 86 ⇒ نسبة الصورة ≈ 0.56 من
    //   العرض، والارتفاع الكلي = الصورة + 120.
    // ★ 2026-10-26: طلب الأدمن «كبّر حجم صور المنتجات في البطاقة» — نسبة
    //   الصورة من عرض البطاقة 0.68 (الارتفاع 96 → ≈122 على هاتف 411dp)،
    //   وارتفاع الشريط يتبع الصورة تلقائياً.
    // ★ 2026-11-17: ميزانية المحتوى 120 → 136: أسماء منتجات الصيدليات
    //   أطول فتلتف لسطرين، فكان العمود يتجاوز حيّزه بـ13px.
    final screenWidth = MediaQuery.sizeOf(context).width;
    final cardWidth = ((screenWidth - 24 - 10) / 2).clamp(150.0, 190.0);
    final imageHeight = (cardWidth * 0.68).clamp(102.0, 126.0);

    return SizedBox(
      height: imageHeight + 136,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: products.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final product = products[index];
          final isOpen = ShopGate.isOpen(
            shopId: product.shopId,
            fallbackOpen: !closedShopIds.contains(product.shopId),
          );
          return _HProductCard(
            product: product,
            width: cardWidth,
            imageHeight: imageHeight,
            isStoreOpen: isOpen,
            onTap: () => onProductTap?.call(product),
            onAdd: () => _addToCart(context, product, isOpen),
          );
        },
      ),
    );
  }
}

/// بطاقة المنتج العمودية داخل الشريط الأفقي.
class _HProductCard extends StatelessWidget {
  const _HProductCard({
    required this.product,
    required this.width,
    required this.imageHeight,
    required this.isStoreOpen,
    required this.onTap,
    required this.onAdd,
  });

  final Product product;

  /// عرض البطاقة وارتفاع منطقة الصورة — تُحسبان من عرض الشاشة في
  /// [ProductRow] لتطابق نسب المرجع على كل المقاسات.
  final double width;
  final double imageHeight;

  final bool isStoreOpen;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final hasDiscount = product.discountPercent > 0;
    final hasImage = product.logoImage != null && product.logoImage!.isNotEmpty;

    return SizedBox(
      width: width,
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.divider, width: 1.2),
        ),
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // صورة المنتج على خلفية بيضاء نقية: البطاقة كلها بيضاء.
              SizedBox(
                height: imageHeight,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(color: AppColors.surface),
                    ),
                    if (hasImage)
                      Padding(
                        // ★ نفس قاعدة البطاقتين: `contain` + هامش داخلي،
                        //   فالصورة كاملة داخل الإطار مهما اختلفت مقاساتها.
                        padding: const EdgeInsets.all(8),
                        child: AppImage(
                          product.logoImage!,
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.medium,
                          cacheWidth: 420,
                          cacheHeight: 420,
                          // بديل ثابت بدل مؤشر تحميل متحرك لكل بطاقة.
                          loadingBuilder: (context, child, progress) =>
                              progress == null
                              ? child
                              : const AppImagePlaceholder(
                                  color: AppColors.surface,
                                ),
                          errorBuilder: (_, _, _) => Center(
                            child: Icon(
                              product.logo ?? Icons.shopping_bag_rounded,
                              color: AppColors.primary,
                              size: 34,
                            ),
                          ),
                        ),
                      )
                    else
                      Center(
                        child: Icon(
                          product.logo ?? Icons.shopping_bag_rounded,
                          color: AppColors.primary,
                          size: 34,
                        ),
                      ),
                    if (hasDiscount)
                      // ★ المرجع: شارة الخصم **كبسولة** مسطّحة في أعلى يسار
                      //   الصورة (ارتفاع 19 لوجي، نصف قطر كامل، بلا حدّ
                      //   أبيض ولا ظل) بلون `#FA4663` المقيس من الصورة.
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.danger,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Text(
                            'خصم ${product.discountPercent.toInt()}٪',
                            style: GoogleFonts.cairo(
                              color: Colors.white,
                              fontSize: 11.5,
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    if (product.requiresPrescription)
                      const Positioned(
                        bottom: 8,
                        right: 8,
                        child: PrescriptionPill(),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
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
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.storefront_rounded,
                            size: 12,
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
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              CurrencyFormatter.format(product.price),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.cairo(
                                // ★ المرجع (2026-10-26): السعر **أخضر**
                                //   `#15A065` غامق، وبجانبه السعر القديم
                                //   مشطوباً رمادياً إن وُجد.
                                color: isStoreOpen
                                    ? AppColors.primary
                                    : AppColors.textHint,
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (product.oldPrice != null &&
                              product.oldPrice! > product.price) ...[
                            const SizedBox(width: 6),
                            Text(
                              CurrencyFormatter.format(product.oldPrice!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.cairo(
                                color: AppColors.textHint,
                                fontSize: 11,
                                decoration: TextDecoration.lineThrough,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 7),
                      // المرجع: زر الإضافة يملأ عرض البطاقة بالكامل.
                      _AddButton(isStoreOpen: isStoreOpen, onTap: onAdd),
                    ],
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

/// زر الإضافة داخل بطاقة المرجع: **كبسولة خضراء تملأ عرض البطاقة**
/// (ارتفاع 34، نصف قطر = نصف الارتفاع، مسطّح بلا ظل) بأيقونة سلة بيضاء.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.isStoreOpen, required this.onTap});

  final bool isStoreOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SoftPress(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            width: double.infinity,
            height: 34,
            decoration: BoxDecoration(
              gradient: isStoreOpen ? AppColors.buttonGradient : null,
              color: isStoreOpen ? null : AppColors.surfaceTint,
              borderRadius: BorderRadius.circular(17),
              border: isStoreOpen ? null : Border.all(color: AppColors.divider),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  isStoreOpen ? 'أضف إلى السلة' : 'مغلق',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                    color: isStoreOpen ? Colors.white : AppColors.textHint,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  isStoreOpen
                      ? Icons.shopping_cart_rounded
                      : Icons.lock_outline_rounded,
                  color: isStoreOpen ? Colors.white : AppColors.textHint,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
