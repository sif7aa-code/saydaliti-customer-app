import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/shop.dart';
import 'app_image.dart';

class ShopCard extends StatelessWidget {
  const ShopCard({super.key, required this.shop, this.onTap});

  final Shop shop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = AppColors.primary;
    final isOpen = shop.isOpen;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isOpen
                  ? AppColors.primary.withValues(alpha: 0.2)
                  : AppColors.divider,
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              // غلاف الصيدلية (Cover) — لون مميز بأيقونة كبيرة وشارة الحالة
              Container(
                height: 116,
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [bg, Color.lerp(bg, Colors.black, 0.22)!],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                ),
                child: Stack(
                  children: [
                    // نمط زخرفي خفيف
                    Positioned(
                      left: -26,
                      top: -34,
                      child: Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 70,
                      bottom: -40,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      right: 14,
                      child: _OpenStatusBadge(isOpen: isOpen),
                    ),
                    // شارة التصنيف في الجهة المقابلة
                    if (shop.categoryName.isNotEmpty)
                      Positioned(
                        top: 10,
                        left: 14,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.category_rounded,
                                color: Colors.white,
                                size: 12,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                shop.categoryName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.cairo(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // الشعار على الغلاف
                    Center(child: _Logo(shop: shop, size: 88)),
                  ],
                ),
              ),

              // محتوى البطاقة
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // اسم الصيدلية كاملاً
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            shop.name,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              color: AppColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              height: 1.25,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _OpenStoreButton(isOpen: isOpen, color: bg),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // وقت العمل الكامل
                    Row(
                      children: [
                        Icon(
                          Icons.access_time_rounded,
                          size: 14,
                          color: isOpen
                              ? AppColors.primary
                              : AppColors.textHint,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${shop.workingHours}  •  ${shop.workingDays}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              color: isOpen
                                  ? AppColors.textSecondary
                                  : AppColors.danger,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (shop.specialNote != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isOpen
                              ? AppColors.primaryLight
                              : AppColors.danger.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isOpen
                                  ? Icons.local_offer_outlined
                                  : Icons.info_outline_rounded,
                              size: 15,
                              color: isOpen
                                  ? AppColors.primary
                                  : AppColors.danger,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                shop.specialNote!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.cairo(
                                  color: isOpen
                                      ? AppColors.primary
                                      : AppColors.danger,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
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
      ),
    );
  }
}

class _OpenStatusBadge extends StatelessWidget {
  const _OpenStatusBadge({required this.isOpen});

  final bool isOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: isOpen
            ? Colors.white.withValues(alpha: 0.95)
            : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: isOpen ? AppColors.success : AppColors.danger,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            isOpen ? 'مفتوح الآن' : 'مغلق',
            style: GoogleFonts.cairo(
              color: isOpen ? AppColors.success : Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.shop, this.size = 90});

  final Shop shop;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasImage = shop.logoImage != null && shop.logoImage!.isNotEmpty;
    return Container(
      width: size,
      height: size,
      // ★ حشو داخلي + قصّ على المستطيل الداخلي: الشعار لا يغطي الإطار
      //   الأبيض ولا يخرج عنه.
      padding: EdgeInsets.all(size * 0.045),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.20),
        child: hasImage
            ? AppImage(
                shop.logoImage!,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                cacheWidth: 280,
                cacheHeight: 280,
                // كان مؤشراً **حتمياً** (determinate): يُعاد بناء البطاقة مع
                // كل حدث تقدّم في التحميل، أي عشرات المرات لكل صورة شعار.
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const AppImagePlaceholder(),
                errorBuilder: (_, _, _) =>
                    Icon(shop.logo, color: Colors.white, size: size * 0.48),
              )
            : Icon(shop.logo, color: Colors.white, size: size * 0.48),
      ),
    );
  }
}

class _OpenStoreButton extends StatelessWidget {
  const _OpenStoreButton({required this.isOpen, required this.color});

  final bool isOpen;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: isOpen ? AppColors.primary : AppColors.surfaceTint,
        borderRadius: BorderRadius.circular(14),
        boxShadow: isOpen
            ? [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
        border: isOpen ? null : Border.all(color: AppColors.divider),
      ),
      child: Icon(
        Icons.chevron_left_rounded,
        color: isOpen ? Colors.white : AppColors.textHint,
        size: 24,
      ),
    );
  }
}
