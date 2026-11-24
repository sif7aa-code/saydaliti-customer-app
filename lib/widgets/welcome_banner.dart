import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import 'app_image.dart';

/// ★ ألوان بطاقة الترحيب في الشاشة الرئيسية فقط (مطابقة الصورة المرجعية):
///   أخضر داكن النصوص/الأيقونة فوق التدرّج الأخضر. خاصة بهذا الملف ولا
///   تُستخدم في أي شاشة أخرى، فلا تتأثر أي صفحة سواها.
const Color _navyText = AppColors.textPrimary;

/// ترحيب ثابت يظهر أعلى الشاشة الرئيسية لكل مندوب أو زبون.
///
/// `compact`: بطاقة ترحيب صغيرة مضغوطة في زاوية الرأس (الوضع الافتراضي
/// للشاشة الرئيسية). بدونه: البطاقة الكبيرة الملوّنة (شاشة المندوب).
class WelcomeBanner extends StatelessWidget {
  const WelcomeBanner({
    super.key,
    required this.name,
    required this.isDriver,
    this.compact = false,
    this.width,
    this.trailing,
    this.avatarUrl,
  });

  final String name;
  final bool isDriver;
  final bool compact;

  /// عرض البطاقة المضغوطة (يقارَب 55% من عرض الشاشة).
  final double? width;

  /// عنصر اختياري يُضمَّن آخر البطاقة المضغوطة (جرس التنبيهات).
  final Widget? trailing;

  /// صورة الحساب: تحلّ مكان أيقونة الشخص في البطاقة المضغوطة.
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final safeName = (name.trim().isEmpty) ? 'زائر' : name.trim();
    final title = isDriver
        ? 'أهلاً بك يا مندوب $safeName'
        : 'أهلاً بك يا $safeName';
    final subtitle = isDriver
        ? 'طلباتك بانتظارك — استقبل ووصّل ودقّق في الوقت الحقيقي.'
        : 'سعداء بعودتك';
    final icon = isDriver
        ? Icons.delivery_dining_rounded
        : Icons.local_pharmacy_rounded;

    if (compact) {
      return _compactCard(
        title: title,
        subtitle: subtitle,
        icon: icon,
        avatarUrl: avatarUrl,
      );
    }
    return _wideCard(title: title, subtitle: subtitle, icon: icon);
  }

  /// البطاقة المضغوطة (الشاشة الرئيسية فقط): تدرّج أخضر ساطع كما في
  /// الصورة المرجعية، نص أبيض محاذى لليمين، صورة المستخدم دائرة بيضاء
  /// بأيقونة خضراء داكنة، وجرس التنبيهات دائرة بيضاء على اليسار.
  ///
  /// ★ لا تُلمس البطاقة الكبيرة (`_wideCard`) الخاصة بشاشة المندوب.
  Widget _compactCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required String? avatarUrl,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = (width ?? constraints.maxWidth * 0.55)
            .clamp(0.0, constraints.maxWidth)
            .toDouble();
        return Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: w,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 16,
              ),
              decoration: BoxDecoration(
                // ★ المرجع (2026-10-26): تدرّج بطاقة الرأس أخضر مشرق
                //   `#3CC87F` أعلى اليمين ← أعمق `#087B5C` أسفل اليسار،
                //   وهو `AppColors.brandGradient` المقيس من الصورة نفسها.
                gradient: AppColors.brandGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: (avatarUrl == null || avatarUrl.isEmpty)
                          ? Icon(icon, color: _navyText, size: 24)
                          : AppImage(
                              avatarUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                icon,
                                color: _navyText,
                                size: 24,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            color: const Color(0xFFFFFFFF),
                            fontSize: 16.5,
                            height: 1.25,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 12,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // جرس التنبيهات صار داخل البطاقة نفسها.
                  if (trailing != null) ...[
                    const SizedBox(width: 10),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// البطاقة الكبيرة الملوّنة (شاشة المندوب).
  Widget _wideCard({
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: AppColors.buttonGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.20),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
