import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'device_sound.dart';
import 'notification_sound.dart';

/// إشعار نظام حقيقي (يظهر في شريط الإشعارات) بصوت كل نوع إشعار،
/// ويعمل خارج التطبيق (الخلفية/مقفل).
///
/// ★ أيقونة الشريط = شعار التطبيق (`ic_stat_notification`) بنسخة ظلّية
///   مبسّطة (إطار + صليب + دبّوس موقع + نبضة)، لأن أندرويد يرسمها
///   بيضاء على شفاف ويتجاهل الألوان. لا صورة داخل الإشعار نفسه؛
///   الشعار الكامل يبقى في بنر التطبيق الداخلي وفي قائمة الجرس.
///
/// كل نوع إشعار له قناة Android مستقلة لها نغمتها
/// (تُنشأ في `MainActivity.kt` → `NotifyChannels`)، لأن Android
/// لا يسمح بتغيير صوت القناة بعد إنشائها.
class SystemNotification {
  SystemNotification._();
  static final SystemNotification instance = SystemNotification._();

  /// معرّفات القنوات — مطابقة تماماً لـ NotifyChannels في MainActivity.kt
  /// وتلك التي يرسلها tools/push_worker.js.
  static const String chNewOrder = 'strasopa_v2_new_order';
  static const String chAccepted = 'strasopa_v2_accepted';
  static const String chDelivering = 'strasopa_v2_delivering';
  static const String chRejected = 'strasopa_v2_rejected';
    static const String chReplaced = 'strasopa_v2_replaced';
    static const String chPriceChanged = 'strasopa_v2_price_changed';
  static const String chDelivered = 'strasopa_v2_delivered';
  static const String chAlert = 'strasopa_v2_alert';

  /// أسماء القنوات كما تظهر في إعدادات النظام.
  static const Map<String, String> _channelNames = {
    chNewOrder: 'طلب جديد',
    chAccepted: 'قبول الطلب',
    chDelivering: 'جاري التوصيل',
    chRejected: 'رفض الطلب',
    chReplaced: 'استبدال منتج',
    chPriceChanged: 'تغيير سعر',
    chDelivered: 'توصيل الطلب',
    chAlert: 'تنبيه عام',
  };

  static const String _statusIcon = 'ic_stat_notification';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _granted = false;

  bool get ready => _ready;
  bool get granted => _granted;

  /// يُستدعى عند الضغط على إشعار عرضناه نحن (رسائل data-only التي يعرضها
  /// معالج الخلفية). الحمولة = `orderId|serial|kind`.
  void Function(String payload)? onLocalNotificationTap;

  /// حمولة الإشعار المحلي الذي فتح منه التطبيق عند الإقلاع (Cold Start).
  /// تُقرأ مرة واحدة ثم تُصفَّر حتى لا يفتح التطبيق الطلب مرتين.
  String? get localLaunchPayload => _localLaunchPayload;
  set localLaunchPayload(String? value) => _localLaunchPayload = value;
  String? _localLaunchPayload;

  /// تهيئة + طلب إذن الإشعارات (أندرويد 13+ / آيفون).
  Future<void> init() async {
    if (_ready) return;
    // نغمة المستخدم على هذا الهاتف (إن اختار واحدة) تُقرأ أولاً حتى
    // يُوجَّه أول إشعار إلى قناتها مباشرة.
    await DeviceSound.load();
    try {
      await _plugin.initialize(
        InitializationSettings(
          android: const AndroidInitializationSettings(_statusIcon),
          iOS: const DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        // ── الضغط على إشعار عرضناه نحن أثناء تشغيل التطبيق ──
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            onLocalNotificationTap?.call(payload);
          }
        },
      );

      // ── الإقلاع من إشعار محلي (التطبيق مقفل/مُقتل) ──
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        final payload = details?.notificationResponse?.payload;
        if (payload != null && payload.isNotEmpty) {
          _localLaunchPayload = payload;
        }
      }

      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        _granted = (await android.requestNotificationsPermission()) ?? false;
        // إنشاء القنوات أيضاً من Dart (احتياط لو فشلت Kotlin).
        for (final entry in _channelNames.entries) {
          await android.createNotificationChannel(
            AndroidNotificationChannel(
              entry.key,
              entry.value,
              description: 'صوت تنبيه: ${entry.value}',
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
              vibrationPattern: Int64List.fromList(const [0, 250, 150, 250]),
            ),
          );
        }
      }

      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        _granted =
            (await ios.requestPermissions(alert: true, badge: true, sound: true)) ??
                false;
      }

      _ready = true;
    } catch (e) {
      _ready = false;
      if (kDebugMode) print('SystemNotification init failed: $e');
    }
  }

  /// قناة Android المناسبة لنوع الإشعار.
  ///
  /// ★ نغمة اختيار المستخدم (من أصوات هاتفه) تتقدّم على قناة الحدث:
  ///   كل الإشعارات تُعرض على قناته المخصّصة، فلا يرنّ صوت التطبيق
  ///   القديم مع الجديد.
  static String channelFor(String? soundOrType) {
    final custom = DeviceSound.channelId;
    if (custom != null && custom.isNotEmpty) return custom;
    switch (NotificationSound.resolve(soundOrType)) {
      case NotifySound.newOrder:
        return chNewOrder;
      case NotifySound.accepted:
        return chAccepted;
      case NotifySound.delivering:
        return chDelivering;
      case NotifySound.rejected:
        return chRejected;
      case NotifySound.replaced:
        return chReplaced;
      // ★ تغيير السعر قناة مستقلة: لها نغمة وصوت نطق خاصّان،
      //   وخلطها مع الاستبدال يجعل المستخدم لا يميّز الثنائين.
      case NotifySound.priceChanged:
        return chPriceChanged;
      case NotifySound.delivered:
        return chDelivered;
      case NotifySound.alert:
        return chAlert;
    }
  }

  /// اسم القناة كما يظهر في إعدادات النظام.
  static String channelName(String id) {
    final custom = DeviceSound.channelId;
    if (custom != null && custom.isNotEmpty && id == custom) {
      return DeviceSound.label;
    }
    return _channelNames[id] ?? 'تنبيه عام';
  }

  /// يعرض إشعار النظام بالنص فقط — بلا أي صورة.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? soundOrType,
  }) async {
    if (!_ready) await init();
    if (!_ready || !_granted) return;
    final channel = channelFor(soundOrType);
    final channelLabel = channelName(channel);
    try {
      final details = AndroidNotificationDetails(
        channel,
        channelLabel,
        channelDescription: 'صوت تنبيه: $channelLabel',
        importance: Importance.high,
        priority: Priority.high,
        // الصوت يأتي من القناة نفسها (لها نغمة خاصة بكل حدث).
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(const [0, 250, 150, 250]),
        ticker: body,
        autoCancel: true,
      );
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: details,
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: true,
          ),
        ),
        payload: body,
      );
    } catch (e) {
      if (kDebugMode) print('SystemNotification show failed: $e');
    }
  }

  /// معرّف رقمي ثابت لكل صف إشعار (حتى لا يتكرر رقم الإشعار).
  static int notificationId(String rawId) => rawId.hashCode & 0x3fffffff;

  /// ★ رقم الطلب في العنوان إن لم يكن ظاهراً في النص.
  ///
  /// العنوان هو أول ما يُقرأ في شريط الإشعارات خارج التطبيق، وهو
  /// أول سطر يُقصّ حين يطول النص ⇒ وضع الرقم فيه يضمن أن يقرأ
  /// المندوب رقم الطلب دائماً. وإن كان `body` يحويه أصلاً لا نكرّره.
  static String withSerialTag(
    String title, {
    String? serial,
    String? body,
  }) {
    final s = (serial ?? '').trim();
    if (s.isEmpty || s == 'null') return title;
    final tag = s.startsWith('#') ? s : '#$s';
    if (title.contains(tag)) return title;
    if ((body ?? '').contains(tag)) return title;
    return '$title  $tag';
  }
}
