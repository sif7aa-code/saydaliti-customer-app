import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/widgets/duplicate_orders_panel.dart';
import 'package:saydaliti/core/theme/app_colors.dart';
import 'package:saydaliti/core/utils/order_duplicates.dart';

/// ★ اختبارات واجهة للوحة التحذير وحدها: بيانات مصنوعة في الذاكرة، بلا
///   شبكة ولا قاعدة ولا OTP — فالهدف الشكل والضغط لا الخدمة.
DuplicateReceipt _receipt({
  required String id,
  String serial = '#5',
  String driverPhone = '07831111111',
  String? driverName,
  String status = 'accepted',
  DateTime? at,
  bool stamped = true,
}) => DuplicateReceipt(
  orderId: id,
  serial: serial,
  driverPhone: driverPhone,
  driverName: driverName ?? driverPhone,
  receivedAt: at ?? DateTime.utc(2026, 10, 27, 10, 5),
  hasReceiptStamp: stamped,
  status: status,
);

DuplicateGroup _group({
  String phone = '07830000001',
  String name = 'زبون',
  double basket = 12000,
  required List<DuplicateReceipt> receipts,
}) => DuplicateGroup(
  customerPhone: phone,
  customerName: name,
  basketAmount: basket,
  receipts: List<DuplicateReceipt>.unmodifiable(receipts),
);

Future<void> _pump(WidgetTester tester, DuplicateOrdersPanel panel) async {
  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: SingleChildScrollView(child: panel)),
      ),
    ),
  );
  await tester.pump();
}

const _header = 'تنبيه: طلب مكرر عند أكثر من مندوب';

/// النص مهما كان شكله: `Text(data:)` أو `Text.rich(textSpan:)`.
String _plain(Text t) => t.data ?? t.textSpan?.toPlainText() ?? '';

void main() {
  group('الظهور والاختفاء', () {
    testWidgets('بلا مجموعات: لا تحذير ولا نص ولا سطر فراغ', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: const [],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => '',
        ),
      );

      expect(find.text(_header), findsNothing);
      expect(find.text('عرض البقية (0)'), findsNothing);
      // المكوّن يُرجع SizedBox.shrink: لا شيء يُرسم منه.
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('مع تكرار: الرأس والشرح وعدّاد المجموعات', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#5'),
                _receipt(id: 'b', serial: '#6', driverPhone: '07832222222'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (s) => s == 'accepted' ? 'مقبول' : s,
        ),
      );

      expect(find.text(_header), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(
        find.textContaining('نفس الزبون ونفس السلة خلال ست ساعات'),
        findsOneWidget,
      );
      expect(find.textContaining('الأول: #5'), findsOneWidget);
      expect(find.textContaining('تكرر عند: #6'), findsOneWidget);
      expect(find.textContaining('عدد المستلِمين 2'), findsOneWidget);
    });

    testWidgets('ثلاث نسخ في نفس المجموعة: الأول واحد واثنان أحمر', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#1'),
                _receipt(id: 'b', serial: '#2', driverPhone: '07832222222'),
                _receipt(id: 'c', serial: '#3', driverPhone: '07833333333'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مكتمل',
        ),
      );

      expect(find.textContaining('الأول: #1'), findsOneWidget);
      expect(find.textContaining('تكرر عند: #2'), findsOneWidget);
      expect(find.textContaining('تكرر عند: #3'), findsOneWidget);
      expect(find.textContaining('عدد المستلِمين 3'), findsOneWidget);
    });
  });

  group('الشكل على شاشة ضيقة (٣٦٠×٦٩٠)', () {
    testWidgets('مجموعة واحدة: بلا استثناء وبارتفاع لا يبتلع الشاشة', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a'),
                _receipt(id: 'b', driverPhone: '07832222222'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      expect(tester.takeException(), isNull);
      final h = tester.getSize(find.byType(DuplicateOrdersPanel)).height;
      expect(h, lessThan(300));
    });

    testWidgets('عدد المجموعات لا يمدّ اللوحة: الحدّ ثابت مهما كثرت', (
      tester,
    ) async {
      // ★ الاختبار بالثبات لا بالبكسل: مقاس الخطط في الاختبارات غير
      //   حقيقية (خط مستطيل)، فعدة البكسل هنا تخدع. ما يهمّ المنصة
      //   أن التحذير لا يزداد طولاً كلما زاد التكرار.
      Future<double> heightFor(int n) async {
        await _pump(
          tester,
          DuplicateOrdersPanel(
            groups: [
              for (var i = 0; i < n; i++)
                _group(
                  phone: '078300$i',
                  receipts: [
                    _receipt(id: 'x$i', serial: '#${i + 1}'),
                    _receipt(
                      id: 'y$i',
                      serial: '#${i + 51}',
                      driverPhone: '07832222222',
                    ),
                  ],
                ),
            ],
            expanded: true,
            onToggle: (_) {},
            statusLabel: (_) => 'مرفوض',
          ),
        );
        expect(tester.takeException(), isNull);
        // القائمة الداخلية محكومة بثلث الشاشة: هذا الحدّ هو ضمن
        //   ألا يدفن التحذير قائمة الطلبات التي تحته.
        final listHeight = tester
            .getSize(
              find.descendant(
                of: find.byType(DuplicateOrdersPanel),
                matching: find.byType(Scrollable),
              ),
            )
            .height;
        expect(listHeight, lessThanOrEqualTo(690 * 0.3 + 1));
        return tester.getSize(find.byType(DuplicateOrdersPanel)).height;
      }

      final eight = await heightFor(8);
      final forty = await heightFor(40);
      expect((forty - eight).abs(), lessThan(1.0));
    });

    testWidgets('القائمة الداخلية تمرر فعلاً حين تتجاوز الحد', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            for (var i = 0; i < 12; i++)
              _group(
                phone: '0783000$i',
                receipts: [
                  _receipt(id: 'x$i'),
                  _receipt(id: 'y$i', driverPhone: '07832222222'),
                ],
              ),
          ],
          expanded: true,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      final scroller = find.descendant(
        of: find.byType(DuplicateOrdersPanel),
        matching: find.byType(Scrollable),
      );
      expect(scroller, findsWidgets);
      await tester.drag(scroller.first, const Offset(0, -220));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('نص طويل في سطر واحد لا يكسر الصف', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              name: 'زبون باسم طويل جداً وممتد كي نختبر الالتفاف',
              basket: 999999999,
              receipts: [
                _receipt(
                  id: 'a',
                  serial: '#طل-٩٩٩٩٩٩',
                  driverName: 'مندوب باسم طويل جداً',
                ),
                _receipt(
                  id: 'b',
                  serial: '#طل-٩٩٩٩٩٧',
                  driverPhone: '07832222222',
                  driverName: 'مندوب آخر بسمط طويل',
                ),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'قيد التوصيل',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('تكرر عند: #طل-٩٩٩٩٩٧'), findsOneWidget);
    });
  });

  group('التفاعل', () {
    testWidgets('الضغط على سطر يُبلّغ عن نفس السطر', (tester) async {
      DuplicateReceipt? opened;
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'first', serial: '#5'),
                _receipt(id: 'later', serial: '#6', driverPhone: '07832222222'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          onOpenReceipt: (r) => opened = r,
          statusLabel: (_) => 'مقبول',
        ),
      );

      await tester.tap(find.textContaining('تكرر عند: #6'));
      await tester.pump();
      expect(opened?.orderId, 'later');

      await tester.tap(find.textContaining('الأول: #5'));
      await tester.pump();
      expect(opened?.orderId, 'first');
    });

    testWidgets('بلا مُبلِّغ: الأسطر غير قابلة للضغط ولا تنهار', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a'),
                _receipt(id: 'b', driverPhone: '07832222222'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      await tester.tap(find.textContaining('الأول: #5'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('«عرض البقية (٢)» يطلب التوسيع ثم يظهر «تقليص»', (
      tester,
    ) async {
      final requests = <bool>[];
      final groups = [
        for (var i = 0; i < 5; i++)
          _group(
            phone: '0783000000$i',
            receipts: [
              _receipt(id: 'a$i', serial: '#${i + 1}'),
              _receipt(
                id: 'b$i',
                serial: '#${i + 11}',
                driverPhone: '07832222222',
              ),
            ],
          ),
      ];

      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: groups,
          expanded: false,
          onToggle: requests.add,
          statusLabel: (_) => 'مقبول',
        ),
      );

      expect(find.text('عرض البقية (2)'), findsOneWidget);
      await tester.tap(find.text('عرض البقية (2)'));
      await tester.pump();
      expect(requests, [true]);

      // بعد التوسيع تُعرض المجموعات الخمس ويظهر زر التقليص.
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: groups,
          expanded: true,
          onToggle: requests.add,
          statusLabel: (_) => 'مقبول',
        ),
      );
      expect(find.text('تقليص'), findsOneWidget);
      await tester.tap(find.text('تقليص'));
      await tester.pump();
      expect(requests.last, false);
    });

    testWidgets('ثلاث مجموعات أو أقل: بلا زر توسيع', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            for (var i = 0; i < 3; i++)
              _group(
                phone: '0783000000$i',
                receipts: [
                  _receipt(id: 'a$i'),
                  _receipt(id: 'b$i', driverPhone: '07832222222'),
                ],
              ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      expect(find.textContaining('عرض البقية'), findsNothing);
      expect(find.text('تقليص'), findsNothing);
    });
  });

  group('نصوص الحقول', () {
    testWidgets('تسمية الحالة تأتي من الشاشة: مصدر واحد لا نسخة ثانية', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', status: 'delivered'),
                _receipt(
                  id: 'b',
                  driverPhone: '07832222222',
                  status: 'cancelled',
                ),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (s) => 'TR:$s',
        ),
      );

      expect(find.textContaining('TR:delivered'), findsOneWidget);
      expect(find.textContaining('TR:cancelled'), findsOneWidget);
    });

    testWidgets('سطر بلا مندوب: بلا فواصل مكرّرة «· ·»', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a'),
                _receipt(id: 'b', driverPhone: '07832222222'),
                _receipt(
                  id: 'c',
                  serial: '#7',
                  driverPhone: '',
                  driverName: 'لم يُستلَم بعد',
                  stamped: false,
                ),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'قيد الانتظار',
        ),
      );

      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(DuplicateOrdersPanel),
              matching: find.byType(Text),
            ),
          )
          .map(_plain)
          .toList();

      final identity = texts.firstWhere((t) => t.contains('تكرر عند: #7'));
      expect(identity, contains('لم يُستلَم بعد'));
      // سطر بلا مندوب: لا «·» يتبعها فراغ ثم «·» (كان الخلل في النص الموصول).
      expect(identity, isNot(contains('· ·')));
      expect(texts.where((t) => t.contains('· ·')), isEmpty);
      // الوقت في سطره الخاص: «إنشاء» لا «استلام».
      expect(texts.any((t) => t.startsWith('إنشاء')), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('وقت مسجَّل ووقت مستعمل من الإنشاء يميّزان كلماتهما', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#1'),
                _receipt(
                  id: 'b',
                  serial: '#2',
                  driverPhone: '07832222222',
                  stamped: false,
                ),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      expect(find.textContaining('استلام'), findsWidgets);
      expect(find.textContaining('إنشاء'), findsOneWidget);
    });
  });

  group('الترتيب والتمييز', () {
    testWidgets('مفتاح الألوان ظاهر: «الأساس» و«مكرر» بكلمتهما', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#5'),
                _receipt(id: 'b', serial: '#6', driverPhone: '07832222222'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      // شارة «الأساس» مرّتان: واحدة في المفتاح وواحدة على السطر.
      expect(find.text('الأساس'), findsNWidgets(2));
      expect(find.text('مكرر'), findsOneWidget);
      expect(find.textContaining('أول من استلم السلّة'), findsOneWidget);
      // الشرح يُصرّح بالترتيب الجديد.
      expect(find.textContaining('الأخطر أولاً'), findsOneWidget);
    });

    testWidgets('كل نسخة متأخرة بشارة «مكرر» برقمها، والأساس بلا رقم', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#1'),
                _receipt(id: 'b', serial: '#2', driverPhone: '07832222222'),
                _receipt(id: 'c', serial: '#3', driverPhone: '07833333333'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مكتمل',
        ),
      );

      expect(find.text('مكرر 2'), findsOneWidget);
      expect(find.text('مكرر 3'), findsOneWidget);
      expect(find.text('مكرر 1'), findsNothing);
    });

    testWidgets('التمييز لوناً: الأساس أخضر والمتأخر أحمر', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#5'),
                _receipt(id: 'b', serial: '#6', driverPhone: '07832222222'),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      // اللون على مقطع الهوية نفسه (النص مركّب: كلمة التمييز ثم الهوية).
      Color colorOf(String contains) {
        final span =
            tester.widget<Text>(find.textContaining(contains).first).textSpan!
                as TextSpan;
        return (span.children!.last as TextSpan).style!.color!;
      }

      expect(colorOf('الأول: #5'), AppColors.success);
      expect(colorOf('تكرر عند: #6'), AppColors.danger);
    });

    testWidgets('البطاقات مرقّمة «م1، م2…» لتُشار بالأرقام لا بالعدّ', (
      tester,
    ) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            for (var i = 0; i < 4; i++)
              _group(
                phone: '0783000000$i',
                receipts: [
                  _receipt(id: 'a$i', serial: '#${i + 1}'),
                  _receipt(
                    id: 'b$i',
                    serial: '#${i + 11}',
                    driverPhone: '07832222222',
                  ),
                ],
              ),
          ],
          expanded: true,
          onToggle: (_) {},
          statusLabel: (_) => 'مقبول',
        ),
      );

      for (var i = 1; i <= 4; i++) {
        expect(find.text('م$i'), findsOneWidget);
      }
      // الترقيم لاتيني لا «عرض البقية»: عدّاد الرأس يبقى رقماً مجرّداً.
      expect(find.text('4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('الحالة في شارة مستقلة بلا أن تُخفي الوقت', (tester) async {
      await _pump(
        tester,
        DuplicateOrdersPanel(
          groups: [
            _group(
              receipts: [
                _receipt(id: 'a', serial: '#5', status: 'delivered'),
                _receipt(
                  id: 'b',
                  serial: '#6',
                  driverPhone: '07832222222',
                  status: 'cancelled',
                ),
              ],
            ),
          ],
          expanded: false,
          onToggle: (_) {},
          statusLabel: (s) => s == 'delivered' ? 'مكتمل' : 'مرفوض',
        ),
      );

      expect(find.text('مكتمل'), findsOneWidget);
      expect(find.text('مرفوض'), findsOneWidget);
      // الوقت ما زال في سطره: لا يبتلعه اسم الحالة.
      expect(find.textContaining('استلام 27/10'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
