import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme/app_colors.dart';

/// سياسة الخصوصية الخاصة بالتطبيق.
///
/// Google تطلب أمرين معاً: رابط السياسة في حقول Play Console، **ورابط أو نص
/// السياسة داخل التطبيق نفسه**. هذا الملف يوفّر الثاني: نص مختصر يُعرض داخل
/// التطبيق مع زر يفتح الصفحة الكاملة على الويب.
class PrivacyPolicy {
  PrivacyPolicy._();

  /// الصفحة الكاملة (موقع رسمي عام، بلا تسجيل دخول، لكل العالم).
  static const String fullUrl = 'https://saydaliti-privacy.netlify.app/';

  /// صفحة «عن التطبيق».
  static const String aboutUrl =
      'https://saydaliti-privacy.netlify.app/#about';

  /// بريد التواصل المذكور في السياسة.
  static const String contactEmail = 'mnstalshtrt@gmail.com';

  static const List<String> summaryPoints = <String>[
    'ندخل رقم هاتفك وكلمة المرور لإنشاء حسابك وتسجيل الدخول، والاسم الذي تكتبه لإتمام الحجز أو الطلب.',
    'نحفظ حجوزاتك وطلباتك وعنوان التسليم الذي تحدده بنفسك، ورسائلك مع العيادة لا يراها إلا طرفا المحادثة.',
    'الصور تُختار بأداة اختيار الصور في نظام أندرويد، فلا يطّلع التطبيق على بقية صور جهازك.',
    'تُشارك بيانات الطلب مع الصيدلية التي تطلب منها ومع المندوب المسؤول عن توصيل طلبك، ولا تُباع لأي جهة.',
  ];

  /// يفتح صفحة السياسة الكاملة في متصفح الجهاز. يرجع false إن تعذّر الفتح.
  static Future<bool> openFullPage() async {
    try {
      return await launchUrl(
        Uri.parse(fullUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  /// يفتح صفحة «عن التطبيق».
  static Future<bool> openAboutPage() async {
    try {
      return await launchUrl(
        Uri.parse(aboutUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  /// نص مختصر عن الخصوصية داخل التطبيق + رابط الصفحة الكاملة.
  static Future<void> showInApp(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.privacy_tip_outlined,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'سياسة الخصوصية',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'لمحة سريعة عن البيانات التي نتعامل معها داخل التطبيق:',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: summaryPoints
                          .map(
                            (String point) => Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    margin: const EdgeInsets.only(
                                      top: 7,
                                      left: 6,
                                      right: 10,
                                    ),
                                    decoration: const BoxDecoration(
                                      color: AppColors.primary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      point,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 13.5,
                                        height: 1.6,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => openFullPage(),
                    child: const Text(
                      'قراءة سياسة الخصوصية الكاملة',
                      style: TextStyle(fontSize: 14.5),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => openAboutPage(),
                  child: const Text(
                    'تعرّف على تطبيق اطباء ذي قار',
                    style: TextStyle(fontSize: 13.5),
                  ),
                ),
                const SizedBox(height: 2),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// سطر صغير يُوضع أسفل شاشات الدخول: «سياسة الخصوصية · عن التطبيق».
class PrivacyPolicyLinksRow extends StatelessWidget {
  const PrivacyPolicyLinksRow({super.key, this.leading, this.onDark = false});

  final String? leading;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final Color labelColor = onDark ? Colors.white : AppColors.primary;
    final Color mutedColor = onDark
        ? Colors.white.withValues(alpha: 0.75)
        : AppColors.textHint;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (leading != null)
          Text(leading!, style: TextStyle(fontSize: 12, color: mutedColor)),
        TextButton(
          onPressed: () => PrivacyPolicy.showInApp(context),
          style: TextButton.styleFrom(
            foregroundColor: labelColor,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('سياسة الخصوصية', style: TextStyle(fontSize: 12)),
        ),
        Text('·', style: TextStyle(fontSize: 12, color: mutedColor)),
        TextButton(
          onPressed: () => PrivacyPolicy.openAboutPage(),
          style: TextButton.styleFrom(
            foregroundColor: labelColor,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('عن التطبيق', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}
