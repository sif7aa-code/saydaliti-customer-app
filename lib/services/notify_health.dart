/// صحة الإشعارات على الجهاز — الفحص والتوجيه.
///
/// ★ لماذا؟
///   FCM يردّ «تم الإرسال» للسيرفر حتى لو كان إذن الإشعارات
///   مسحوباً على الجهاز، والنظام حينها **يُسقط** الإشعار بصمت.
///   وكذلك «تحسين البطارية» يقتل الخدمة فيتوقف الاستطلاع.
///   لا شيء من هذا يظهر للمستخدم، فيظن أن التطبيق لا يرسل شيئاً.
///   هذه الخدمة تفحص الحالتين، وتفتح له إعدادات النظام مباشرة.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart' show appNavigatorKey;
import '../core/theme/app_colors.dart';
import 'auth_service.dart';
import 'notification_channel_settings.dart';

class NotifyHealth with WidgetsBindingObserver {
  NotifyHealth._();
  static final NotifyHealth instance = NotifyHealth._();

  static const MethodChannel _ch = MethodChannel('strasopa/notification_channels');
  static const String _kLastPrompt = 'notify_health_prompt_v1';

  /// ذرّة الحوار: لا نفتحه مرتين متزامنتين (resume + مؤقت الإقلاع).
  static bool _asking = false;

  bool _started = false;

  /// يُستدعى قبل `runApp`: يسجّل المراقب ويجدول أول فحص بعد أن
  /// ينتهي حوار إذن النظام (كنا نطالب به في نفس الإقلاع).
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(seconds: 20), maybeNudge);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future<void>.delayed(const Duration(seconds: 2), maybeNudge);
    }
  }

  Future<bool> _notificationsEnabled() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _ch.invokeMethod<bool>('appNotificationsEnabled') ?? true;
    } catch (_) {
      // القناة غير متاحة ⇒ لا نفتح حواراً على شكّ.
      return true;
    }
  }

  Future<bool> _batteryUnrestricted() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _ch.invokeMethod<bool>('batteryUnrestricted') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// يفحص ويُظهر دليلاً مرة كل ٦ ساعات على الأكثر لكل حالة.
  Future<void> maybeNudge() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (!AuthService.instance.isLoggedIn) return;
    if (_asking) return;

    final enabled = await _notificationsEnabled();
    final battery = await _batteryUnrestricted();
    if (enabled && battery) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(_kLastPrompt) ?? 0;
    if (now - last < const Duration(hours: 6).inMilliseconds) return;

    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    await prefs.setInt(_kLastPrompt, now);
    if (!ctx.mounted) return;
    _asking = true;
    try {
      await _show(ctx, enabled: enabled, battery: battery);
    } finally {
      _asking = false;
    }
  }

  Future<void> _show(
    BuildContext ctx, {
    required bool enabled,
    required bool battery,
  }) async {
    final missing = [
      if (!enabled) 'إشعارات التطبيق مسحوبة من إعدادات الهاتف.',
      if (!battery) 'الهاتف يقيّد تشغيل التطبيق في الخلفية.',
    ];
    await showDialog<void>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(
          Icons.notifications_off_rounded,
          color: AppColors.primary,
          size: 32,
        ),
        title: Text(
          'الإشعارات قد تتأخر أو لا تصل',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 15),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              missing.join('\n'),
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(fontSize: 12.5, height: 1.8),
            ),
            const SizedBox(height: 6),
            Text(
              'وصول إشعارات الطلب والتوصيل والتطبيق مغلق يعتمد على هذين الإعدادين.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                height: 1.7,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          if (!enabled)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () {
                Navigator.pop(dCtx);
                NotificationChannelSettings.instance.openAppSettings();
              },
              child: Text(
                'فتح إعدادات الإشعارات',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
            ),
          if (!battery)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () {
                Navigator.pop(dCtx);
                unawaited(_openBatterySettings());
              },
              child: Text(
                'إلغاء تقييد البطارية',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(
              'لاحقاً',
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openBatterySettings() async {
    try {
      await _ch.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }
}
