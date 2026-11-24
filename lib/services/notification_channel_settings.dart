/// نغمة الإشعار التي اختارها المستخدم في **إعدادات الهاتف**.
///
/// ★ لماذا نقرأها من النظام بدل أن نختارها نحن؟
///   على أندرويد، صوت قناة الإشعار لا يمكن للتطبيق تغييره بعد
///   إنشاء القناة — الإعداد يثبّته المستخدم من إعدادات النظام.
///   لذلك: نقرأ ما اختاره فعلاً، ونحفظه محلياً، ونعرضه له، ونفتح
///   له صفحة الإعدادات مباشرة لتغييره.
///
/// هذا يحترم اختيار المستخدم بدل فرض نغمة من عندنا.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_sound.dart';

const MethodChannel _ch = MethodChannel('strasopa/notification_channels');

class NotificationChannelSettings {
  NotificationChannelSettings._();
  static final NotificationChannelSettings instance =
      NotificationChannelSettings._();

  /// معرّفات القنوات (مطابقة لـ NotifyChannels في MainActivity.kt).
  static const String newOrder = 'strasopa_v2_new_order';
  static const String accepted = 'strasopa_v2_accepted';
  static const String delivering = 'strasopa_v2_delivering';
  static const String rejected = 'strasopa_v2_rejected';
  static const String replaced = 'strasopa_v2_replaced';
  static const String delivered = 'strasopa_v2_delivered';
  static const String alert = 'strasopa_v2_alert';

  static const String _prefsKey = 'notify_channel_sounds_v1';

  /// آخر قراءة من النظام (قد تكون فارغة قبل أول قراءة).
  static Map<String, String?> _cache = {};

  /// هل نختار نغمة افتراضية واحدة لكل الإشعارات أم نتبع إعدادات الهاتف؟
  ///
  /// `true` (الافتراضي) ⇒ نتبع ما اختاره المستخدم في إعدادات الهاتف.
  /// `false` ⇒ نتجاهل إعداداته ونستخدم أصوات التطبيق (سلوك قديم).
  bool _followSystem = true;
  bool get followSystem => _followSystem;

  Map<String, String?> get sounds => Map.unmodifiable(_cache);

  /// تهيئة: تحميل الاختيار المحفوظ ثم قراءة ما ضبطه المستخدم الآن.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _followSystem = prefs.getBool('notify_follow_system_sound_v1') ?? true;
    } catch (_) {}
    await refresh();
  }

  /// يقرأ نغمات القنوات من النظام ويحفظها (حتى لو لم يغيّر شيئاً).
  Future<void> refresh() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final raw = await _ch.invokeMapMethod<String, String?>('channelSounds');
      if (raw == null) return;
      _cache = raw;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        raw.entries.map((e) => '${e.key}=${e.value ?? ''}').toList(),
      );
    } catch (e) {
      // غير متاح (iOS/ويب) ⇒ نُبقي ما لدينا.
      debugPrint('channel sounds: $e');
    }
  }

  /// تفعيل/تعطيل اتباع إعدادات الهاتف (مع حفظ الاختيار).
  Future<void> setFollowSystem(bool v) async {
    _followSystem = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notify_follow_system_sound_v1', v);
    } catch (_) {}
  }

  /// نغمة القناة كما اختارها المستخدم، بصيغة نصية للعرض.
  ///
  /// `null`/فارغة ⇒ نغمة النظام الافتراضية.
  String displayName(String channelId) {
    final v = _cache[channelId];
    if (v == null || v.isEmpty || v == 'null') return 'نغمة النظام';
    // content://media/internal/audio/media/<id> ⇒ آخر جزء هو المعرّف.
    final id = v.split('/').last;
    if (id == 'default_notification_uri') return 'نغمة النظام';
    return 'نغمة مخصّصة (#$id)';
  }

  /// هل اختار المستخدم نغمة مختلفة عمّا يفترضه التطبيق؟
  bool isCustomised(String channelId) {
    final v = _cache[channelId];
    return v != null && v.isNotEmpty && v != 'null' &&
        !v.endsWith('default_notification_uri');
  }

  /// القناة التي تخصّ هذا النوع من الإشعارات.
  static String channelIdFor(NotifySound s) => switch (s) {
        NotifySound.newOrder => newOrder,
        NotifySound.accepted => accepted,
        NotifySound.delivering => delivering,
        // ★ تغيير السعر على قناة الرفض: كل تنبيه يخصّ الطلب
        //   وتغييره/استبداله، فقناة واحدة تكفي ولا تتضخّم الإعدادات.
        NotifySound.rejected ||
        NotifySound.replaced ||
        NotifySound.priceChanged =>
          rejected,
        NotifySound.delivered => delivered,
        NotifySound.alert => alert,
      };

  /// يفتح إشعارات التطبيق في إعدادات الهاتف.
  Future<void> openAppSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod<bool>('openAppNotificationSettings');
    } catch (e) {
      debugPrint('open app notif settings: $e');
    }
  }

  /// يفتح إعدادات قناة بعينها (يختار فيها المستخدم النغمة).
  Future<void> openChannelSettings(String channelId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod<bool>('openChannelSettings',
          {'channelId': channelId});
    } catch (e) {
      debugPrint('open channel settings: $e');
    }
  }

  /// يعيد القراءة بعد عودة المستخدم من الإعدادات (لمعرفة اختياره الجديد).
  Future<void> reloadAfterSettings() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await refresh();
  }
}
