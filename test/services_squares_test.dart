import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/screens/services_screen.dart';

/// ★ صفحة الخدمات بأيقونات **مربّعة** جنب بعض (أمر الأدمن 11-04)، ومعها
///   مربّع «اغسل سيارتك» (11-09) زرّ فقط يقول «قريباً».
///
///   المحكّوم هنا هو الشكل لا الشاشة المُفتَحة: البوابتان وبقاؤهما كما
///   كانتا يغطّيهما اختبار الشريط السفلي. ما يُختبر:
///     * ثلاثة مربّعات متساوية، طول كل منها = عرضها.
///     * الاسم والزرّ داخل المربّع لا خارجَه.
///     * لا فيض على أضيق هاتف ولا مع خط أكبر — لأن الاسم صار داخل
///       مربّع لا داخل بطاقة عريضة، والتجاوز كان هو الخطر الوحيد.
///     * مربّع الغسيل لا يدفع شاشةً ولا يرسل شيئاً: رسالة «قريباً» فقط.
///
///   مقاسات الحرف في اختبارات الوحدة هي Ahem العريض لا Cairo، فلا
///   يُعتمد على ارتفاع السطور هنا؛ يُعتمد على الاحتواء وعلى غياب الاستثناء.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = Size(width, width * 1.9);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const MaterialApp(home: ServicesScreen()));
    await tester.pump();
  }

  testWidgets('ثلاثة مربّعات متساوية، كل منها بطول عرضها', (tester) async {
    await pump(tester, width: 360);

    final squares = find.byType(AspectRatio);
    expect(squares, findsNWidgets(3));
    final first = tester.getRect(squares.at(0)).width;
    for (var i = 1; i < 3; i++) {
      expect(tester.getRect(squares.at(i)).width, closeTo(first, 1));
    }

    for (final entry in [
      ('طلب مندوب', 'اضغط هنا'),
      ('حجز طبيب', 'احجز موعد'),
      ('اغسل سيارتك', 'قريباً'),
    ].indexed) {
      final square = tester.getRect(squares.at(entry.$1));
      final name = tester.getRect(find.text(entry.$2.$1));
      final label = tester.getRect(find.text(entry.$2.$2));
      expect(square.width, closeTo(square.height, 1));
      expect(name.left, greaterThanOrEqualTo(square.left));
      expect(name.right, lessThanOrEqualTo(square.right));
      expect(label.top, greaterThan(name.bottom));
      expect(label.bottom, lessThanOrEqualTo(square.bottom));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('على أضيق هاتف (320) لا فيض ولا تجاوز', (tester) async {
    await pump(tester, width: 320);
    expect(find.byType(AspectRatio), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('مع خط أكبر (+30%) تبقى المربّعات بلا تجاوز', (tester) async {
    await pump(tester, width: 320, textScale: 1.3);
    expect(find.byType(AspectRatio), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('«اغسل سيارتك» زرّ فقط: رسالة قريباً بلا شاشة ولا إرسال', (
    tester,
  ) async {
    await pump(tester, width: 360);

    expect(find.text('اغسل سيارتك'), findsOneWidget);
    expect(find.text('قريباً'), findsOneWidget);

    await tester.tap(find.text('اغسل سيارتك'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('قريباً — خدمة غسيل السيارات.'), findsOneWidget);
    // لا دفع لمسار جديد: خدمات ما زالت قمة الملاح.
    expect(
      Navigator.of(tester.element(find.byType(ServicesScreen))).canPop(),
      isFalse,
    );

    // الرسالة تختفي وحدها بعد ثانيتين: pumpAndSettle لا يُقدّم مؤقّتاً
    //   لا يرسم إطارات، فلا بد من ضخّ المدة نفسها ثم تسوية الحركة.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('قريباً — خدمة غسيل السيارات.'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
