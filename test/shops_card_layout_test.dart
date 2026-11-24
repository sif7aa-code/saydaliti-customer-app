import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:saydaliti/app.dart';
import 'package:saydaliti/screens/shops_screen.dart';
import 'package:saydaliti/services/notification_center.dart';
import 'package:saydaliti/widgets/bottom_nav_bar.dart';

/// ★ بطاقات صفحة المتاجر بشكلها الجديد (مرجع 2026-10-30)
///
///   البطاقات لا تُرسم بلا بيانات، والشبكة في الاختبارات تردّ 400. لكن
///   `catalog_shops` هي نسخة القرص التي يقرأها `_Dataset` **قبل** أي نداء
///   شبكة («نسخة القرص قد تكون من أي عمر»)، فبذرُها يجعل البطاقات تُبنى
///   فعلاً ويُقاس ترتيبها: اللوحة الخضراء في أقصى اليسار، الشعار بجانبها،
///   والاسم وأوقات العمل يميناً — كالصورة المرجعية.
///
///   الحالة والوقت يُقاسان من الساعة الآن، فلا تُثبت هنا نتيجة متجرٍ جدوله
///   يفتح ويغلق في وقت قد يكون الاختبار داخله أو خارجه. المتاجر المبذورة
///   ثلاثة: دائم الفتح («٢٤ ساعة»)، وموقوف يدوياً (القرار للمفتاح لا للوقت)،
///   وجدول لا يُفهم (لا تقييد زمنياً). وأما ذو النافذة المعتادة فيُثبت عليه
///   أمر واحد لا يتغيّر: المعروض وقتٌ منسّق («07:00 ص») لا نص القاعدة الخام
///   («07:00 - 22:00»).
///
///   ★ هذا الاختبار في ملفٍ مستقل عمداً: `RealDataService` مفردة، ونتيجة
///   الجلب الفاشل تبقى في ذاكرتها ٦٠ ثانية، فلو سبقه اختبار صفحة آخر
///   لأعاد الكل قائمة فارغة من الذاكرة قبل أن يلمس القرص.
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// يستقبل من صفحة المتاجر وحدها (الرئيسية تبقى حيّة داخل `IndexedStack`).
  ///
  /// ★ `all` ليست للاختبار بل لإثبات أن الخطاف حيّ: إن تعطّل الاستقبال
  ///   صارت `mine` فارغة دائماً والاختبار أعمى.
  ({List<String> mine, List<String> all}) captureRenderErrors() {
    final mine = <String>[];
    final all = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      all.add(text);
      if (text.contains('file:///M:/strasopa/lib/screens/shops_screen.dart') ||
          text.contains('package:saydaliti/screens/shops_screen.dart')) {
        mine.add(text);
      }
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    return (mine: mine, all: all);
  }

  Finder inShops(Finder matching) =>
      find.descendant(of: find.byType(ShopsScreen), matching: matching);

  testWidgets('البطاقة: لوحة الحالة يسار والاسم يمين ولا فيض داخلها', (
    WidgetTester tester,
  ) async {
    // 360 هو أساس قياس المرجع نفسه: 576 بكسل ÷ 1.6.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      'catalog_shops': jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'rows': [
          {
            // دائم الفتح بقرار الأدمن: الحالة لا تتغيّر بساعة الاختبار.
            'id': 's-1',
            'name': 'مخبز الشطرة',
            'is_open': true,
            'working_hours': '٢٤ ساعة',
            'working_days': 'يومياً',
          },
          {
            'id': 's-2',
            'name': 'بقالة أم علي',
            'is_open': false,
            'working_hours': '09:00 - 21:00',
            'working_days': 'السبت - الخميس',
          },
          {
            // أقسى حالة واقعية: اسم طويل مع سطر أوقات طويل لا يُفهم.
            'id': 's-3',
            'name': 'مطاعم ومأكولات الشطرة المركزية للأغذية والسندويجات',
            'is_open': true,
            'working_hours': 'من الساعة ٠٧:٠٠ صباحاً حتى ٢٣:٣٠ مساءً',
            'working_days': 'كل أيام الأسبوع بلا استثناء',
          },
          {
            // نافذة عادية: داخلها أم خارجها يعتمد على ساعة الاختبار، لذلك
            // لا يُثبت شكل الحالة بل شكل الوقت (منسّق لا خام).
            'id': 's-4',
            'name': 'حلوى النخيل',
            'is_open': true,
            'working_hours': '07:00 - 22:00',
            'working_days': 'يومياً',
          },
        ],
      }),
    });

    final errors = captureRenderErrors();

    await tester.pumpWidget(const StrasopaApp());
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavBar),
        matching: find.text('المتاجر'),
      ),
    );
    await settle(tester);

    final open = inShops(find.text('مفتوح الآن'));
    expect(open, findsAtLeastNWidgets(2));
    expect(inShops(find.text('مغلق')), findsWidgets);
    expect(inShops(find.text('مخبز الشطرة')), findsOneWidget);
    expect(inShops(find.textContaining('أم علي')), findsOneWidget);

    // ★ الوقت المعروض محسوب من الجدول: «طوال اليوم» للدائم، و«07:00 ص»
    //   منسّقة لصاحب النافذة، ولا مكان لنص القاعدة الخام في أي بطاقة.
    expect(inShops(find.text('مفتوح طوال اليوم')), findsOneWidget);
    expect(inShops(find.textContaining('07:00 ص')), findsWidgets);
    expect(inShops(find.textContaining('07:00 - 22:00')), findsNothing);
    // الموقوف يدوياً يقول ذلك صراحة، لا «مغلق» وحدها.
    expect(inShops(find.text('مغلق • موقوف يدوياً')), findsOneWidget);

    // ★ الاسم الكامل يظهر: سطران بدل سطر كان يقصّ الأسماء الطويلة.
    final longName = inShops(
      find.text('مطاعم ومأكولات الشطرة المركزية للأغذية والسندويجات'),
    );
    expect(longName, findsOneWidget);
    expect(tester.widget<Text>(longName).maxLines, 2);

    // اللوحة الخضراء في أقصى اليسار (حاشية الصفحة 18 + حشو البطاقة)،
    // والاسم يقع إلى يمينها بالكامل.
    final panel = tester.getRect(open.first);
    final name = tester.getRect(find.text('مخبز الشطرة'));
    expect(
      panel.left,
      lessThan(130.0),
      reason: 'لوحة الحالة لم تسكن أقصى يسار البطاقة',
    );
    expect(name.left, greaterThan(panel.right));

    // ★ الدليل أن الرصد حيّ: فيض الشريط السفلي المشترك يُستهلك هنا
    //   صراحةً، فلو كان المستقبِل معطلاً لبدت `mine` فارغة دائماً.
    expect(errors.mine, isEmpty, reason: 'البطاقات فيّضت داخل صفحة المتاجر');
    tester.takeException();

    NotificationCenter.instance.stop();
  });
}
