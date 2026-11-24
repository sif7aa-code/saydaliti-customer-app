import 'package:flutter/widgets.dart';

/// نسخة غير ويب (أندرويد/آيفون/سطح المكتب): لا بطاقة تثبيت.
///
/// التطبيق هنا مُنصَّب أصلاً من حزمة، فلا معنى لـ«أضف إلى الشاشة
/// الرئيسية». وجود هذا الملف يمنع استيراد `dart:js_interop` — وهو غير
/// متاح خارج المتصفح — فتفشل كل نسخ الهاتف عند البناء.
class InstallAppBanner extends StatelessWidget {
  const InstallAppBanner({super.key, this.padding = 12});

  final double padding;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
