import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:saydaliti/screens/login_screen.dart';

/// ★ الحقول **إجبارية في الشاشة نفسها**، لا في الملف وحده.
///
///   `auth_fields_test.dart` يثبت الحجج. هذا يثبت الوصل: أن زر «تسجيل
///   الدخول» لا ينطلق برحلة شبكة قبل تعبئة الحقول، وأن الرسالة تظهر
///   تحت الحقل لا في مكان آخر. الاختبار بلا شبكة عمداً — فالمتوقّع أن
///   الطلب **لا يُرسل أصلاً**، ولو أُرسل لظهر المؤشر الدائر.
void main() {
  setUpAll(() {
    // الخطوط تُحمَّل من الشبكة، والشبكة هنا مقفلة — نُلغي الجلب الصافي
    // فلا يُهدَّر زمن ولا يظهر خطأ تحميل لا ناقة للحقل فيه.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LoginScreen())),
    );
    await tester.pump();
  }

  Future<void> tapSubmit(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pump();
  }

  testWidgets('الحقلان فارغان ⇒ رسالتان تحت الحقلين ولا دائرة تحميل', (
    tester,
  ) async {
    await open(tester);
    await tapSubmit(tester);

    expect(find.text('أدخل رقم الهاتف'), findsOneWidget);
    expect(find.text('أدخل كلمة المرور'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('رقم ناقص ⇒ حجة أحد عشر رقماً، والكلمة وحدها لا تكفي', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextFormField).first, '07857');
    await tester.enterText(find.byType(TextFormField).last, '123456');
    await tapSubmit(tester);

    expect(find.text('يجب أن يكون الرقم 11 رقماً بالضبط'), findsOneWidget);
    expect(find.text('أدخل كلمة المرور'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('مسافة في كلمة المرور لا تُحسب محتوى', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextFormField).first, '07857683066');
    await tester.enterText(find.byType(TextFormField).last, '   ');
    await tapSubmit(tester);

    expect(find.text('أدخل كلمة المرور'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
