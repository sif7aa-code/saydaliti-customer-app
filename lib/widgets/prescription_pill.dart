import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';

/// كبسولة «يتطلب وصفة» فوق صورة الدواء.
///
/// تُعلن الشرط على البطاقة قبل فتح المنتج؛ فالتفاصيل تشرحه، والسلة
/// ترفض إتمام الطلب بلا صورة وصفة.
class PrescriptionPill extends StatelessWidget {
  const PrescriptionPill({super.key, this.fontSize = 10});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.warning,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.medical_information_rounded,
            color: AppColors.textPrimary,
            size: fontSize + 2,
          ),
          const SizedBox(width: 3),
          Text(
            'يتطلب وصفة',
            style: GoogleFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: fontSize,
              height: 1.1,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
