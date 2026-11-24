import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/screens/admin_dashboard_screen.dart';
import 'package:saydaliti/screens/admin_orders_screen.dart';

/// الشاشة الحقيقية بلا شبكة: بيئة الاختبار تردّ على الطلبات بـ400،
/// والمطلوب هنا ثبات الأدوات والتنقل والتخطيط لا أرقام القاعدة.
void main() {
  Future<void> pumpDashboard(
    WidgetTester tester, {
    double width = 360,
    double height = 900,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AdminDashboardScreen(),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> reveal(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('رأس اللوحة وأدواته العشر باقية كما كانت', (tester) async {
    await pumpDashboard(tester);

    expect(find.text('لوحة تحكم الأدمن'), findsOneWidget);

    // بالترتيب الذي ترسمه اللوحة: التمرير يتقدّم ولا يرجع.
    for (final label in [
      'إرسال شعار للجميع',
      'أكواد الخصم',
      'إدارة الأقسام',
      'إدارة الصيدليات',
      'الأجهزة والإشعارات',
      'إدارة المستخدمين',
      'أصحاب الصيدليات',
      'محفظة المندوبين',
      'إدارة البانرات',
      'مراقبة الطلبات',
    ]) {
      await reveal(tester, label);
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('على عرض 320 لا فيض في الرأس أو البطاقات', (tester) async {
    await pumpDashboard(tester, width: 320, height: 780);

    expect(find.text('لوحة تحكم الأدمن'), findsOneWidget);
    await reveal(tester, 'إدارة الصيدليات');
    expect(tester.takeException(), isNull);
    await reveal(tester, 'مراقبة الطلبات');
    expect(tester.takeException(), isNull);
  });

  testWidgets('«مراقبة الطلبات» تفتح شاشتها الأصلية', (tester) async {
    await pumpDashboard(tester);

    await reveal(tester, 'مراقبة الطلبات');
    await tester.tap(find.text('مراقبة الطلبات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(AdminOrdersScreen), findsOneWidget);
  });

  testWidgets('لا عناوين الأقسام التي أضيفت في إعادة التصميم', (tester) async {
    await pumpDashboard(tester);

    // التصميم المرجوع إليه بطاقة تلو الأخرى بلا ترويسة قسم.
    for (final header in [
      'المتابعة والإحصاءات',
      'الطلبات والمحتوى',
      'الحسابات والمحافظ',
      'التواصل والإشعارات',
    ]) {
      expect(find.text(header), findsNothing, reason: header);
    }
  });
}
