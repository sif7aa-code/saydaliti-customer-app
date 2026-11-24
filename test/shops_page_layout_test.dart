import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/app.dart';
import 'package:saydaliti/screens/shops_screen.dart';
import 'package:saydaliti/services/notification_center.dart';
import 'package:saydaliti/widgets/bottom_nav_bar.dart';

/// ★ صفحة المتاجر بشكلها الجديد (مرجع 2026-10-30)
///
///   الاختبار بلا شبكة: كل نداء يردّ 400 فلا متاجر تُرسم. ما يُضمَن هنا هو
///   الهيكل الذي لا يعتمد على الشبكة — شريط البحث بمربّعه الأخضر، وترويسة
///   «جميع الصيدليات» — وأن بناء الصفحة لا يرمي استثناء تخطيط من داخلها
///   (فيض Column أو Row) على عرض الهاتف.
///
///   ★ لماذا لا يكفي `expect(takeException(), isNull)`؟ لأن `BottomNavBar`
///   المشترك يرمي فيضاً من 4 بكسل داخل اختبار الودجات: خط الاختبار البديل
///   يجعل كل حرف مربعاً بعرض حجمه، فتتصف «الرئيسية» في سطرين داخل ارتفاع
///   العنصر الثابت 64. هو فيض خطٍّ لا تصميم: يظهر في الرئيسية قبل أي تبديل
///   ويختفي عند عرض 800 حيث تسع التسمية سطرٌ واحد، وبخط Cairo الحقيقي على
///   الهاتف السطور تسع. لذلك تُستهلك هذه الاستثناءات صراحةً ويُفحص فقط ما
///   سبّبته صفحة المتاجر نفسها — لأن تعديل الشريط المشترك يمسّ كل الشاشات
///   خلافاً لأمر «لا تغيّر أي شيء آخر».
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// يلتقط استثناءات الرسم كلها أثناء الاختبار ويعيد منها ما سبّبته
  /// صفحة المتاجر (نسبةً لملفّها في سلسلة منشئ الـ RenderFlex).
  List<String> captureShopsPageErrors() {
    final mine = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      if (text.contains('file:///M:/strasopa/lib/screens/shops_screen.dart') ||
          text.contains('package:saydaliti/screens/shops_screen.dart')) {
        mine.add(text);
      }
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    return mine;
  }

  void useReferencePhone(WidgetTester tester) {
    // 360 هو أساس قياس المرجع نفسه: 576 بكسل ÷ 1.6.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openShops(WidgetTester tester) async {
    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text('المتاجر'),
      ),
    );
    await settle(tester);
    expect(find.byType(ShopsScreen), findsOneWidget);
  }

  /// الباحث داخل صفحة المتاجر وحدها: الرئيسية تبقى حيّة داخل
  /// `IndexedStack` بعد التبديل، فأيقونة المتجر وعنوان «المتاجر» موجودان
  /// في الشجرة معاً، والبحث الطليق يردّ عدداً أكبر فيُفشل اختباراً سليماً.
  Finder inShops(Finder matching) =>
      find.descendant(of: find.byType(ShopsScreen), matching: matching);

  testWidgets('تبويب المتاجر يعرض حقل البحث وترويسة «جميع الصيدليات»', (
    WidgetTester tester,
  ) async {
    useReferencePhone(tester);
    final mine = captureShopsPageErrors();

    await openShops(tester);

    expect(inShops(find.text('ابحث عن صيدلية...')), findsOneWidget);
    expect(inShops(find.text('جميع الصيدليات')), findsOneWidget);
    // المرجع: لا AppBar أخضر فوق الصفحة — الترويسة أول القائمة على الخلفية.
    expect(inShops(find.byType(AppBar)), findsNothing);
    expect(mine, isEmpty, reason: 'فيض تخطيط داخل صفحة المتاجر نفسها');
    // يستهلك فيض الشريط المشترك (خط الاختبار) فلا يفشل الاختبار على ما
    // ليس عيباً في صفحتنا.
    tester.takeException();

    NotificationCenter.instance.stop();
  });

  testWidgets('مربّع البحث الأخضر يوازي حقل البحث ولا يفيض', (
    WidgetTester tester,
  ) async {
    useReferencePhone(tester);
    final mine = captureShopsPageErrors();

    await openShops(tester);

    final field = inShops(find.byType(TextField));
    final button = inShops(find.byIcon(Icons.storefront_rounded));
    expect(field, findsOneWidget);
    expect(button, findsOneWidget);
    expect(
      tester.getRect(field).height,
      closeTo(tester.getRect(button).height, 1),
    );
    // المربّع في أقصى اليمين والحقل إلى يساره (ترتيب RTL).
    expect(
      tester.getRect(button).right,
      greaterThan(tester.getRect(field).right),
    );
    expect(mine, isEmpty, reason: 'شريط البحث فيّض داخل الصفحة');
    tester.takeException();

    NotificationCenter.instance.stop();
  });
}
