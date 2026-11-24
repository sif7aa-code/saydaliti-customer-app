import 'dart:async';
// ★ مثل `main.dart` تماماً: `dart:io` لكتابة سجلّ الأعطال تُستبدل على
//   المتصفح ببدائل صامتة (`core/io_stub_web.dart`)، وعلى أندرويد/ويندوز
//   تُستخدم المكتبة الحقيقية نفسها حرفياً — لا سلوك مختلف على الهاتف.
//   الهدف: تشغيل اللوحة في كروم للمعاينة بلا بناء APK.
import 'core/io_stub_web.dart' if (dart.library.io) 'core/io_native.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/admin_panel_app.dart';
import 'services/admin_password_session.dart';
import 'services/auth_service.dart';

/// ★ نقطة تشغيل **تطبيق الأدمن المنفصل** (`com.saydaliti.adminpanel`).
///
/// تُبنى بهذا الملف وحده: `flutter build apk --target lib/main_admin.dart`.
/// ما لا يصله ملف التشغيل يُسقطه Flutter من الملف الأصلي (`libapp.so`)،
/// فلا وجود لشاشات الزبون ولا للمنتج ولا للسلة في نسخة الأدمن — كما أن
/// شاشات اللوحة لم تعد موجودة في نسخة الزبائن.
///
/// ★ **لا Firebase ولا إشعارات ولا خدمة خلفية هنا عمداً**: لا `PushService`،
///   ولا `FcmRouter`، ولا `BackgroundMonitor`. اللوحة تُفتح عند الحاجة
///   وتُغلق، فلا داعي لإبقاء العملية حيّة ولا لإشعار «عمل التطبيق في
///   الخلفية». الطلبات تصل إلى القاعدة مباشرة عند فتح اللوحة.
Future<void> _writeCrashLog(Object error, StackTrace stack) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}admin_log.txt');
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
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _writeCrashLog(details.exception, details.stack ?? StackTrace.current);
  };
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // ★ نفس سلسلة تطبيق الزبون: استرجاع الجلسة المحفوظة من القرص،
      //   فتُقرأ الأدمنية (`is_admin`) ويُحدَّث الدور من الخادم
      //   (`AuthService.init` يبدأ الدورة بنفسه) — بلا تسجيل دخول لكل فتح.
      await AuthService.instance.init();

      // ★ تذكرة فتح اللوحة: تُستعاد من الفتح السابق حتى لا يُسأل الأدمن
      //   بعد قفل الهاتف وفتحه. الفحص الصامت منها في القاعدة مرة واحدة
      //   لكل فتح — داخل `AdminPanelGate.open` كما كان تماماً.
      await AdminPasswordSession.restore();

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

      // الخطوط من الأصول المضمّنة لا من الإنترنت (نفس إعداد تطبيق الزبون).
      GoogleFonts.config.allowRuntimeFetching = false;

      runApp(const AdminPanelApp());
    },
    (error, stack) {
      _writeCrashLog(error, stack);
    },
  );
}
