import 'package:flutter/material.dart';

import '../widgets/emerald_banner_background.dart';

/// عنصر يُعرض ضمن البانر الإعلاني المتحرك (Slider).
class BannerItem {
  const BannerItem({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.palette,
    required this.icon,
    this.imageUrl,
    this.speedSeconds = 4,
    this.shopId,
    this.targetUrl,
  });

  final String title;
  final String subtitle;
  final String badge;

  /// لوحة ألوان الخلفية: تُولَّد من لون البانر الأساسي في قاعدة البيانات،
  /// فيختلف لون كل بانر مع بقاء نفس البنية البصرية الفاخرة.
  final EmeraldBannerPalette palette;
  final IconData icon;
  final String? imageUrl;

  /// زمن التقليب بالثواني — يتحكم فيه الأدمن عند إضافة البانر.
  final int speedSeconds;

  /// صيدلية مرتبط بالبانر ليُفتح عند الضغط عليه (اختياري).
  ///
  /// ★ يشمل محلات «كوزمتك» أيضاً: كلاهما حساب صيدلية في `shops`،
  ///   والفرق بينهما قسم المحل فقط.
  final String? shopId;

  /// رابط خارجي يُفتح عند الضغط على البانر (اختياري).
  ///
  /// ★ إذا بدأ بـ`doctor:` فبقيّته معرّف طبيب — وجهة داخل التطبيق،
  ///   وليست رابطاً خارجياً (لا حاجة لعمود جديد في جدول البانرات).
  final String? targetUrl;

  /// معرّف الطبيب إذا كانت وجهة البانر حساب طبيب، وإلا null.
  String? get doctorId {
    final t = targetUrl?.trim() ?? '';
    const prefix = 'doctor:';
    if (!t.startsWith(prefix)) return null;
    final id = t.substring(prefix.length).trim();
    return id.isEmpty ? null : id;
  }
}
