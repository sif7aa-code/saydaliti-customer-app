import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/app.dart';
import 'package:saydaliti/services/notification_center.dart';
import 'package:saydaliti/widgets/bottom_nav_bar.dart';
import 'package:saydaliti/widgets/location_header.dart';

/// ★ الإقلاع بلا شبكة: ما الذي يُضمَن؟
///
///   هذا الاختبار لا يستطيع أن يطلب «شاهدتها مؤخراً» و«مطاعم» لأنه
///   في عالم الاختبارات كل نداء شبكة يردّ **400** (المحمية مقفولة
///   عمداً)، فلا بيانات تُرسم ولا شريط أقسام يظهر. فكان التقرير أحمر
///   على شيء ليس عيباً، والقيمة الوحيدة فيه ضائعة.
///
///   المطلوب هنا هو الحدّ الذي لا يتغيّر مهما سقطت الشبكة: أن التطبيق
///   يُبني، وأن غير المسجَّل يرى واجهة الزائر بشريطه السفلي، وأن
///   السلة لا تُترك بلا هوية.
void main() {
  /// ★ لماذا نبضات محددة لا `pumpAndSettle`؟
  ///   الرئيسية فيها مؤقّت دائم (بانرات تتبدّل كل سبع ثوانٍ) ولا
  ///   حمولة تنتهي في الاختبار ⇒ `pumpAndSettle` «timed out» أبداً.
  ///   النبضات المحدّدة تبني الإطارات اللازمة فقط.
  Future<void> _settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  void setUpView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('التطبيق يُبني عناصره الرئيسية للزائر بلا شبكة',
      (WidgetTester tester) async {
    setUpView(tester);

    await tester.pumpWidget(const StrasopaApp());
    await _settle(tester);

    // رأس الرئيسية كما يُعرض لغير المسجَّل.
    expect(find.text('أهلاً بك يا زائر'), findsOneWidget);
    expect(find.textContaining('ابحث عن مطعم'), findsWidgets);

    // شريط التنقل السفلي بأسمائه الحقيقية الخمسة.
    expect(find.text('الرئيسية'), findsWidgets);
    expect(find.text('المتاجر'), findsWidgets);
    expect(find.text('شورتس'), findsWidgets);
    expect(find.text('خدمات'), findsWidgets);
    expect(find.text('حسابي'), findsWidgets);

    // ★ السلة لم تعد زرّاً في الشريط: انتقلت إلى دائرة بجانب الجرس
    //   أعلى الرئيسية، فأي «السلة» داخل الشريط تعني شريطاً قديماً.
    expect(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text('السلة'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(LocationHeader),
        matching: find.byIcon(Icons.shopping_cart_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(LocationHeader),
        matching: find.byIcon(Icons.notifications_none_rounded),
      ),
      findsOneWidget,
    );

    // «خدمات» لا تُفتح للزائر: تُحوَّل إلى بوابة تسجيل الدخول.
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text('خدمات'),
      ),
    );
    await _settle(tester);
    expect(find.text('تسجيل الدخول'), findsWidgets);

    // ★ مركز الإشعارات نبضة دورية (كل ثانية) أطلقها `initState`
    //   للتطبيق. الإيقاف **داخل الجسم** لا في `addTearDown`: إطار
    //   flutter_test يفحص المؤقّتات المعلّقة بعد الجسم مباشرة وقبل
    //   الترتيبات، فمتأخّرتها تعني «Pending timers» وتقريراً أحمر على
    //   ما ليس عيباً.
    NotificationCenter.instance.stop();
  });

  /// دائرة السلة في الرأس: تفتح السلة صفحةً بزر رجوع، والزائر يمرّ
  /// ببوابة الدخول كما كان يفعل التبويب القديم.
  testWidgets('دائرة السلة أعلى الرئيسية تفتح بوابة الدخول للزائر',
      (WidgetTester tester) async {
    setUpView(tester);

    await tester.pumpWidget(const StrasopaApp());
    await _settle(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(LocationHeader),
        matching: find.byIcon(Icons.shopping_cart_outlined),
      ),
    );
    await _settle(tester);

    expect(find.text('تسجيل الدخول'), findsWidgets);
    // الشاشة خلف البوابة ليست السلة نفسها.
    expect(find.text('السلة'), findsNothing);

    NotificationCenter.instance.stop();
  });
}

