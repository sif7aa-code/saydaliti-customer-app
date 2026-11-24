import 'dart:io';

import 'package:flutter/foundation.dart';

/// طبقة حماية محلية — مساعدة فقط، وليست حاجزاً أمنياً.
///
/// الحاجز الحقيقي في الخادم: أي فحص على الجهاز قابل للتحايل بتعديل
/// الحزمة أو التشغيل على جهاز مُعدَّل. غرضه رفع كلفة الهجوم، ومنع
/// ظهور كلمة السر وكود التحقق في لقطات الشاشة وفي «مبدّل المهام».
class SecurityGuard {
  SecurityGuard._();

  /// يمنع لقطات الشاشة ويخفي محتوى الشاشة في قائمة المهام.
  ///
  /// بدونه، حقل كلمة السر أو كود التحقق يظهر مصغّراً في قائمة
  /// التطبيقات، أو في لقطة شاشة يشاركها المستخدم.
  /// التنفيذ فعلي في MainActivity عبر WindowManager.LayoutParams
  /// لأن_FLAG_SECURE وTASK_HIDDEN وظيفتان أصليتان بلا حزم.
  static void onWindowReady() {
    log('native protections installed');
  }

  /// المؤشرات الشائعة لجهاز مُعدَّل (su/root). القراءة فقط، بلا تنفيذ.
  static Future<bool> isCompromised() async {
    if (!Platform.isAndroid) return false;
    const suPaths = [
      '/system/bin/su',
      '/system/xbin/su',
      '/sbin/su',
      '/su/bin/su',
      '/system/app/Superuser.apk',
      '/data/local/xbin/su',
      '/data/local/bin/su',
      '/debug_ramdisk',
    ];
    for (final p in suPaths) {
      try {
        if (await File(p).exists()) return true;
      } catch (_) {}
    }
    return false;
  }

  /// تسجيل داخلي محجوب عن الإنتاج: logcat يقرأه أي تطبيق على
  /// الإصدارات القديمة، وطباعة التفاصيل تسرّب معلومات.
  static void log(String message) {
    if (kDebugMode) debugPrint('[security] $message');
  }
}