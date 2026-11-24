import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../models/doctor_profile.dart';
import 'app_image.dart';

/// صورة الطبيب: الملف المحلي أولاً، ثم رابط القاعدة، ثم وجه البانر
/// للصفّ البطل، وإلا أيقونة الخدمة. مشتركة بين الدليل وتبويب المفضلة.
Widget doctorAvatarImage(DoctorProfile doctor, double w, double h) {
  final local = doctor.localAsset;
  if (local != null && local.isNotEmpty) {
    return Image.asset(
      local,
      width: w,
      height: h,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
  }
  final url = doctor.imageUrl;
  if (url == null) {
    // صفّ البانر في القاعدة قد يصل بلا صورة (كان البانر هو صورتها) —
    // نعرض وجهها المقصوص من البانر بدل الأيقونة العامة.
    if (doctor.isHero) {
      return Image.asset(
        'assets/images/doctors/doc_hero.jpg',
        width: w,
        height: h,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      );
    }
    return Container(
      width: w,
      height: h,
      color: AppColors.primaryLight,
      child: Icon(
        Icons.medical_services_outlined,
        color: AppColors.primary,
        size: w * 0.45,
      ),
    );
  }
  return AppImage(
    url,
    width: w,
    height: h,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => Container(
      width: w,
      height: h,
      color: AppColors.primaryLight,
      child: Icon(
        Icons.medical_services_outlined,
        color: AppColors.primary,
        size: w * 0.45,
      ),
    ),
  );
}

/// بطاقة القائمة: سطح أبيض بحدّ رقيق وظل هادئ، الصورة يميناً بحلقة خضراء،
/// والاسم بخط عريض بارز سطرين عند الحاجة، ثم التخصص ثم شريحة المنطقة —
/// والقلب في زر دائري مستقل. تُستخدم في الدليل وفي تبويب المفضلة معاً.
class DoctorListCard extends StatelessWidget {
  const DoctorListCard({
    super.key,
    required this.doctor,
    required this.isFav,
    required this.onFav,
    required this.onTap,
  });

  final DoctorProfile doctor;
  final bool isFav;
  final VoidCallback onFav;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: Colors.white,
            border: Border.all(color: const Color(0xFFEFF3F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.045),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                padding: const EdgeInsets.all(2.2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.30),
                      AppColors.primary.withValues(alpha: 0.06),
                    ],
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: ClipOval(child: doctorAvatarImage(doctor, 56, 56)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            doctor.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 15,
                              height: 1.22,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        if (doctor.verified) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified_rounded,
                            size: 16,
                            color: AppColors.info,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      doctor.specialtyLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (doctor.area.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.location_on_rounded,
                              size: 13,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                doctor.area,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.cairo(
                                  fontSize: 10.5,
                                  height: 1.25,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primary,
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
              const SizedBox(width: 8),
              InkWell(
                onTap: onFav,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF7F9F8),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isFav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: isFav ? AppColors.favorite : const Color(0xFFB0BAC4),
                    size: 21,
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
