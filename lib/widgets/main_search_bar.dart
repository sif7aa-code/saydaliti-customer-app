import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';

/// شريط البحث الرئيسي على واجهة الأدوية + زر «تصفية» اختياري.
///
/// ★ 2026-11-20 — صار بنفس مقاس دليل الأطباء: كبسولة ارتفاع ٤٠ ونصف قطر ١٤
///   بحدّ `#E3EFE5` وأيقونة بحث خضراء صغيرة، بدل الصندوق الكبير ذي الدائرة
///   الخضراء (٥٢ بكبسولة كاملة) الذي كان يجعل الصفحة تبدو مختلفة عنها.
class MainSearchBar extends StatelessWidget {
  const MainSearchBar({
    super.key,
    this.onSearchChanged,
    this.onFilterTap,
    this.onSubmitted,
    this.hintText,
  });

  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onFilterTap;

  /// يُستدعى عند الضغط على مفتاح البحث في لوحة المفاتيح.
  final ValueChanged<String>? onSubmitted;

  /// نص الإرشاد داخل الحقل.
  final String? hintText;

  static const Color _fieldBorder = Color(0xFFE3EFE5);

  @override
  Widget build(BuildContext context) {
    final field = Container(
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _fieldBorder),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Icon(Icons.search_rounded, color: AppColors.primary, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              textInputAction: TextInputAction.search,
              onChanged: onSearchChanged,
              onSubmitted: onSubmitted,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                hintText: hintText ?? 'ابحث عن دواء، منتج أو صيدلية...',
                hintStyle: GoogleFonts.cairo(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textHint,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );

    if (onFilterTap == null) return field;

    return Row(
      children: [
        Expanded(child: field),
        const SizedBox(width: 10),
        InkWell(
          onTap: onFilterTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.mintPill,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.tune_rounded,
                  color: AppColors.primary,
                  size: 16,
                ),
                const SizedBox(width: 5),
                Text(
                  'تصفية',
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
