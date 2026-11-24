import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/category_item.dart';

/// ★ 2026-11-20 — شريط أقسام تبويب «الأدوية» صار **شرائح** كدليل الأطباء:
///   الأقراص الدائرية القديمة (٧٨px مع اسم تحتها) كانت أعلى الصفحة وأثقل
///   من بقية الصفحات المنقّحة، فصارت الشريحة بارتفاع ٣٦ كل الأقسام فيها
///   بنفس لغة دليل الأطباء (أبيض بحدّ فاتح، و«المزيد» بطميّ) بلا تغيير
///   في السلوك: النقر يفتح القسم أو ورقة «جميع الأقسام».
class CategoryStrip extends StatelessWidget {
  const CategoryStrip({
    super.key,
    required this.categories,
    this.onCategoryTap,
  });

  final List<CategoryItem> categories;
  final ValueChanged<CategoryItem>? onCategoryTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // بلا حشو داخلي: الشاشة الرئيسية تمرّر هامشها الأفقي نفسه
        // لبقية البطاقات، فيصطفّ أول قسم مع حافة بطاقة الترحيب.
        padding: EdgeInsets.zero,
        itemCount: categories.length + 1,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          // العنصر الأخير هو زر "المزيد".
          if (index == categories.length) {
            return _CategoryPill(
              label: 'المزيد',
              icon: Icons.apps_rounded,
              highlighted: true,
              onTap: () => onCategoryTap?.call(
                CategoryItem(
                  id: 'more',
                  title: 'المزيد',
                  icon: Icons.apps_rounded,
                  color: AppColors.primary,
                ),
              ),
            );
          }
          final category = categories[index];
          return _CategoryPill(
            label: category.title,
            icon: category.icon,
            onTap: onCategoryTap == null
                ? null
                : () => onCategoryTap!(category),
          );
        },
      ),
    );
  }
}

/// شريحة قسم واحدة — نفس مقاس ولغة شرائح دليل الأطباء.
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.icon,
    this.onTap,
    this.highlighted = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  /// «المزيد»: خلفية طميّ فاتحة تميّزها عن الأقسام.
  final bool highlighted;

  static const Color _chipBorder = Color(0xFFE7EEF0);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: highlighted ? AppColors.mintPill : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlighted ? Colors.transparent : _chipBorder,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: AppColors.primary),
            const SizedBox(width: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                height: 1,
                color: highlighted ? AppColors.primary : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
