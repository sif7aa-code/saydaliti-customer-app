import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';

/// شريحة قسم واحدة، كما تُستعمل داخل صفحة الصيدلية (للزبون) وفي شاشة
/// «منتجات الصيدلية» (للأدمن): الشكل واحد والفرق في اللون، فلا يظن الأدمن أن
/// الشريحة التي يراها غير التي يضغطها الزبون.
///
/// البطاقة تُعرَّف بلونها وحدّها وحدها — لا ظل ولا شريط خلفي.
class ShelfChip extends StatelessWidget {
  const ShelfChip({
    super.key,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  final String label;

  /// عدد المنتجات تحت هذا القسم؛ يُعرض دائماً حتى لا يكون الرقم تخميناً.
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = isSelected ? Colors.white : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: isSelected ? AppColors.primary : AppColors.surface,
        borderRadius: BorderRadius.circular(30),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: isSelected ? Colors.transparent : AppColors.divider,
                width: 1.2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  // اسم طويل («مشروبات ساخنة وباردة») لا يدفع الشرائح خارج
                  // الشاشة؛ الشريط أفقي فيمدها بالتمرير.
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.white.withValues(alpha: 0.22)
                        : AppColors.surfaceTint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    textDirection: TextDirection.ltr,
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: isSelected ? Colors.white : AppColors.primary,
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
}
