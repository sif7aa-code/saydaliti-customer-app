import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:saydaliti/app.dart';
import 'package:saydaliti/screens/cart_screen.dart';
import 'package:saydaliti/screens/doctor_appointment_screen.dart';
import 'package:saydaliti/screens/free_driver_request_screen.dart';
import 'package:saydaliti/screens/login_screen.dart';
import 'package:saydaliti/screens/services_screen.dart';
import 'package:saydaliti/services/auth_service.dart';
import 'package:saydaliti/services/notification_center.dart';
import 'package:saydaliti/services/realtime_service.dart';
import 'package:saydaliti/widgets/bottom_nav_bar.dart';
import 'package:saydaliti/widgets/location_header.dart';

/// ★ الشريط السفلي الجديد: «خدمات» بدل «السلة»، والسلة صارت دائرة
///   بجانب جرس الإشعارات أعلى الرئيسية.
///
///   المُحكّ هنا هو **أين تُفتح السلة ولمن**، لأن نقلها يمسّ أمرين:
///   * الزائر: النقرة على الدائرة لا تفتح سلة بلا هوية، بل تمرّ ببوابة
///     الدخول — نفس ما كان التبويب القديم يفعله.
///   * المسجّل: النقرة تفتح السلة **صفحةً** بزر رجوع، فاختفاء الرجوع
///     يعني مستخدمًا محبوسًا في سلالته بلا طريق إلى الرئيسية.
///
///   بلا شبكة: كل نداء يردّ 400 في الاختبارات، ولا يهمّ — فالمقصود هو
///   أي شاشة فُتحت، وهو قرار محلي.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// نبضات محددة لا `pumpAndSettle`: البانرات مؤقّت دائم في الرئيسية.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> view(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// المؤقّتات الدورية تُطفأ داخل الجسم لا في `addTearDown`: إطار
  /// flutter_test يفحص المعلّق منها قبل ترتيبات التفكيك.
  Future<void> silenceBackground(WidgetTester tester) async {
    NotificationCenter.instance.stop();
    RealtimeService.instance.stop();
    await tester.pump();
  }

  Future<void> logIn() async {
    // ★ رقم وهمي صراحةً (أصفار بعد المقدّمة): لا اسم مخترع في الاختبارات.
    //   التوكن غائب عمداً: بدونه لا تبدأ مرورية الأدوار (مؤقّت معلّق).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AuthService.loggedInPrefKey, true);
    await prefs.setString('auth_phone', '07000000000');
    await AuthService.instance.init();
  }

  Finder cartDot() => find.descendant(
    of: find.byType(LocationHeader),
    matching: find.byIcon(Icons.shopping_cart_outlined),
  );

  Future<void> tapCartDot(WidgetTester tester) async {
    await tester.tap(cartDot());
    await settle(tester);
  }

  Future<void> tapNav(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text(label),
      ),
    );
    await settle(tester);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AuthService.instance.accountDeletedLocally();
  });

  tearDown(() async {
    await AuthService.instance.accountDeletedLocally();
  });

  testWidgets('المسجّل: دائرة السلة تفتحها صفحة بزر رجوع', (tester) async {
    await view(tester);
    await logIn();
    expect(AuthService.instance.isLoggedIn, isTrue);

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);

    expect(cartDot(), findsOneWidget);
    expect(find.byType(CartScreen), findsNothing);

    await tapCartDot(tester);

    expect(find.byType(CartScreen), findsOneWidget);
    // ★ الرجوع موجود: بلا هذا السهم لا يعود المستخدم إلى الرئيسية.
    expect(
      find.descendant(
        of: find.byType(CartScreen),
        matching: find.byType(BackButton),
      ),
      findsOneWidget,
    );
    expect(find.text('السلة'), findsWidgets);

    Navigator.of(tester.element(find.byType(CartScreen))).pop();
    await settle(tester);
    expect(find.byType(CartScreen), findsNothing);
    // وعاد إلى الرئيسية: الدائرة في مكانها.
    expect(cartDot(), findsOneWidget);

    await silenceBackground(tester);
  });

  testWidgets('الزائر: دائرة السلة تمرّ ببوابة الدخول ولا تفتح سلة', (
    tester,
  ) async {
    await view(tester);
    expect(AuthService.instance.isLoggedIn, isFalse);

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);

    await tapCartDot(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(CartScreen), findsNothing);

    await silenceBackground(tester);
  });

  testWidgets('«خدمات» للزائر: بوابة دخول قبل أن تُفتح القائمة', (
    tester,
  ) async {
    await view(tester);

    // 1) الزائر: النقرة على «خدمات» بوابة دخول، لا شاشة طلب.
    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);

    await tapNav(tester, 'خدمات');
    // البوابة فوق الهيكل فلا الرئيسية تحته تُرى، ولا التبويب فُتح.
    expect(find.byType(LoginScreen), findsOneWidget);

    await silenceBackground(tester);
  });

  testWidgets('«خدمات» للمسجّل: قائمة اختيارات، لا شاشة طلب مباشرة', (
    tester,
  ) async {
    await view(tester);
    await logIn();

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);

    // الرئيسية وهي ظاهرة (دائرة السلة لا تُرسم إلا فيها): بطاقة «اطلب
    // مندوب توصيل» انتقلت من هنا إلى التبويب، فلم يعد لها أثر.
    expect(cartDot(), findsOneWidget);
    expect(find.text('اطلب مندوب توصيل'), findsNothing);

    await tapNav(tester, 'خدمات');

    // التبويب يفتح مباشرة: لا بوابة لمن هو داخل حسابه.
    expect(find.byType(LoginScreen), findsNothing);
    // ★ 10-31: التبويب صار **قائمة خدمات** — طلب المندوب لم يعد هو
    //   التبويب نفسه، بل بوابة أولى فيه.
    expect(find.byType(ServicesScreen), findsOneWidget);
    expect(find.byType(FreeDriverRequestScreen), findsNothing);
    expect(find.text('طلب مندوب'), findsWidgets);
    // ★ 11-04: المربّعان لا البطاقات العريضة — والاسم في المربّع صار
    //   «حجز طبيب» قصيراً ليسع المربّع؛ شاشة الحجز نفسها لم يَتغيّر عنوانها.
    expect(find.text('حجز طبيب'), findsWidgets);
    // وشاشة الحجز لا تُبنى قبل طلبها.
    expect(find.byType(DoctorAppointmentScreen), findsNothing);

    await silenceBackground(tester);
  });
}
