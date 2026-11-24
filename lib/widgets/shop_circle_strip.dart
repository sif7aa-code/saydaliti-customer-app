import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/shop.dart';
import 'app_image.dart';

class ShopCircleStrip extends StatelessWidget {
  const ShopCircleStrip({super.key, required this.shops, this.onShopTap});

  final List<Shop> shops;
  final ValueChanged<Shop>? onShopTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        clipBehavior: Clip.none,
        itemCount: shops.length,
        separatorBuilder: (context, index) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final shop = shops[index];
          return _ShopCircle(
            shop: shop,
            onTap: onShopTap == null ? null : () => onShopTap!(shop),
          );
        },
      ),
    );
  }
}

class _ShopCircle extends StatelessWidget {
  const _ShopCircle({required this.shop, this.onTap});

  final Shop shop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = shop.logoImage != null && shop.logoImage!.isNotEmpty;
    final isOpen = shop.isOpen;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 128,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 104,
                  height: 104,
                  // ★ الحشو الداخلي يبقي الصورة داخل الحلقة البيضاء: الطفل
                  //   يملأ صندوق الـContainer كامل (منطقة الحدود) إذا لم
                  //   تُزحزح، فتظهر صورة الصيدلية «خارج الحدود».
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.imageBackground,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.07),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                    border: Border.all(
                      color: isOpen ? Colors.white : AppColors.divider,
                      width: 3,
                    ),
                  ),
                  child: ClipOval(
                    // القصّ على الدائرة الداخلية نفسها، لا على الحافة الخارجية.
                    child: hasImage
                        ? AppImage(
                            shop.logoImage!,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            cacheWidth: 260,
                            cacheHeight: 260,
                            // بديل ثابت: لا `AnimationController` لكل شعار.
                            loadingBuilder: (context, child, progress) =>
                                progress == null
                                ? child
                                : const AppImagePlaceholder(),
                            errorBuilder: (_, _, _) => Icon(
                              shop.logo,
                              color: AppColors.primary,
                              size: 42,
                            ),
                          )
                        : Icon(shop.logo, color: AppColors.primary, size: 42),
                  ),
                ),
                // شارة الحالة (مفتوح / مغلق)
                Positioned(
                  bottom: 0,
                  right: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isOpen ? AppColors.success : AppColors.danger,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Text(
                      isOpen ? 'مفتوح' : 'مغلق',
                      style: GoogleFonts.cairo(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // اسم الصيدلية كاملاً حتى 3 أسطر
            Text(
              shop.name,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 11.5,
                height: 1.25,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
