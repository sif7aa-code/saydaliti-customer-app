/// نغمة الإشعارات التي يختارها المستخدم من **أصوات هاتفه**.
///
/// ★ تُحفظ على الجهاز فقط (SharedPreferences): لو بدّل الحساب أو
///   سجّل الخروج تبقى نغمته، ولو فتح من هاتف آخر تبقى نغمة كل هاتف
///   كما هي. الصوت لا يغادر الهاتف؛ يُبلَّغ سيرفر الإشعارات بمعرّف
///   القناة وحده (من `PushService.syncSoundChannel`) مرة عند التغيير،
///   لأن إشعار التطبيق المغلق يرسمه أندرويد ويقرأ صوت قناته من رسالة
///   السيرفر.
/// ★ التطبيق ينشئ على الهاتف قناة إشعار جديدة بصوت الاختيار ويحذف
///   قناة الاختيار السابق ⇒ لا يرنّ القديم مع الجديد. المعرّف يُحفظ
///   هنا من الخادم الأصلي (`NotificationSounds.apply`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _ch = MethodChannel('strasopa/notification_channels');

/// المفتاح الذي يُحفظ به الاختيار (نفس الاسم على الجانب الأصلي).
class DeviceSound {
  DeviceSound._();

  static const String silentUri = 'silent';
  static const String defaultLabel = 'نغمة الإشعارات';

  static String? _uri;
  static String? _title;
  static String? _channelId;

  /// نغمة الاختيار (null ⇒ نغمة التطبيق الافتراضية).
  static String? get selectedUri => _uri;
  static String? get selectedTitle => _title;

  /// قناة الاختيار — الكل يعرض إشعاراته عليها إن وُجدت.
  static String? get channelId => _channelId;

  static String get label {
    final t = (_title ?? '').trim();
    return t.isEmpty ? defaultLabel : t;
  }

  static bool get hasCustom => _channelId != null && _channelId!.isNotEmpty;

  static bool get isSilent => _uri == silentUri;

  /// تحميل الاختيار المحفوظ (يُستدعى مبكراً وعند الإقلاع).
  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _uri = _clean(p.getString('custom_sound_uri'));
      _title = _clean(p.getString('custom_sound_title'));
      _channelId = _clean(p.getString('custom_channel_id'));
    } catch (_) {}
  }

  static String? _clean(String? v) {
    final s = (v ?? '').trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  /// قائمة أصوات الإشعارات في الهاتف (Android فقط).
  static Future<List<Map<String, String>>> list() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    try {
      final raw = await _ch.invokeListMethod<dynamic>('listSounds');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => {
                'title': (m['title'] ?? '').toString(),
                'uri': (m['uri'] ?? '').toString(),
              })
          .where((m) => m['uri']!.isNotEmpty)
          .toList(growable: false);
    } catch (e) {
      debugPrint('device sounds list: $e');
      return const [];
    }
  }

  /// يعاين نغمة مختارة (يتوقف وحده بعد ثوانٍ).
  static Future<void> preview(String uri) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod<bool>('previewSound', {'uri': uri});
    } catch (e) {
      debugPrint('device sound preview: $e');
    }
  }

  static Future<void> stopPreview() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod<bool>('stopSoundPreview');
    } catch (_) {}
  }

  /// يحفظ اختيار المستخدم ويُنشئ قناته على الهاتف.
  /// يعيد true إن نجح التطبيق فعلاً.
  static Future<bool> apply(String uri, String title) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      await _ch.invokeMethod<bool>('stopSoundPreview');
      final id = await _ch.invokeMethod<String>(
        'setCustomSound',
        {'uri': uri, 'title': title},
      );
      if (id == null || id.isEmpty) return false;
      _uri = uri;
      _title = title;
      _channelId = id;
      final p = await SharedPreferences.getInstance();
      await p.setString('custom_sound_uri', uri);
      await p.setString('custom_sound_title', title);
      await p.setString('custom_channel_id', id);
      return true;
    } catch (e) {
      debugPrint('device sound apply: $e');
      return false;
    }
  }

  /// إرجاع نغمة التطبيق الافتراضية (حذف القناة المخصّصة).
  static Future<void> reset() async {
    _uri = null;
    _title = null;
    _channelId = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('custom_sound_uri');
      await p.remove('custom_sound_title');
      await p.remove('custom_channel_id');
    } catch (_) {}
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod<bool>('stopSoundPreview');
      await _ch.invokeMethod<bool>('clearCustomSound');
    } catch (e) {
      debugPrint('device sound reset: $e');
    }
  }
}
