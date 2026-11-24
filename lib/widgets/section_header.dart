import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';

/// رأس قسم موحد (أيقونة + عنوان + زر اختياري "عرض الكل").
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.icon, this.onViewAll});

  final String title;
  final IconData? icon;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          // ★ المرجع: مربّع أخضر 40×40 بنصف قطر 12 وأيقونة بيضاء.
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: AppColors.buttonGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 21),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            title,
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (onViewAll != null)
          GestureDetector(
            onTap: onViewAll,
            behavior: HitTestBehavior.opaque,
            child: Container(
              // ★ المرجع: كبسولة «عرض الكل» فاتحة `#E1F6ED` بنصّ داكن
              //   وسهم صغير، بلا حشو أخضر ولا لون مميّز.
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'عرض الكل',
                    style: GoogleFonts.cairo(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: AppColors.textPrimary,
                    size: 12,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}