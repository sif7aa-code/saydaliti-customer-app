import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/screens/admin_orders_screen.dart';

/// ★ حماية إصلاح «النافذة ما انغلقت» — نافذة كلمة ملخّص أكواد المندوبين.
///
///   العطل الذي بلّغ عنه الأدمن: يضغط «عرض» فتفتح نافذة كلمة اللوحة،
///   وحين تُغلق النافذة نفسها يبقى منها أثر وتحسبها اللوحة «مخربطة».
///   الجذر: محرّر النص كان يُتحرَّر لحظة `pop` بينما الأنيميشن العكسي ما
///   زال يرسم الحقل — استثناء في إطار الإغلاق، وزوال النافذة يتأخر.
///
///   النافذة الآن تملك محرّرها (`AdminCredentialDialog`)، فيتحرّر المحرّر
///   معها حين تُزال فعلاً. هذه الاختبارات تُغلقها كما يُغلقها الأدمن
///   بلمسة: إطار واحد داخل الأنيميشن، ثم بقية الأنيميشن، ثم النتيجة.
///
///   بلا شبكة ولا قاعدة ولا OTP: الهدف نافذة والكلمة التي تُعيدها.
void main() {
  const dialogTitle = 'ملخّص أكواد المندوبين';
  const actionLabel = 'عرض';

  /// يفتح النافذة كما يفتحها الزرّ في اللوحة، ويعيد ما خرج بها.
  Future<void> openDialog(
    WidgetTester tester, {
    required void Function(String?) onClosed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showDialog<String>(
                  context: ctx,
                  barrierDismissible: false,
                  builder: (_) => const AdminCredentialDialog(
                    title: dialogTitle,
                    actionLabel: actionLabel,
                  ),
                ).then(onClosed),
                child: const Text('افتح'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('افتح'));
    await tester.pumpAndSettle();
  }

  group('نافذة كلمة أكواد المندوبين', () {
    testWidgets('«عرض» يُغلقها: لا استثناء في إطار الإغلاق نفسه', (
      tester,
    ) async {
      String? got;
      await openDialog(tester, onClosed: (v) => got = v);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField), '  AB12  ');
      await tester.tap(find.text(actionLabel));

      // ★ الإطار الأول بعد Pop: الأنيميشن العكسي لسه شغّال والحقل في
      //   الشجرة. هنا كان المحرّر يتحرَّر فيُرمي الاستثناء.
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'هذا الاستثناء هو نفسه «النافذة ما انغلقت»',
      );

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'لا أثر للنافذة بعد الزوال',
      );
      expect(find.byType(TextField), findsNothing);
      expect(got, 'AB12', reason: 'الفراغ حول الكلمة يُحذف قبل إرسالها');
    });

    testWidgets('«إلغاء» يُغلقها بلا قيمة ولا استثناء', (tester) async {
      var called = false;
      String? got = 'لم تُستدعَ';
      await openDialog(
        tester,
        onClosed: (v) {
          called = true;
          got = v;
        },
      );

      await tester.tap(find.text('إلغاء'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(called, isTrue);
      expect(got, isNull, reason: 'الإلغاء لا يُخرج كلمة من جيب الأدمن');
    });

    testWidgets('زر «تم» في الكيبورد يُغلقها كما يُغلقه الزرّ', (tester) async {
      String? got;
      await openDialog(tester, onClosed: (v) => got = v);

      await tester.enterText(find.byType(TextField), 'K7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(got, 'K7');
    });

    testWidgets('الحقل يُخفي الكلمة ويأخذ التركيز وحده', (tester) async {
      await openDialog(tester, onClosed: (_) {});
      await tester.enterText(find.byType(TextField), 'AB12');

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.obscureText, isTrue);
      expect(field.autofocus, isTrue);

      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('حقل سبب الإلغاء/الرفض', () {
    testWidgets('يبلّغ بكتابته ويتحرّر مع زواله بلا استثناء', (tester) async {
      final typed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Directionality(
              textDirection: TextDirection.rtl,
              child: AdminReasonField(onChanged: typed.add),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'المتجر اغلق');
      expect(typed, contains('المتجر اغلق'));

      // إزالة الحقل من الشجرة: المحرّر ملكه فيُزال معه — لا محرّر خارجي
      // يُتحرَّر قبل الحقل.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
