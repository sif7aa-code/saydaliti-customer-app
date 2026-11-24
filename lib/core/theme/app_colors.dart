import 'package:flutter/material.dart';

/// ألوان التطبيق الموحدة — هوية **أخضر (#008000)** لتطبيق صيدليتي
/// (2026-11-19، طلب الأدمن: اللون الأخضر المعتمد **#008000 بالضبط**
/// في جميع الصفحات، بعد تبديل السماوي/التركوازي كلياً).
///
/// أسماء الثوابت **لم تتغيّر** كما هي، فكل شاشات التطبيق وكل الأدوار
/// (زبون، مندوب، صاحب صيدلية، أدمن) تسحب ألوانها من هنا وتتبدّل معها دفعة
/// واحدة بلا تعديل أي شاشة.
abstract final class AppColors {
  // الأخضر الأساسي (مسطّح على الأزرار — بلا تدرّج)
  static const Color primary = Color(0xFF008000);
  static const Color primaryDark = Color(0xFF006B00);
  static const Color primaryDeep = Color(0xFF004D00);
  static const Color primaryLight = Color(0xFFE0F0E0);

  // الأخضر الموحّد لواجهة الدليل: رأس الصفحة والبطاقات المميّزة
  static const Color brandDark = Color(0xFF006B00);
  static const Color brand = Color(0xFF008000);
  static const Color brandLight = Color(0xFF2E9E2E);

  /// تدرّج بطاقة الرأس: أخضر مشرق أعلى اليمين → أخضر أعمق أسفل اليسار.
  static const LinearGradient brandGradient = LinearGradient(
    colors: [brandLight, Color(0xFF009B00), primaryDeep],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    stops: [0.0, 0.5, 1.0],
  );

  // تدرّج مائل لبطاقة القسم المميّز بنفس الأخضر
  static const LinearGradient brandCardGradient = LinearGradient(
    colors: [brandLight, brandDark],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // اللمسة المميّزة: أخضر فاتح ساطع يُقرأ فوق الداكن ويعمل على الأبيض
  static const Color accent = Color(0xFF269B26);
  static const Color accentDeep = Color(0xFF006B00);
  static const Color accentLight = Color(0xFFE6F5E6);

  // الخلفية والسطوح: صفحة فاتحة مائلة للأخضر + بطاقات بيضاء نقية
  static const Color background = Color(0xFFF4FAF4);
  static const Color surface = Color(0xFFFEFEFE);
  static const Color surfaceTint = Color(0xFFE6F5E6);

  // ★ إطار الصفحة العائم (المرجع 2026-11-19): أخضر متدرّج خلف الورقة
  //   البيضاء وشريط التنقل، وحبوة التنبيه النشط الخضراء الفاتحة.
  static const LinearGradient shellBackdrop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0B8A22), Color(0xFF007E18), Color(0xFF025A1D)],
  );
  static const Color mintPill = Color(0xFFD8F8E1);
  static const Color navPill = Color(0xFFC6FCDA);

  // خلفية منطقة الصور وحدودها في كل الأماكن
  // ★ مربّعات الصور **بيضاء نقية** (قاعدة ثابتة): صفحة المنتج، السلة،
  //   تتبّع الطلب، شاشة المندوب، ودوائر الصيدليات.
  static const Color imageBackground = Color(0xFFFFFFFF);
  static const Color imageBorder = Color(0xFFD7ECD7);

  // النصوص: أخضر داكن للعناوين ورمادي ماخض للتفاصيل
  static const Color textPrimary = Color(0xFF123211);
  static const Color textSecondary = Color(0xFF5A6F58);
  static const Color textHint = Color(0xFF95A693);

  // الحالات: الحدود محايدة؛ الأحمر والأصفر بقيا ألوان حالة لا هوية
  static const Color divider = Color(0xFFD7ECD7);
  static const Color warning = Color(0xFFF6BA40);
  static const Color danger = Color(0xFFFA4663);
  static const Color dangerLight = Color(0xFFFDE3E8);
  // ★ قلب «المفضلة» أحمر صريح (طلب 2026-11-20) — يُعرف بالمفضلة لا
  //   بالتحذير؛ danger بقي لأخطاء النماذج وحدها.
  static const Color favorite = Color(0xFFE53935);
  static const Color success = Color(0xFF008000);
  static const Color successLight = Color(0xFFE0F0E0);
  static const Color info = Color(0xFF1A76F3);
  static const Color iconContainer = Color(0xFFE0F0E0);

  // تدرج الأزرار الرئيسي — **مسطّح** على أخضر واحد (الاسم بقي
  // `buttonGradient` حتى لا تُلْمَس مواضع استعماله كلها).
  static const LinearGradient buttonGradient = LinearGradient(
    colors: [primary, primary],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  // تدرّج البطاقات الداكنة (بطاقة الرصيد، بطاقة هوية الصيدلية)
  static const LinearGradient navyCardGradient = LinearGradient(
    colors: [primaryDeep, primary, brandLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // تدرجات البانر الإعلاني — درجات الأخضر نفسها:
  //  1) الأخضر الساطع (بطاقة «اطلب أدويتك المفضلة»)
  //  2) الأخضر العميق (أسفل بطاقة الرأس)
  //  3) أخضر متوسط ← أخضر عميق (بانر التوصيل السريع)
  static const LinearGradient bannerGradient1 = LinearGradient(
    colors: [Color(0xFF008000), Color(0xFF2E9E2E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient bannerGradient2 = LinearGradient(
    colors: [Color(0xFF004D00), Color(0xFF008000)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient bannerGradient3 = LinearGradient(
    colors: [Color(0xFF007300), Color(0xFF004D00)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
