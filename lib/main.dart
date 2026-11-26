import 'dart:async';
// `dart:io` للكتابة في ملف السجل: على الويب تُستبدل ببدائل صامتة
// (`core/io_stub_web.dart`) حتى يُبنى التطبيق للمتصفح بلا كسل على الهاتف.
import 'core/io_stub_web.dart' if (dart.library.io) 'core/io_native.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'services/auth_service.dart';
import 'services/background_poller.dart';
import 'services/device_sound.dart';
import 'services/fcm_background_handler.dart';
import 'services/fcm_router.dart';
import 'services/ios_push_service.dart';
import 'services/location_service.dart';
import 'services/notification_channel_settings.dart';
import 'services/notification_sound.dart';
import 'services/notify_health.dart';
import 'services/push_service.dart';
import 'services/real_data_service.dart';
import 'services/system_notification.dart';

/// يكتب أي خطأ غير مسبوق (Uncaught Exception / Flutter Error) إلى ملف
/// داخل مجلد التطبيق حتى يمكن تشخيص السبب لاحقاً من الجهاز مباشرة.
Future<void> _writeCrashLog(Object error, StackTrace stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}app_log.txt');
    final logFile = await file.open(mode: FileMode.append);
    final entry = StringBuffer()
      ..writeln('---- ${DateTime.now().toIso8601String()} ----')
      ..writeln('$error')
      ..writeln(stack.toString())
      ..writeln('');
    logFile.writeString(entry.toString());
    await logFile.flush();
    await logFile.close();
  } catch (_) {}
}

Future<void> main() async {
  // حاجز أمان شامل: أي خطأ غير مسبوق يكتب في ملف السجل بدل إسكاته،
  // ويمنع تعطّل كامل التطبيق بسبب خطأ في بنية شاشة واحدة.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _writeCrashLog(details.exception, details.stack ?? StackTrace.current);
  };
  await runZonedGuarded<Future<void>>(
    () async {
      // تهيئة الحزم داخل نفس الزون الذي يُشغَّل فيه التطبيق (يمنع
      // خطأ "Zone mismatch" على الويب).
      WidgetsFlutterBinding.ensureInitialized();

      // ── إشعارات FCM: تسجيل معالج الخلفية قبل أي شيء آخر ──
      // يجب أن يكون هذا **قبل** runApp وقبل استقبال أي رسالة: معالج
      // الخلفية دالة top-level، وتسجيلها هنا يضمن عملها في نسخة Release
      // (خارج حالة Debug) أي عندما يكون التطبيق مغلقاً/مُقتلاً.
      try {
        FirebaseMessaging.onBackgroundMessage(fcmBackgroundMessageHandler);
      } catch (e) {
        _writeCrashLog(e, StackTrace.current);
      }
      // ★ مراقبة الخلفية الدائمة: تسجيل قناة `strasopa/bg_monitor`
      //   قبل runApp، فالخدمة الأمامية الأصلية تنادي `tick` كل دقيقة
      //   فتُنفَّذ جولة استطلاع الإشعارات والتطبيق مغلق.
      //   (استُبدلت هنا بحزمة workmanager لأنها لا تُبنى مع Gradle الحالي.)
      try {
        await BackgroundMonitor.instance.init();
      } catch (e) {
        _writeCrashLog(e, StackTrace.current);
      }
      // موجّه ضغطات الإشعارات (يتضمن getInitialMessage بعد الإقلاع).
      FcmRouter.instance.start();
      // استعادة بيانات تسجيل الدخول المحفوظة قبل عرض التطبيق
      // حتى لا تظهر شاشة تسجيل الدخول مرة أخرى بعد أول دخول.
      await AuthService.instance.init();
      // ★ بوابة لوحة التحكم انتقلت إلى تطبيق الأدمن المنفصل (2026-10-11):
      //   نسخة الزبائن لم تعد تستعيد تذكرة اللوحة ولا تفتحها أصلاً،
      //   فاستعادة التذكرة صارت في `main_admin.dart`.

      // آخر موقع محفوظ على الجهاز: يُعرض في الأعلى فور فتح التطبيق
      // بدل رسالة "جاري تحديد موقعك..." (يُعاد تحديده مع كل طلب جديد).
      await LocationService.instance.loadSaved();

      // إشعارات Firebase (FCM): بعد عرض التطبيق.
      // ⚠️ await هنا كان يؤخّر أول إطار ⇒ شاشة سوداء عند الفتح.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // ★ آيفون: Firebase أولاً (تطبيق iOS في مشروع diqarapp). وإن غاب
        //   ملف الإعداد في بناءٍ ما يبقى جسر APNs المباشر حتى لا يصمت
        //   الجهاز — فلا نُسجّل التوكن مرتين أبداً.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          await PushService.instance.init();
          if (PushService.instance.isReady) {
            unawaited(PushService.instance.start());
          } else {
            unawaited(IosPushService.instance.start());
          }
          return;
        }
        unawaited(PushService.instance.start());
      });

      // نغمات تنبيه الإشعارات: تحميلها مسبقاً حتى لا يتأخر أول إشعار.
      unawaited(NotificationSound.instance.load());
      unawaited(NotificationSound.instance.preload());
      // نغمة الإشعار التي اختارها المستخدم في إعدادات الهاتف.
      unawaited(NotificationChannelSettings.instance.init());
      // نغمة أصوات الهاتف التي اختارها المستخدم (تُحفظ على الجهاز).
      unawaited(DeviceSound.load());

      // ★ خدمة المراقبة الخلفية لا تُشغَّل من هنا بعد اليوم (طلب
      //   2026-11-02: «إشعارات خارجية حتى لو التطبيق مغلق بدون
      //   الاعتماد على التشغيل في الخلفية»). الذي يقررها هو
      //   `NotificationCenter._loadBrand` حين يعرف إن كان لهذا الحساب
      //   توكن FCM يستقبل من الخادم: له توكن ⇒ لا خلفية إطلاقاً، ولا
      //   توكن ⇒ شبكة الأمان وحدها. تسجيل القناة في `init()` أعلاه
      //   يكفي؛ فالنداء عند الحاجة يصير لاحقاً.

      // إشعارات النظام: تجهيز بعد أول إطار.
      unawaited(SystemNotification.instance.init());

      // ★ فحص صحة الإشعارات: إذن النظام وتقييد البطارية.
      //   بلا هذا يظل المستخدم ينتظر إشعاراً لن يصل، لأن FCM يردّ
      //   للسيرفر «تم» بينما النظام على الجهاز يُسقطه بصمت.
      NotifyHealth.instance.start();

      // ★ الكتالوج (أقسام/صيدليات/بانرات/منتجات) يبدأ التحميل من الآن، لا من
      //   أول ضغطة تبويب: زمن شاشة البداية كان يُمضى بلا أي طلب شبكة، ثم
      //   تقف الرئيسية منتظرةً أربع رحلات تبدأ بعدها. `unawaited` مقصود —
      //   لا يُؤخّر أول إطار، ومن يصل للكتالوج لاحقاً ياخذ نسخة الجهاز
      //   فوراً ويُحدَّث في الخلفية (`_Dataset` نفسه).
      unawaited(RealDataService.instance.prefetchCatalog());

      // التمدد الكامل من حافة إلى حافة (يمنع المساحات البيضاء الجانبية التي
      // يضيفها النظام على الشاشات الطويلة) مع إبقاء ألوان أشرطة النظام بيضاء
      // متناسقة مع خلفية التطبيق.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );

      // استخدم الخطوط المضمّنة محلياً داخل الأصول بدل تحميلها من الإنترنت
      // (ضروري لإظهار الخط الصحيح وقياساته نفسها على جميع الأجهزة حتى بدون إنترنت).
      GoogleFonts.config.allowRuntimeFetching = false;
      runApp(const StrasopaApp());

      // بعد runApp يصبح MethodChannel على Android جاهزاً، فَنقرأ عندها ما
      // التقطه Android عند الإقلاع من إشعار (نية الإقلاع / خدمة FCM).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FcmRouter.instance.ingestNativeWhenReady();
      });
    },
    (error, stack) {
      _writeCrashLog(error, stack);
    },
  );
}
