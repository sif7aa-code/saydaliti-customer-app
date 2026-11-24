import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'auth_service.dart';
import 'fcm_router.dart';
import 'supabase_service.dart';

/// إشعارات آيفون عبر APNs المباشر (بلا Firebase).
///
/// الجانب الأصلي (`AppDelegate.swift`) يسجّل الجهاز لدى آبل، فيصل هنا
/// توكن APNs ويُحفظ في `push_tokens` بمنصة `ios`، ومنها يرسل الخادم.
/// ونقرة الإشعار تصل كحمولة نصّية إلى [FcmRouter] نفسه المستعمل مع FCM،
/// فالشاشات والتوجيه سلوك واحد على كل الأنظمة.
class IosPushService {
  IosPushService._();
  static final IosPushService instance = IosPushService._();

  static const MethodChannel _channel = MethodChannel('saydaliti/apns');

  bool _started = false;
  String? _token;
  String? _savedToken;
  String? _savedPhone;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> start() async {
    if (!isSupported || _started) return;
    _started = true;
    _channel.setMethodCallHandler(_onCall);
    AuthService.instance.addListener(_onAuthChanged);
    try {
      await _channel.invokeMethod<void>('ready');
      // نقرة فتحت التطبيق من إشعار والتطبيق مقتول (تُقرأ مرة واحدة).
      final launch = _stringMap(await _channel.invokeMethod<dynamic>('getLaunchTap'));
      if (launch != null) {
        await FcmRouter.instance.ingestPayloadTap(launch);
      }
      final token = await _channel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) await _save(token);
    } catch (e) {
      if (kDebugMode) print('APNs bridge start error: $e');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'token':
        final token = call.arguments?.toString() ?? '';
        if (token.isNotEmpty) await _save(token);
        return null;
      case 'tokenError':
        if (kDebugMode) print('APNs token error: ${call.arguments}');
        return null;
      case 'tap':
        final payload = _stringMap(call.arguments);
        if (payload != null) {
          await FcmRouter.instance.ingestPayloadTap(payload);
        }
        return null;
      default:
        return null;
    }
  }

  /// يحفظ التوكن في حساب المستخدم — ويُعاد عند كل تبديل حساب بالدخول.
  Future<void> _save(String token) async {
    _token = token;
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) return;
    if (_savedToken == token && _savedPhone == phone) return;
    try {
      await SupabaseService.instance.registerPushToken(
        phone,
        token,
        platform: 'ios',
        deviceLabel: 'iOS',
      );
      _savedToken = token;
      _savedPhone = phone;
    } catch (e) {
      if (kDebugMode) print('APNs token save error: $e');
    }
  }

  /// دخول جديد (أو نفسه بعد خروج): يُعاد تفعيل صفّ الجهاز، لأن الخروج
  /// يُبطله (`deactivate_own_push_tokens`) والسيرفر لا يرسل لصفّ معطّل.
  void _onAuthChanged() {
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      _savedPhone = null;
      return;
    }
    final token = _token;
    if (token != null && token.isNotEmpty) unawaited(_save(token));
  }

  static Map<String, String>? _stringMap(Object? raw) {
    if (raw is! Map) return null;
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key == null || value == null) return;
      out[key.toString()] = value.toString();
    });
    return out.isEmpty ? null : out;
  }
}
