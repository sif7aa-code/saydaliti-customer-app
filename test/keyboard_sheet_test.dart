import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/core/utils/keyboard_sheet.dart';

/// ★ القاعدة المُراد حمايتها: الشيت السفلي الذي فيه حقل «كود الخصم» لا
/// يتجاوز ما يبقى من الشاشة بعد الكيبورد — حتى لا يغطي الكيبورد الحقل
/// وزر «تطبيق».
void main() {
  double sheetTotal(Size screen, double keyboard) =>
      KeyboardSheet.maxHeight(screenSize: screen, keyboardInset: keyboard) +
      KeyboardSheet.bottomInset(keyboard) +
      KeyboardSheet.chromeHeight;

  group('KeyboardSheet.maxHeight', () {
    test('بلا كيبورد: سقف ثابت ولا يملأ الشاشة الطويلة', () {
      expect(
        KeyboardSheet.maxHeight(
          screenSize: const Size(400, 1200),
          keyboardInset: 0,
        ),
        KeyboardSheet.maxContentHeight,
      );
    });

    test('هاتف 800 مع كيبورد 350 => المحتوى 386 والكلي = الشاشة', () {
      const screen = Size(393, 800);
      expect(
        KeyboardSheet.maxHeight(screenSize: screen, keyboardInset: 350),
        800 - 350 - KeyboardSheet.chromeHeight,
      );
      expect(sheetTotal(screen, 350), lessThanOrEqualTo(800 + 0.001));
      expect(
        KeyboardSheet.fitsScreen(screenSize: screen, keyboardInset: 350),
        isTrue,
      );
    });

    test('كيبورد ضخم: لا يهبط المحتوى تحت الحد الأدنى', () {
      const screen = Size(393, 800);
      expect(
        KeyboardSheet.maxHeight(screenSize: screen, keyboardInset: 760),
        KeyboardSheet.minContentHeight,
      );
      // الكيبورد ابتلع المتاح: `fitsScreen` تقول صراحةً إننا على الحد.
      expect(
        KeyboardSheet.fitsScreen(screenSize: screen, keyboardInset: 760),
        isFalse,
      );
    });

    test('شاشة صغيرة (560) مع كيبورد 300 => يبقى شيت قابل للتمرير', () {
      const screen = Size(360, 560);
      final h = KeyboardSheet.maxHeight(screenSize: screen, keyboardInset: 300);
      expect(h, greaterThanOrEqualTo(KeyboardSheet.minContentHeight));
      expect(
        KeyboardSheet.fitsScreen(screenSize: screen, keyboardInset: 300),
        isFalse, // 560 - 300 - 64 = 196 < 240 ⇒ القاعدين يعمل
      );
    });

    test('كيبورد سالب (متصفح منضدة) يُحسب صفراً', () {
      const screen = Size(1200, 900);
      expect(KeyboardSheet.bottomInset(-120), 0);
      expect(
        KeyboardSheet.maxHeight(screenSize: screen, keyboardInset: -120),
        KeyboardSheet.maxContentHeight,
      );
    });

    test('كل كيبورد أكبر يُنتج محتوى أصغر (رتيب) ولا يتجاوز الشاشة', () {
      const screen = Size(393, 850);
      double? previous;
      for (final kb in <double>[0, 120, 240, 300, 360, 420, 480]) {
        final h = KeyboardSheet.maxHeight(
          screenSize: screen,
          keyboardInset: kb,
        );
        if (previous != null) expect(h, lessThanOrEqualTo(previous));
        previous = h;
        if (KeyboardSheet.fitsScreen(screenSize: screen, keyboardInset: kb)) {
          expect(sheetTotal(screen, kb), lessThanOrEqualTo(850 + 0.001));
        }
      }
    });
  });

  group('القياس على أحجام الهواتف الفعلية', () {
    // هواوي الاختبار وأجهزة الزبائن الشائعة: العرض/الارتفاع بالبكسل المنطقي.
    const phones = <String, Size>{
      'huawei_test': Size(364, 780),
      'common_1080p': Size(393, 851),
      'small_720p': Size(360, 640),
    };
    for (final entry in phones.entries) {
      for (final keyboard in <double>[280, 340, 400]) {
        test('${entry.key} مع كيبورد $keyboard', () {
          final screen = entry.value;
          final h = KeyboardSheet.maxHeight(
            screenSize: screen,
            keyboardInset: keyboard,
          );
          // أعلى نقطة يغطيها الكيبورد.
          final keyboardTop = screen.height - keyboard;
          // الشيت أسفله مباشرةً: حشوته السفلية = الكيبورد، فالمتبقي
          // للمحتوى = screen − keyboard − chrome.
          expect(h, lessThanOrEqualTo(keyboardTop));
          expect(h, greaterThanOrEqualTo(KeyboardSheet.minContentHeight));
        });
      }
    }
  });

  group('شيت حقيقي (showModalBottomSheet) مع كيبورد', () {
    Future<void> openSheet(
      WidgetTester tester, {
      required bool keyboardAware,
    }) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      late BuildContext rootCtx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                rootCtx = c;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      showModalBottomSheet<void>(
        context: rootCtx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          final kb = keyboardAware
              ? KeyboardSheet.bottomInset(MediaQuery.of(ctx).viewInsets.bottom)
              : 0.0;
          final content = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TextField(
                decoration: InputDecoration(labelText: 'كود الخصم'),
              ),
              // محتوى طويل مثل سلة حقيقية: العنوان + الملاحظة + الكود +
              // الدفع + زر الإرسال.
              const SizedBox(height: 700),
            ],
          );
          if (!keyboardAware) {
            // ★ الشكل القديم: حشوة ثابتة وبلا سقف ⇒ الشيت يظل ملتصقاً
            //   بأسفل الشاشة والكيبورد يغطي ما تحته.
            return Container(
              padding: const EdgeInsets.all(20),
              child: SafeArea(child: SingleChildScrollView(child: content)),
            );
          }
          // ★ الشكل الجديد: نفس الشيت بقياسات `KeyboardSheet`.
          return Container(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + kb),
            child: SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: KeyboardSheet.maxHeight(
                    screenSize: MediaQuery.sizeOf(ctx),
                    keyboardInset: kb,
                  ),
                ),
                child: SingleChildScrollView(child: content),
              ),
            ),
          );
        },
      );
      await tester.pumpAndSettle();
    }

    testWidgets('بلا قياسات الكيبورد: منطقة التمرير تنزل خلف الكيبورد', (
      tester,
    ) async {
      await openSheet(tester, keyboardAware: false);
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await tester.pumpAndSettle();

      final scrollBottom = tester
          .getRect(find.byType(SingleChildScrollView))
          .bottom;
      final keyboardTop = 851 - 400;
      // الأدلّة: الشيت لم يتحرك، فأسفله ما زال عند قاع الشاشة (= تحت
      // الكيبورد) — وهذا بالضبط ما كان يغطّي حقل الكود.
      expect(scrollBottom, greaterThan(keyboardTop + 100));
    });

    testWidgets('مع قياسات الكيبورد: منطقة التمرير كلها فوقه', (tester) async {
      await openSheet(tester, keyboardAware: true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(SingleChildScrollView));
      final keyboardTop = 851 - 400;
      expect(rect.bottom, lessThanOrEqualTo(keyboardTop + 0.5));
      expect(rect.top, greaterThanOrEqualTo(0));
      // والحقن نفسها (التي يظنّها المستخدم «الحقل اختفى») ما زالت داخل
      // المساحة الظاهرة أو قابلة للتمرير إليها.
      expect(rect.height, lessThanOrEqualTo(keyboardTop));
    });

    testWidgets('الكيبورد يختفي فيعود الشيت لحجمه (لا قفص دائم)', (
      tester,
    ) async {
      await openSheet(tester, keyboardAware: true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      await tester.pumpAndSettle();
      final withKeyboard = tester.getRect(find.byType(SingleChildScrollView));

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      final withoutKeyboard = tester.getRect(
        find.byType(SingleChildScrollView),
      );

      expect(withoutKeyboard.height, greaterThan(withKeyboard.height));
      expect(withoutKeyboard.height, KeyboardSheet.maxContentHeight);
    });
  });
}
