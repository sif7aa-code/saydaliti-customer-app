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

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.showShopName = false,
    this.isStoreOpen = true,
    this.onTap,
  });

  final Product product;
  final bool showShopName;
  final bool isStoreOpen;
  final VoidCallback? onTap;

  void _onAddToCart(BuildContext context) {
    // ★ البوابة الوحيدة: الوقت الحالي هو الحكم، ورسالتها تقول متى يفتح
    //   الصيدلية بالتحديد. [isStoreOpen] تبقى وصفاً للواجهة (اللون والشارة)
    //   ولا تملك وحدها أن تفتح السلة أو تغلقها.
    if (ShopGate.refuseIfNeeded(
      context,
      shopId: product.shopId,
      shopName: product.shopName,
      fallbackOpen: isStoreOpen,
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
    final hasDiscount = product.discountPercent > 0;
    // ★ 2026-10-23: البطاقة أصغر قليلاً (صورة وحاشية أخف) والخط أكبر
    //   قليلاً — طلب الأدمن، بلا أي تغيير في السلوك أو البيانات.
    // ★ 2026-10-26: صورة أكبر (86/100 → 100/118) بطلب الأدمن «كبّر حجم
    //   صور المنتجات في البطاقة» — الحاشية والخط والسلوك كما هي.
    final isCompact = MediaQuery.sizeOf(context).width <= 340;
    final imageSize = isCompact ? 100.0 : 118.0;

    return InkWell(
      onTap: onTap,
      // ★ 14 = نصف قطر البطاقة المقاس من الصورة المرجعية
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: EdgeInsets.all(isCompact ? 9 : 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.divider,
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.035),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: imageSize,
                  height: imageSize,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.imageBorder),
                  ),
                  child:
                      product.logoImage != null && product.logoImage!.isNotEmpty
                      ? Padding(
                          // ★ هامش داخلي: الصورة تظهر كاملة داخل الإطار،
                          // لا طالعة الحافة ولا مقصوصة من أي جهة.
                          padding: EdgeInsets.all(imageSize * 0.06),
                          child: AppImage(
                            product.logoImage!,
                            fit: BoxFit.contain,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.medium,
                            cacheWidth: 360,
                            cacheHeight: 360,
                            // بديل ثابت: مؤشر التحميل هنا كان يضيف
                            // `AnimationController` لكل بطاقة في القائمة.
                            loadingBuilder: (context, child, progress) =>
                                progress == null
                                ? child
                                : const AppImagePlaceholder(
                                    color: AppColors.surface,
                                  ),
                            errorBuilder: (_, _, _) => Icon(
                              product.logo ?? Icons.fastfood_rounded,
                              color: AppColors.primary,
                              size: 34,
                            ),
                          ),
                        )
                      : Center(
                          child: Icon(
                            product.logo ?? Icons.fastfood_rounded,
                            color: AppColors.primary,
                            size: 34,
                          ),
                        ),
                ),
                if (hasDiscount)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        // ★ شارة مسطّحة بيضاوية مثل المرجع: بلا إطار
                        //   أبيض وبلا ظل، ونصف قطرها = نصف ارتفاعها.
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
                    bottom: 6,
                    left: 6,
                    child: PrescriptionPill(),
                  ),
              ],
            ),
            SizedBox(width: isCompact ? 9 : 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      color: isStoreOpen
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: isCompact ? 15 : 16,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  if (showShopName) ...[
                    const SizedBox(height: 2),
                    Text(
                      product.shopName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (product.specialNote != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      product.specialNote!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        color: AppColors.primary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        CurrencyFormatter.format(product.price),
                        style: GoogleFonts.cairo(
                          // ★ السعر أخضر #15A065 — مقاس من نص السعر في
                          //   الصورة المرجعية (عينة #1A9F60 / #15A065).
                          color: isStoreOpen
                              ? AppColors.primary
                              : AppColors.textSecondary,
                          fontSize: isCompact ? 16 : 17.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (product.oldPrice != null &&
                          product.oldPrice! > product.price)
                        Text(
                          CurrencyFormatter.format(product.oldPrice!),
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
            SizedBox(width: isCompact ? 5 : 7),
            _AddToCartButton(
              isStoreOpen: isStoreOpen,
              compact: isCompact,
              onTap: () => _onAddToCart(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddToCartButton extends StatelessWidget {
  const _AddToCartButton({
    required this.isStoreOpen,
    required this.compact,
    required this.onTap,
  });

  final bool isStoreOpen;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = isStoreOpen
        ? Icons.add_shopping_cart_rounded
        : Icons.lock_outline_rounded;
    final color = isStoreOpen ? Colors.white : AppColors.textHint;

    // بدون `Tooltip`: كل بطاقة تنتج واحداً (مؤقّت ضغط طويل + مُدخل
    // overlay)، و٢٠٠ بطاقة = ٢٠٠ نسخة لرسالة لا معنى لها على اللمس
    // أصلاً. النص موجود داخل الزر نفسه.
    return SoftPress(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            width: compact ? 34 : null,
            height: 34,
            padding: compact
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 13, vertical: 0),
            decoration: BoxDecoration(
              // ★ زر مسطّح بيضاوي مثل المرجع: لون #15A065 الصافي بلا ظل.
              gradient: isStoreOpen ? AppColors.buttonGradient : null,
              color: isStoreOpen ? null : AppColors.surfaceTint,
              borderRadius: BorderRadius.circular(17),
              border: isStoreOpen ? null : Border.all(color: AppColors.divider),
            ),
            child: compact
                ? Icon(icon, color: color, size: 19)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: color, size: 18),
                      const SizedBox(width: 5),
                      Text(
                        isStoreOpen ? 'أضف' : 'مغلق',
                        style: GoogleFonts.cairo(
                          color: color,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
