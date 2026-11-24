import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:saydaliti/screens/register_screen.dart';

/// ★ إنشاء الحساب: كل حقل **إجباري**، والحجة تُعرض قبل أي شبكة.
///
///   شاشة التسجيل كانت تقبل اسماً فارغاً، وكلمةً من أربعة محارف (بينما
///   تشترط الاستعادة في القاعدة ستة)، ورقماً لا يبدأ بـ07، ولقباً عاماً
///   مثل «حساب» اسماً. الاختبار يثبت أن أياً من هذا لا يمرّ الآن، وأن
///   زر «إنشاء الحساب» لا يطلق رحلة شبكة والحقلُ ناقص — فلو انطلقت
///   لظهر المؤشر الدائر، والشبكة في الاختبارات مقفلة عمداً.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RegisterScreen())),
    );
    await tester.pump();
  }

  Future<void> tapCreate(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'إنشاء الحساب'));
    await tester.pump();
  }

  // الحقول بالترتيب داخل البطاقة: الاسم، ثم الرقم، ثم كلمة المرور.
  testWidgets('الكل فارغ ⇒ ثلاث رسائل ولا دائرة تحميل', (tester) async {
    await open(tester);
    await tapCreate(tester);

    expect(find.text('أدخل اسم الصيدلية أو اسمك'), findsOneWidget);
    expect(find.text('أدخل رقم الهاتف'), findsOneWidget);
    expect(find.text('أدخل كلمة المرور'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('لقب عام مرفوض اسمًا', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'حساب');
    await tester.enterText(find.byType(TextFormField).at(1), '07857683066');
    await tester.enterText(find.byType(TextFormField).at(2), '123456');
    await tapCreate(tester);

    expect(
      find.text('اكتب اسمه الحقيقي، لا لقباً مثل «حساب» أو «زبون»'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('كلمة من أربعة محارف لم تعد تكفي', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'مخبز أم علي');
    await tester.enterText(find.byType(TextFormField).at(1), '07857683066');
    await tester.enterText(find.byType(TextFormField).at(2), '1234');
    await tapCreate(tester);

    expect(find.text('كلمة المرور 6 محارف على الأقل'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('رقم لا يبدأ بـ07 مرفوض في التسجيل', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'مخبز أم علي');
    await tester.enterText(find.byType(TextFormField).at(1), '12345678901');
    await tester.enterText(find.byType(TextFormField).at(2), '123456');
    await tapCreate(tester);

    expect(find.text('رقم الهاتف يبدأ بـ07 مثل 07800000000'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
