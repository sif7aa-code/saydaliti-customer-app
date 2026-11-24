import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/order_elapsed.dart';
import 'package:saydaliti/widgets/order_elapsed_text.dart';

/// اختبار «وقت الطلب»: كم صارله وكم مضى — للمندوب وللزبون من مصدر واحد.
void main() {
  // لحظة مرجعية ثابتة حتى لا يتغيّر الناتج باختلاف وقت تشغيل الاختبار.
  final now = DateTime(2026, 10, 27, 15, 30);

  String iso(DateTime dt) => dt.toUtc().toIso8601String();

  Map<String, dynamic> order({DateTime? created, DateTime? delivered}) =>
      <String, dynamic>{
        if (created != null) 'created_at': iso(created),
        if (delivered != null) 'delivered_at': iso(delivered),
      };

  group('منذ كم أُرسِل الطلب', () {
    test('طلب حيّ: «منذ» محسوب من الآن', () {
      final o = order(created: now.subtract(const Duration(minutes: 25)));
      expect(OrderElapsed.label(o, now: now), 'منذ 25 دقيقة');
      expect(OrderElapsed.counterLabel(o), 'كم مضى عليه');
    });

    test('الدقائق: الواحد والاثنان والجمع الصحيح', () {
      expect(OrderElapsed.passedLabel(const Duration(seconds: 20)), 'لحظة');
      expect(OrderElapsed.passedLabel(const Duration(minutes: 1)), 'دقيقة واحدة');
      expect(OrderElapsed.passedLabel(const Duration(minutes: 2)), 'دقيقتين');
      expect(OrderElapsed.passedLabel(const Duration(minutes: 7)), '7 دقائق');
      expect(OrderElapsed.passedLabel(const Duration(minutes: 45)), '45 دقيقة');
    });

    test('الساعات والأيام: الجمع الصحيح أيضاً', () {
      expect(OrderElapsed.passedLabel(const Duration(hours: 1)), 'ساعة واحدة');
      expect(OrderElapsed.passedLabel(const Duration(hours: 2)), 'ساعتين');
      expect(OrderElapsed.passedLabel(const Duration(hours: 5)), '5 ساعات');
      expect(OrderElapsed.passedLabel(const Duration(hours: 13)), '13 ساعة');
      expect(OrderElapsed.passedLabel(const Duration(days: 1)), 'يوم واحد');
      expect(OrderElapsed.passedLabel(const Duration(days: 2)), 'يومين');
      expect(OrderElapsed.passedLabel(const Duration(days: 6)), '6 أيام');
      expect(OrderElapsed.passedLabel(const Duration(days: 40)), '40 يوماً');
    });

    test('العدّاد يتقدّم مع الساعة: لا يبقى على لحظة الفتح', () {
      final o = order(created: now.subtract(const Duration(minutes: 4)));
      expect(OrderElapsed.label(o, now: now), 'منذ 4 دقائق');
      expect(
        OrderElapsed.label(
          o,
          now: now.add(const Duration(minutes: 30)),
        ),
        'منذ 34 دقيقة',
      );
    });
  });

  group('كم مضى على الطلب المُسلَّم', () {
    test('يتوقف عند التسليم ويقول «استغرق»', () {
      final created = now.subtract(const Duration(hours: 2));
      final delivered = created.add(const Duration(minutes: 40));
      final o = order(created: created, delivered: delivered);
      expect(OrderElapsed.label(o, now: now.add(const Duration(days: 3))),
          'استغرق 40 دقيقة');
      expect(OrderElapsed.counterLabel(o), 'مدة الطلب');
    });

    test('بلا وقت تسليم يبقى «منذ» مهما طالت الحالة', () {
      final o = order(
        created: now.subtract(const Duration(days: 3)),
      );
      expect(OrderElapsed.label(o, now: now), 'منذ 3 أيام');
    });
  });

  group('البيانات الناقصة لا تُختَرع', () {
    test('بلا created_at ⇒ نص فارغ فلا يظهر سطر', () {
      expect(OrderElapsed.label(<String, dynamic>{}, now: now), '');
      expect(OrderElapsed.passed(<String, dynamic>{}, now: now), '');
      expect(OrderElapsed.placedAt(<String, dynamic>{'created_at': null}), isNull);
    });

    test('قيمة "null" النصية ليست وقتاً', () {
      final o = <String, dynamic>{'created_at': 'null', 'delivered_at': 'null'};
      expect(OrderElapsed.placedAt(o), isNull);
      expect(OrderElapsed.deliveredAt(o), isNull);
      expect(OrderElapsed.label(o, now: now), '');
    });

    test('تاريخ فاسد ⇒ بلا سطر، لا استثناء', () {
      final o = <String, dynamic>{'created_at': 'أمس تقريباً'};
      expect(OrderElapsed.placedAt(o), isNull);
      expect(OrderElapsed.clock(o['created_at']), '—');
    });

    test('تسليم قبل الإنشاء ⇒ صفر لا مدة سالبة', () {
      final o = order(
        created: now,
        delivered: now.subtract(const Duration(hours: 1)),
      );
      expect(OrderElapsed.span(o, now: now), Duration.zero);
      expect(OrderElapsed.label(o, now: now), 'استغرق لحظة');
    });
  });

  test('وقت الطلب يُقرأ بتوقيت الهاتف', () {
    final utc = DateTime.utc(2026, 10, 27, 18, 20);
    expect(OrderElapsed.placedAt(<String, dynamic>{'created_at': iso(utc)}),
        utc.toLocal());
    expect(OrderElapsed.placedAt(<String, dynamic>{'created_at': iso(utc)})!.isUtc,
        false);
  });

  group('ساعة الطلب بصيغة واحدة', () {
    test('صباحاً ومساءً ومقاس ١٢', () {
      expect(OrderElapsed.clock(iso(DateTime.utc(2026, 10, 27, 0, 5))), contains('صباحاً'));
      expect(OrderElapsed.clock(iso(DateTime.utc(2026, 10, 27, 12, 5))), contains('مساءً'));
      expect(OrderElapsed.clock(iso(DateTime.utc(2026, 10, 27, 15, 20))), endsWith('مساءً'));
    });

    test('الوقت الغائب شرطة لا "null"', () {
      expect(OrderElapsed.clock(null), '—');
      expect(OrderElapsed.clock(''), '—');
      expect(OrderElapsed.clock('null'), '—');
    });
  });

  group('المدة بالساعة والدقيقة معاً — شاشة تقارن طلبات بجانب بعضها', () {
    test('الدقائق وحدها ما لم تكتمل ساعة', () {
      expect(OrderElapsed.passedPrecise(const Duration(seconds: 20)), 'لحظة');
      expect(OrderElapsed.passedPrecise(const Duration(minutes: 1)), 'دقيقة واحدة');
      expect(OrderElapsed.passedPrecise(const Duration(minutes: 7)), '7 دقائق');
      expect(OrderElapsed.passedPrecise(const Duration(minutes: 59)), '59 دقيقة');
    });

    test('الساعة مع دقائقها، وبلا دقائق تُكتفى بالساعة', () {
      expect(
        OrderElapsed.passedPrecise(const Duration(hours: 2, minutes: 15)),
        'ساعتين و15 دقيقة',
      );
      expect(OrderElapsed.passedPrecise(const Duration(hours: 1)), 'ساعة واحدة');
      expect(
        OrderElapsed.passedPrecise(const Duration(hours: 1, minutes: 1)),
        'ساعة واحدة ودقيقة واحدة',
      );
      expect(
        OrderElapsed.passedPrecise(const Duration(hours: 5, minutes: 40)),
        '5 ساعات و40 دقيقة',
      );
      expect(
        OrderElapsed.passedPrecise(const Duration(hours: 13, minutes: 5)),
        '13 ساعة و5 دقائق',
      );
    });

    test('فوق اليوم: أيام مع ساعاتها، لا «25 ساعة» على طلب عمره يوم', () {
      expect(OrderElapsed.passedPrecise(const Duration(hours: 24)), 'يوم واحد');
      expect(
        OrderElapsed.passedPrecise(const Duration(hours: 26)),
        'يوم واحد وساعتين',
      );
      expect(OrderElapsed.passedPrecise(const Duration(days: 3)), '3 أيام');
    });

    test('البادئة نفسها: «منذ» للحيّ و«استغرق» للمُسلَّم', () {
      final created = now.subtract(const Duration(hours: 3, minutes: 20));
      expect(
        OrderElapsed.labelPrecise(order(created: created), now: now),
        'منذ 3 ساعات و20 دقيقة',
      );
      expect(
        OrderElapsed.labelPrecise(
          order(created: created, delivered: now),
          now: now,
        ),
        'استغرق 3 ساعات و20 دقيقة',
      );
    });

    test('بلا وقت إنشاء ⇒ فارغ، فلا سطر مُختلَق', () {
      expect(OrderElapsed.labelPrecise(<String, dynamic>{}, now: now), '');
    });

    test('الاختصار القديم باقٍ كما كان للمندوب والزبون', () {
      expect(
        OrderElapsed.passedLabel(const Duration(hours: 2, minutes: 15)),
        'ساعتين',
      );
      expect(OrderElapsed.labelPrecise(
        order(created: now.subtract(const Duration(hours: 2, minutes: 15))),
        now: now,
      ), 'منذ ساعتين و15 دقيقة');
    });
  });

  group('سطر الوقت الحيّ في البطاقة', () {
    // بطاقة ضيقة عمداً: النص غير المرن كان يعطي شريط تجاوز العرض.
    Future<void> pumpCard(
      WidgetTester tester,
      Map<String, dynamic> o, {
      bool precise = false,
      bool withClock = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 190,
                  child: Row(
                    children: [
                      // مرن كما في البطاقة الحقيقية: النص غير المرن في
                      // صفٍّ ضيق يتجاوز حدّ البطاقة.
                      Flexible(
                        child: OrderElapsedText(
                          order: o,
                          precise: precise,
                          withClock: withClock,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('عرض «منذ…» بلا تجاوز على عرض البطاقة', (tester) async {
      await pumpCard(tester, <String, dynamic>{
        'created_at': DateTime.now()
            .subtract(const Duration(minutes: 25))
            .toUtc()
            .toIso8601String(),
      });
      expect(find.textContaining('منذ'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // يُطفأ المؤقّت المشترك عند الخروج من الشاشة.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('المُسلَّم يعرض «استغرق» ويتوقف', (tester) async {
      final created = DateTime.now().subtract(const Duration(hours: 2));
      await pumpCard(tester, <String, dynamic>{
        'created_at': created.toUtc().toIso8601String(),
        'delivered_at': created
            .add(const Duration(minutes: 35))
            .toUtc()
            .toIso8601String(),
      });
      expect(find.textContaining('استغرق'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(find.textContaining('استغرق'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('بلا وقت إنشاء ⇒ لا سطر ولا شرطة حائرة', (tester) async {
      await pumpCard(tester, <String, dynamic>{});
      expect(find.text('—'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('مع ساعة الإرسال: «طلب … · منذ …» في بطاقة ضيقة', (tester) async {
      final created = DateTime.now().subtract(const Duration(hours: 2));
      final o = <String, dynamic>{'created_at': created.toUtc().toIso8601String()};
      await pumpCard(tester, o, precise: true, withClock: true);
      final line = tester.widget<Text>(find.byType(Text).last).data ?? '';
      expect(line, startsWith('طلب ${OrderElapsed.clock(o['created_at'])} · '));
      expect(line, contains('منذ'));
      // المدة تُقاس بساعة الويجت المشتركة، فلا يُثبت نصّها هنا — المطلوب
      // أن السطر كله يسع عرض البطاقة بلا شريط تجاوز.
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}
