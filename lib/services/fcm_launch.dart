// =====================================================================
//  جسر Kotlin ⇄ Dart لبيانات الإقلاع من إشعار (Killed State)
// =====================================================================
//
//  Android يلتقط extras الإشعار في MainActivity / FcmMessagingService
//  ويخزّنها في `FcmLaunchStore`. هذا الجلب يقرأها مرة واحدة بعد إقلاع
//  محرك Flutter، فيكمل المسار مع `getInitialMessage` (وكلاهما معاً يغطّي
//  الحالتين: رسالة وصلت والنواة ميتة، أو رسالة موجودة في intent).
//
//  القراءة تتم مرة واحدة فقط (consume) فلا يُفتح الطلب مرتين.
// =====================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// قناة الاتصال مع الكود الأصلي.
class FcmLaunch {
  FcmLaunch._();
  static final FcmLaunch instance = FcmLaunch._();

  static const MethodChannel _channel = MethodChannel('strasopa/fcm_launch');

  bool _read = false;

  /// يقرأ حمولة الإشعار المحفوظة أصلاً على Android (إن وُجدت).
  Future<Map<String, String>?> consume() async {
    if (_read) return null;
    _read = true;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'consumeLaunchPayload',
      );
      if (raw == null || raw.isEmpty) return null;
      return raw.map((k, v) => MapEntry('$k', '$v'));
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) print('FcmLaunch consume failed: $e');
      return null;
    }
  }
}
