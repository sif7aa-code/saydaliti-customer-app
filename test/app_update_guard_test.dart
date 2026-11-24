import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saydaliti/services/update_guard.dart';

/// ★ فحص التحديث يُقرأ من `app_settings`، والشبكة في الاختبارات تردّ 400 ⇒
///   المسار المُختبَر هو **نسخة القرص** (`update_cfg_cache_v1`) — وهي نفسها
///   التي تُصلح الفحص عند انقطاع الإنترنت على الهاتف.
Future<void> seedServerCopy(String latest, {String message = ''}) async {
  SharedPreferences.setMockInitialValues({
    'update_cfg_cache_v1': jsonEncode({
      'update_latest_version': latest,
      'update_enabled': true,
      'update_message': message,
    }),
  });
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// يفتح التطبيق ويعرض النافذة ثم يسلّم سياق الـ Scaffold.
  Future<void> launch(WidgetTester tester, String installed) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('الرئيسية'))),
    );
    UpdateGuard.instance.start(
      tester.element(find.byType(Scaffold)),
      installed: installed,
    );
    await settle(tester);
  }

  group('مقارنة الإصدارات', () {
    test('الفجوة تُحسب بعدد الإصدارات لا بكبر الرقم', () {
      expect(UpdateGuard.versionsBehind('1.7.62', '1.7.62'), 0);
      expect(UpdateGuard.versionsBehind('1.7.63', '1.7.62'), 0);
      expect(UpdateGuard.versionsBehind('1.7.62', '1.7.63'), 1);
      expect(UpdateGuard.versionsBehind('1.7.62', '1.7.64'), 2);
      expect(UpdateGuard.versionsBehind('1.7.62', '1.7.70'), 8);
      // قفزة سلسلة (1.7 ⇒ 1.8) تعني جهازاً أبعد من إصدارين.
      expect(UpdateGuard.versionsBehind('1.7.62', '1.8.3'), 2);
      expect(UpdateGuard.versionsBehind('', '1.7.63'), 0);
      expect(UpdateGuard.versionsBehind('1.7.63', ''), 0);
    });

    test('القرار: إصدار خلف = اختيارية، إصداران = إجبارية', () {
      expect(
        UpdateGuard.decide(installed: '1.7.62', latest: ''),
        UpdateNeed.none,
      );
      expect(
        UpdateGuard.decide(installed: '1.7.62', latest: '1.7.63'),
        UpdateNeed.optional,
      );
      expect(
        UpdateGuard.decide(installed: '1.7.62', latest: '1.7.65'),
        UpdateNeed.mandatory,
      );
      expect(
        UpdateGuard.decide(installed: '1.7.65', latest: '1.7.65'),
        UpdateNeed.none,
      );
      expect(
        UpdateGuard.decide(
          installed: '1.7.62',
          latest: '1.7.65',
          enabled: false,
        ),
        UpdateNeed.none,
      );
    });
  });

  testWidgets('إصدار واحد خلف: رسالة اختيارية بزر «لاحقاً»', (
    WidgetTester tester,
  ) async {
    await seedServerCopy('1.7.63');
    await launch(tester, '1.7.62');

    expect(find.text('يوجد إصدار جديد'), findsOneWidget);
    expect(find.text('لاحقاً'), findsOneWidget);
    expect(find.text('تحديث الآن'), findsOneWidget);
    expect(find.textContaining('الإصدار الجديد: 1.7.63'), findsOneWidget);

    await tester.tap(find.text('لاحقاً'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('إصداران خلف: الرسالة إجبارية بلا خيار «لاحقاً»', (
    WidgetTester tester,
  ) async {
    await seedServerCopy('1.7.65');
    await launch(tester, '1.7.62');

    expect(find.text('التحديث مطلوب للمتابعة'), findsOneWidget);
    expect(find.text('لاحقاً'), findsNothing);
    expect(find.text('تحديث الآن'), findsOneWidget);

    // النقر خارجها لا يغلقها (الحارس في `PopScope` + barrierDismissible).
    await tester.tapAt(const Offset(4, 4));
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);

    // تفريغ النافذة يدوياً حتى لا تنتقل حالة «نافذة مفتوحة» للاختبار التالي.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
  });

  testWidgets('نص الرسالة المخصص من اللوحة يُعرض كما هو', (
    WidgetTester tester,
  ) async {
    await seedServerCopy(
      '1.7.64',
      message: 'أسعار جديدة في المتاجر، حدِّث التطبيق',
    );
    await launch(tester, '1.7.63');

    expect(
      find.textContaining('أسعار جديدة في المتاجر، حدِّث التطبيق'),
      findsOneWidget,
    );
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
  });

  testWidgets('المحدَّث لا يرى أي رسالة', (WidgetTester tester) async {
    await seedServerCopy('1.7.62');
    await launch(tester, '1.7.62');

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('تحديث الآن'), findsNothing);
  });

  test('رابط التحديث هو صفحة سنتر الشطرة على Google Play', () {
    expect(
      UpdateGuard.playWebUrl,
      'https://play.google.com/store/apps/details?id=com.shatra.shtrapp',
    );
  });
}
