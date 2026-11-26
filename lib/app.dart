import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme/app_theme.dart';
import 'screens/chat_screen.dart' show openChatFromLink;
import 'screens/doctor_shell.dart';
import 'screens/driver_orders_screen.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'screens/my_doctor_appointments_screen.dart';
import 'screens/secretary_appointments_screen.dart';
import 'screens/shop_owner_shell.dart';
import 'services/auth_service.dart';
import 'services/chat_service.dart';
import 'services/city_store.dart';
import 'services/location_service.dart';
import 'services/notification_center.dart';
import 'services/presence_service.dart';
import 'services/push_service.dart';
import 'services/status_center.dart';
import 'services/update_guard.dart';
import 'widgets/city_picker_sheet.dart';

/// مفتاح تنقّل عمومي لإعادة توجيه المستخدم لشاشة تسجيل الدخول
/// فوراً عند حذف حسابه أو تعطيله من لوحة الأدمن.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// يسمح بالسحب اليدوي للتمرير بالماوس واللمس (بدون شريط تمرير).
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class StrasopaApp extends StatefulWidget {
  const StrasopaApp({super.key});

  @override
  State<StrasopaApp> createState() => _StrasopaAppState();
}

class _StrasopaAppState extends State<StrasopaApp> with WidgetsBindingObserver {
  /// آخر حساب مرّ على الواجهة — لتحديد تغيّر الحساب مرة واحدة فقط.
  static String? _lastPhone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // تسجيل الـ Overlay ومركز الإشعارات **مرة واحدة**: كانا داخل
    // `build()`، فيُجدَّدان مع كل إعادة بناء للتطبيق.
    NotificationCenter.instance.start();
    // ★ إشعار السكرتير «حجز جديد بانتظار موافقتك» يفتح شاشة الموافقات
    //   عند الضغط — الرابط الداخلي `appointments` لا يُفتح خارجياً.
    NotificationCenter.onAppointmentsTap = () {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => const SecretaryAppointmentsScreen(),
        ),
      );
    };
    // ★ إشعار دور المريض: يفتح «حجوزاتي» — والبطاقة في الرئيسية تختفي
    //   وحدها بعد انتهاء المعاينة، والسجل يبقى هنا.
    NotificationCenter.onBookingsTap = () {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => const MyDoctorAppointmentsScreen(),
        ),
      );
    };
    // ★ إشعار دردشة العيادة: يفتح المحادثة داخل التطبيق لا رابطاً خارجياً.
    NotificationCenter.onChatTap = openChatFromLink;
    // ★ شارة الدردشة تُحدَّث في كل التطبيق من مصدر واحد.
    ChatService.instance.startPolling();
    // ★ حضور الدردشة: فتح التطبيق = «متصل الآن» الآن وكل ٣٠ ثانية.
    PresenceService.instance.markOnline();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      StatusCenter.instance.attach(context);
      // رسالة التحديث: فحص واحد لكل فتح للتطبيق، والقرار كله من `app_settings`.
      unawaited(UpdateGuard.instance.start(appNavigatorKey.currentContext));
      unawaited(_askCityIfFirstRun());
    });
  }

  /// «اختر مدينتك»: مرة واحدة على الجهاز. المحفوظة تُقرأ قبل العرض فلا
  /// تظهر الورقة مجدداً في أي فتح لاحق.
  static bool _cityChecked = false;
  Future<void> _askCityIfFirstRun() async {
    if (_cityChecked) return;
    _cityChecked = true;
    await CityStore.instance.load();
    if (!mounted || CityStore.instance.hasChoice) return;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final city = await showCityPicker(ctx);
    if (city != null) await CityStore.instance.save(city);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // في المقدمة ⇒ بطاقة داخل التطبيق + نغمة خفيفة.
    // في الخلفية ⇒ إشعار نظام حقيقي بصوت قناته وشعار الحساب.
    NotificationCenter.instance.setForeground(
      state == AppLifecycleState.resumed,
    );
    // عند كل فتح: نضمن حفظ توكن الجهاز في حسابه (يبقى محفوظاً دائماً).
    if (state == AppLifecycleState.resumed) {
      // ★★ العودة للمقدمة: تحديث الدور **الآن** ثم استئناف المراقبة.
      //   كان المؤقّت يعمل في الخلفية كل ٢٠ ثانية بلا فائدة تُرى.
      unawaited(AuthService.instance.refreshFromServer());
      AuthService.instance.resumeRoleWatch();
      unawaited(PushService.instance.ensureTokenSaved());
      // ★ حاضر الآن، ونبضة تجديد تبدأ من هنا.
      PresenceService.instance.markOnline();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // ★★ مطويّ/غير مرئي: لا فائدة من فحص الدور الدوري بلا واجهة.
      AuthService.instance.pauseRoleWatch();
      // ★ خرج من التطبيق ⇒ يُختم «آخر ظهور» الآن. `inactive` العابر
      //   (إشعار أو مكالمة) ليس خروجاً فلا يُحسب.
      if (state != AppLifecycleState.inactive) {
        PresenceService.instance.markOffline();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'اطباء ذي قار',
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: AppTheme.light,
      scrollBehavior: const _AppScrollBehavior(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: ListenableBuilder(
          listenable: AuthService.instance,
          builder: (context, _) {
          final auth = AuthService.instance;
          // أي تغيّر في الحساب (دخول/خروج/تعطيل) ⇒ تنظيف قائمة الإشعارات
          // وإعادة جلب شعار الحساب الجديد.
          if (auth.phone != _lastPhone) {
            _lastPhone = auth.phone;
            StatusCenter.activeAccountPhone = auth.phone;
            // موقع هذا الحساب وحده (عزل كامل بين المستخدمين).
            LocationService.instance.setAccount(auth.phone);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => NotificationCenter.instance.onAccountChanged(),
            );
            // ★ تبديل الحساب: صفّر/حدّث شارة الدردشة الآن لا بعد دورة.
            unawaited(ChatService.instance.refreshUnread());
            // ★ الحساب الجديد يُعلن حضوره فوراً؛ والخروج يختم آخر ظهور.
            if ((auth.phone ?? '').trim().isEmpty) {
              PresenceService.instance.markOffline();
            } else {
              PresenceService.instance.markOnline();
            }
          }
          final removed = auth.accountRemoved;
          if (removed) {
            _redirectToLogin();
          }
          // المندوب يفتح شاشة الطلبات مباشرة.
          if (auth.isDriver) return const DriverOrdersScreen();
          // ★ صاحب الصيدلية: منتجاته ومحفظته وإشعاراته فقط، بلا بقية
          //   أزرار التطبيق. والأدمن يُستثنى: لوحته شغل لا عمل.
          if (auth.isShopOwner && !auth.isAdmin) return const ShopOwnerShell();
          // ★ الطبيب/سكرتير العيادة: حجوزاته ومحفظته وإشعاراته فقط.
          //   الدور يُكتشف من `doctors` (مرة كل دقيقة) ويُحفظ محلياً.
          if (auth.isClinicAccount) return const DoctorShell();
          // حساب محذوف/معطّل يرى شاشة تسجيل الدخول دائماً.
          if (removed) return const LoginScreen();
          return MainShell(isGuest: !auth.isLoggedIn);
          },
      ),
    );
  }

  /// إعادة توجيه واحدة لشاشة تسجيل الدخول وتفريغ كل شاشات التطبيق.
  static bool _redirectingRemoved = false;
  static void _redirectToLogin() {
    if (_redirectingRemoved) return;
    _redirectingRemoved = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ★ تفريغ كل ما فوق `home` فقط: `home` نفسه يعرض `LoginScreen`
      //   لأن `removed = true`، فلا دفعة ثانية تُخفي `home` خلف
      //   شاشة منتهية الصلاحية (وهي التي كانت تُبقيه حبيساً).
      appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      _redirectingRemoved = false;
    });
  }
}
