import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:saydaliti/app.dart';
import 'package:saydaliti/screens/login_screen.dart';
import 'package:saydaliti/services/auth_service.dart';
import 'package:saydaliti/services/notification_center.dart';
import 'package:saydaliti/services/realtime_service.dart';
import 'package:saydaliti/widgets/bottom_nav_bar.dart';

/// ★ حارس نقرة «حسابي» — الشرط الذي طلبه الأدمن حرفياً:
///   **انقله إلى شاشة تسجيل الدخول فقط إن لم يسجّل.**
///
///   فالزائر الذي يضغط زرّ «حسابي» يجب أن يجد شاشة الدخول — وفيها
///   «أنشئ حساباً جديداً» — لا شريطاً أعلى الشاشة يختفي بعد ثانيتين ولا
///   صفحة تنتظر منه أن يضغط زرّاً آخر. أما من هو داخل حسابه فالنقرة نفسها
///   تفتح تبويبه كما كانت، ولا تُظهر شاشة دخول إطلاقاً.
///
///   ★ لماذا اختباران متقابلان لا اختبار واحد؟ لأن نصف الطلب هو «فقط»:
///   لو أُلغي الشرط لصار كل زبون مسجّل يرى شاشة دخول عند كل نقرة على
///   حسابه — وهو أسوأ من العطل الأصلي. فلا يُقبل هذا الإصلاح إلا بدليل
///   أن المسجّل لا تنتقل به النقرة إلى أي شاشة دخول.
///
///   بلا شبكة: كل نداء يردّ 400 في الاختبارات، فلا بيانات تُرسم — وهذا
///   لا يهم، فالمُحكّ هو **أي شاشة فُتحت**، وهو قرار محلي لا يعتمد على
///   الجواب.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// ★ نبضات محددة لا `pumpAndSettle`: الرئيسية فيها مؤقّت دائم (البانرات
  ///   تتبدّل كل سبع ثوانٍ) فـ`pumpAndSettle` تسقط «timed out» أبداً —
  ///   نفس القرار الموثّق في `widget_test.dart`.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> tapAccountTab(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text('حسابي'),
      ),
    );
    await settle(tester);
  }

  /// ★ يُطفئ الخلفيات قبل نهاية الجسم، لا في `tearDown`.
  ///
  ///   إطار flutter_test يفحص المؤقّتات المعلّقة **بعد الجسم مباشرة وقبل**
  ///   ترتيبات التفكيك، فأي `Timer` حيّ عند آخر سطر = تقرير أحمر على شيء
  ///   ليس عيباً في الكود. مركز الإشعارات نبضة كل ثانية، وهو الذي يشغّل
  ///   خدمة اللحظي (اتصال ثم إعادة محاولة بعد ستّ ثوانٍ)، فيُطفآن معاً
  ///   وبهذا الترتيب: اللحظي لا يوقظه أحد بعد إيقاف المركز.
  Future<void> silenceBackground(WidgetTester tester) async {
    NotificationCenter.instance.stop();
    RealtimeService.instance.stop();
    await tester.pump();
  }

  setUp(() async {
    // كل اختبار يبدأ من قرص نظيف: الحالة تُضبط صراحةً في الأسفل، فلا
    // يتسرّب تسجيل دخول من اختبار إلى الاختبار الذي بعده.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AuthService.instance.accountDeletedLocally();
  });

  tearDown(() async {
    // الجلسة تُطفأ بلا رحلة شبكة: `accountDeletedLocally` تفعل التنظيف
    // المحلي وحده، فلا يبقى مستخدم «مسجّل» يتسرّب إلى الاختبار التالي.
    await AuthService.instance.accountDeletedLocally();
  });

  testWidgets('غير المسجّل: «حسابي» تنقله إلى شاشة تسجيل الدخول', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    expect(AuthService.instance.isLoggedIn, isFalse);

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);

    // الزائر داخل الهيكل: شريطه السفلي موجود ولم تُفتح أي شاشة دخول بعد.
    expect(find.byType(BottomNavBar), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);

    await tapAccountTab(tester);

    // ★ النتيجة المطلوبة: شاشة الدخول فوق الهيكل، بزرّ رجوع حتى لا يُحبس.
    expect(find.byType(LoginScreen), findsOneWidget);
    // وفيها طريق التسجيل لمن لا يملك حساباً أصلاً — وهو حال «مستخدم جديد».
    expect(find.textContaining('أنشئ حساباً'), findsWidgets);

    await silenceBackground(tester);
  });

  testWidgets('المسجّل دخوله: «حسابي» لا تنقله إلى شاشة الدخول', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // جلسة محفوظة على القرص الوهمي ⇒ `init` يبني حالة دخول حقيقية في
    // هذا الاختبار. التوكن يبقى غائباً عمداً: بدونه لا تبدأ مرورية الأدوار
    // (مؤقّت دوري معلّق يُفشل الاختبار بلا سبب)، والمقصود هو «داخل
    // التطبيق» لا «جلسة حيّة».
    //
    // ★ الرقم وهمي صراحةً (أصفار بعد المقدّمة): لا اسم مخترع في
    //   الاختبارات، وصفحة «حسابي» تعرض ما في القرص كما هو.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AuthService.loggedInPrefKey, true);
    await prefs.setString('auth_phone', '07000000000');
    await AuthService.instance.init();
    expect(AuthService.instance.isLoggedIn, isTrue);

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);

    // هو داخل حسابه: الشريط ظاهر ولا شاشة دخول قبل النقر.
    expect(find.byType(BottomNavBar), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);

    await tapAccountTab(tester);

    // ★ الشقّ الثاني من الطلب: لا تحويل لمن هو مسجّل.
    expect(find.byType(LoginScreen), findsNothing);
    // والصفحة التي فُتحت ليست صفحة الزائر («أنت تدخل كزائر»): بل صفحته.
    expect(find.textContaining('أنت تدخل كزائر'), findsNothing);

    await silenceBackground(tester);
  });
}
