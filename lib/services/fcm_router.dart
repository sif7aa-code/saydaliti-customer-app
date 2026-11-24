// =====================================================================
//  توجيه الإشعارات عند الضغط عليها — بما فيها بدء التشغيل من إشعار
//  (Terminated / Killed State) عبر getInitialMessage
// =====================================================================
//
//  المشكلة المعتادة:
//  عند killed النظام ثم ضغط المستخدم على الإشعار، يُنشأ intent جديد
//  ويُستدعى `getInitialMessage` **قبل** أن يكون التطبيق جاهزاً
//  (قبل تسجيل الدخول وقبل جاهزية الـ navigator). لو حاولنا التنقّل
//  فوراً فلن يجد الـ navigator ⇒ تضيع النقرة.
//
//  الحل هنا:
//  1) نحفظ حمولة الإشعار في الذاكرة وفي SharedPreferences (فتنجو من
//     إقلاع العملية).
//  2) ننتظر جاهزية التطبيق (تسجيل دخول + navigator) ونستنزف الطلب
//     مرة واحدة فقط.
// =====================================================================

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart' show appNavigatorKey;
import '../screens/order_tracking_screen.dart';
import '../screens/secretary_appointments_screen.dart';
import 'auth_service.dart';
import 'fcm_launch.dart';
import 'system_notification.dart';

/// حمولة إشعار معلّقة حتى يجهز التطبيق.
class FcmPendingTap {
  const FcmPendingTap({
    required this.title,
    required this.body,
    required this.orderId,
    required this.serial,
    required this.kind,
    required this.link,
  });

  final String title;
  final String body;
  final String orderId;
  final String serial;
  final String kind;
  final String link;

  static const String _kStored = 'fcm_pending_tap_v1';

  Map<String, String> toMap() => {
        'title': title,
        'body': body,
        'orderId': orderId,
        'serial': serial,
        'kind': kind,
        'link': link,
      };

  static FcmPendingTap? fromMap(Map<String, String>? m) {
    if (m == null) return null;
    final orderId = (m['orderId'] ?? '').trim();
    final link = (m['link'] ?? '').trim();
    final title = (m['title'] ?? '').trim();
    if (orderId.isEmpty && link.isEmpty && title.isEmpty) return null;
    return FcmPendingTap(
      title: title,
      body: m['body'] ?? '',
      orderId: orderId,
      serial: m['serial'] ?? '',
      kind: m['kind'] ?? '',
      link: link,
    );
  }

  /// قراءة من التخزين المحلي (تنجو من إقلاع العملية).
  static Future<FcmPendingTap?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStored);
      if (raw == null || raw.isEmpty) return null;
      final map = <String, String>{};
      for (final part in raw.split('&')) {
        if (part.isEmpty) continue;
        final i = part.indexOf('=');
        if (i <= 0) continue;
        map[Uri.decodeComponent(part.substring(0, i))] =
            Uri.decodeComponent(part.substring(i + 1));
      }
      return fromMap(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kStored,
        toMap().entries
            .map((e) =>
                '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
            .join('&'),
      );
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kStored);
    } catch (_) {}
  }
}

/// يدير الطلبات المعلّقة ويفتح الشاشة الصحيحة عند الجاهزية.
class FcmRouter with WidgetsBindingObserver {
  FcmRouter._();
  static final FcmRouter instance = FcmRouter._();

  bool _started = false;
  bool _draining = false;
  bool _nativeChecked = false;
  bool _localTapsAttached = false;

  /// يبدأ مراقبة الجاهزية (يُستدعى من main بعد ensureInitialized).
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_drainLoop());
  }

  /// يُستدعى من main **بعد** `runApp` (أي بعد تسجيل MethodChannel على
  /// جانب Android). نستطيع عندها قراءة ما التقطه Android من نية الإقلاع.
  ///
  /// لماذا التأجيل؟ لو استدعيناها قبل `runApp` لَما وُجد مُستقبِل
  /// على الجانب الأصلي بعد ⇒ `MissingPluginException` وضاعت الحمولة.
  void ingestNativeWhenReady() {
    if (_nativeChecked) return;
    _nativeChecked = true;
    _attachLocalNotificationTaps();
    unawaited(ingestNativeLaunchPayload());
  }

  /// يربط الضغط على الإشعارات التي نعرضها نحن (رسائل data-only التي
  /// يعرضها معالج الخلفية)، وكذلك الإقلاع من إشعار محلي.
  void _attachLocalNotificationTaps() {
    if (_localTapsAttached) return;
    _localTapsAttached = true;
    SystemNotification.instance.onLocalNotificationTap = (payload) {
      unawaited(_onLocalTapPayload(payload));
    };
    // إقلاع كامل من إشعار محلي (didNotificationLaunchApp).
    final initial = SystemNotification.instance.localLaunchPayload;
    if (initial != null && initial.isNotEmpty) {
      SystemNotification.instance.localLaunchPayload = null;
      unawaited(_onLocalTapPayload(initial));
    }
  }

  Future<void> _onLocalTapPayload(String payload) async {
    final parts = payload.split('|');
    final orderId = parts.isNotEmpty ? parts[0].trim() : '';
    final serial = parts.length > 1 ? parts[1].trim() : '';
    final kind = parts.length > 2 ? parts[2].trim() : '';
    if (orderId.isEmpty && kind.isEmpty) return;
    await FcmPendingTap(
      title: '',
      body: '',
      orderId: orderId,
      serial: serial,
      kind: kind,
      link: '',
    ).persist();
    unawaited(_drainLoop());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_drainLoop());
  }

  /// تُستدعى عند كل نقرة إشعار (من `onMessageOpenedApp` أو
  /// `getInitialMessage`) — تحفظ الطلب ثم تحاول تنفيذه فوراً.
  Future<void> onNotificationTapped(RemoteMessage message) async {
    final data = message.data;
    final title =
        (message.notification?.title ?? data['title'] ?? '').toString().trim();
    final body =
        (message.notification?.body ?? data['body'] ?? '').toString().trim();
    final orderId = data['orderId']?.toString().trim() ?? '';
    final link = data['link']?.toString().trim() ?? '';
    if (title.isEmpty && orderId.isEmpty && link.isEmpty) return;

    await FcmPendingTap(
      title: title,
      body: body,
      orderId: orderId,
      serial: data['serial']?.toString() ?? '',
      kind: (data['kind'] ?? data['status'] ?? '').toString(),
      link: link,
    ).persist();
    unawaited(_drainLoop());
  }

  /// يستنزف الطلب المعلّق عند جاهزية التطبيق (مع إعادة محاولة قصيرة).
  Future<void> _drainLoop() async {
    if (_draining) return;
    _draining = true;
    try {
      // ننتظر جاهزية الـ navigator وتسجيل الدخول (حتى ٣٠ ثانية).
      for (var i = 0; i < 60; i++) {
        if (_ready()) {
          final tap = await FcmPendingTap.load();
          if (tap != null) {
            await tap.clear(); // مرة واحدة فقط
            _open(tap);
          }
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } finally {
      _draining = false;
    }
  }

  bool _ready() {
    if (appNavigatorKey.currentState == null) return false;
    final phone = AuthService.instance.phone;
    return phone != null && phone.isNotEmpty;
  }

  /// يقرأ ما التقطه Android (intent الإقلاع أو خدمة FCM) ويحفظه
  /// كطلب معلّق. يُستدعى بعد إقلاع المحرك.
  Future<void> ingestNativeLaunchPayload() async {
    final payload = await FcmLaunch.instance.consume();
    if (payload == null) return;
    await ingestPayloadTap(payload, kindKey: 'status');
  }

  /// يحوّل حمولة إشعار (من أي مسار أصلي) إلى طلب معلّق ثم يستنزفه.
  /// يستعمله آيفون أيضاً: حمولته تأتي من APNs مباشرةً بلا Firebase.
  Future<void> ingestPayloadTap(
    Map<String, String> payload, {
    String kindKey = 'kind',
  }) async {
    final orderId = (payload['orderId'] ?? '').trim();
    final link = (payload['link'] ?? '').trim();
    final title = (payload['title'] ?? '').trim();
    if (orderId.isEmpty && link.isEmpty && title.isEmpty) return;
    await FcmPendingTap(
      title: title,
      body: payload['body'] ?? '',
      orderId: orderId,
      serial: payload['serial'] ?? '',
      kind: payload[kindKey] ?? '',
      link: link,
    ).persist();
    unawaited(_drainLoop());
  }

  /// يفتح الشاشة المناسبة.
  void _open(FcmPendingTap tap) {
    // ★ إشعار العيادة: إلى شاشة الموافقات — قبل فحص صفة المندوب، فقد
    //   يحمل حساب السكرتير صفة مندوب أيضاً، والرابط هنا صريح.
    if (tap.link == 'appointments') {
      try {
        appNavigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => const SecretaryAppointmentsScreen(),
          ),
        );
      } catch (_) {}
      return;
    }

    // المندوب: شاشته الرئيسية قائمة الطلبات وتُبنى تلقائياً ⇒ لا تنقّل.
    if (AuthService.instance.isDriver) return;

    // طلب ⇒ شاشة تتبع التوصيل (تقرأ تفاصيل الطلب بنفسها).
    if (tap.orderId.isEmpty) return;
    final serial = tap.serial.isEmpty ? '' : '#${tap.serial}';
    try {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => OrderTrackingScreen(
            orderId: tap.orderId,
            orderNumber: serial,
          ),
        ),
      );
    } catch (_) {
      // تعذّر التنقّل — لا نكسر التطبيق.
    }
  }
}
