import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/order_duplicates.dart';

/// ★ باني صفّ طلب كما يصل من `fetchAllOrders()` (أي من PostgREST):
///   الحقول اختيارية بالحذف، والأرقام قد تصل `num` أو نصّاً.
Map<String, dynamic> order({
  required String id,
  Object? phone = '07830000001',
  Object? name = 'زبون',
  Object? total = 12000,
  Object? fee = 0,
  Object? discount = 0,
  Object? driver = '07831111111',
  Object? acceptedAt,
  Object? createdAt = '2026-10-27T10:00:00.000Z',
  Object? status = 'accepted',
  Object? serial,
}) {
  final row = <String, dynamic>{
    'id': id,
    'total_amount': total,
    'status': status,
  };
  // الحذف التام للحقل يحاكي قاعدة بلا هذا العمود، لا قيمة صورية.
  if (phone != null) row['user_phone'] = phone;
  if (name != null) row['user_name'] = name;
  if (fee != null) row['delivery_fee'] = fee;
  if (discount != null) row['coupon_discount'] = discount;
  if (driver != null) row['assigned_driver_phone'] = driver;
  if (acceptedAt != null) row['accepted_at'] = acceptedAt;
  if (createdAt != null) row['created_at'] = createdAt;
  if (serial != null) row['serial_number'] = serial;
  return row;
}

void main() {
  group('كشف التكرار — الشرط الأساسي', () {
    test('نسختان عند مندوبين مختلفين = تحذير واحد', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T10:05:00.000Z', serial: 5),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T10:40:00.000Z',
          serial: 6,
        ),
      ]);

      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.customerPhone, '07830000001');
      expect(g.receipts, hasLength(2));
      expect(g.driverCount, 2);
      expect(g.laterOnes, hasLength(1));
    });

    test('الأول استلاماً هو الأقدم وقتاً، والمتأخر بعده', () {
      // الأقدم مُرَّر ثانياً في القائمة: الترتيب بالوقت لا بترتيب الوارد.
      final groups = OrderDuplicates.find([
        order(
          id: 'late',
          driver: '07832222222',
          acceptedAt: '2026-10-27T11:30:00.000Z',
          serial: 8,
        ),
        order(id: 'first', acceptedAt: '2026-10-27T10:15:00.000Z', serial: 7),
      ]);

      final g = groups.single;
      expect(g.firstReceived.orderId, 'first');
      expect(g.firstReceived.serial, '#7');
      expect(g.laterOnes.single.orderId, 'late');
    });

    test('نفس المندوب على نسختين ليس تكراراً عند المندوبين', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T10:05:00.000Z'),
        order(id: 'b', acceptedAt: '2026-10-27T10:40:00.000Z'),
      ]);
      expect(groups, isEmpty);
    });

    test('نسختان بلا مندوب لا تُنذران (لا مستلِم بعد)', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', driver: null, acceptedAt: null),
        order(id: 'b', driver: null, acceptedAt: null),
      ]);
      expect(groups, isEmpty);
    });

    test('ثلاثة مندوبين = مجموعة واحدة بثلاثة سطور', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T11:00:00.000Z', serial: 9),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T11:10:00.000Z',
          serial: 10,
        ),
        order(
          id: 'c',
          driver: '07833333333',
          acceptedAt: '2026-10-27T11:20:00.000Z',
          serial: 11,
        ),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.receipts, hasLength(3));
      expect(groups.single.driverCount, 3);
    });

    test('زبائن مختلفون بنفس السلة لا يتكررون', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          phone: '07830000001',
          acceptedAt: '2026-10-27T10:05:00.000Z',
        ),
        order(
          id: 'b',
          phone: '07830000002',
          driver: '07832222222',
          acceptedAt: '2026-10-27T10:40:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });

    test('سلة مختلفة المبلغ للزبون نفسه ليست تكراراً', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', total: 12000, acceptedAt: '2026-10-27T10:05:00.000Z'),
        order(
          id: 'b',
          total: 19000,
          driver: '07832222222',
          acceptedAt: '2026-10-27T10:40:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });

    test('سطر بلا رقم زبون يُتجاهل ولا يُجمَع مع سطر آخر', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', phone: null, acceptedAt: '2026-10-27T10:05:00.000Z'),
        order(
          id: 'b',
          phone: null,
          driver: '07832222222',
          acceptedAt: '2026-10-27T10:40:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });
  });

  group('بصمة السلة (المجموع + الخصم − الرسوم)', () {
    test('نسخة استعملت كود خصم تُطابق أختها بلا خصم', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          total: 10000,
          discount: 0,
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          total: 9500,
          discount: 500,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);

      expect(groups, hasLength(1));
      // القيمة المرجعة هي سلة السطر الأول (بعد الترتيب)، لا المجموع المدفوع.
      expect(groups.single.basketAmount, 10000);
    });

    test('نسخة برسوم توصيل تُطابق نسخة أُعفيت منها', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          total: 12000,
          fee: 0,
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          total: 14000,
          fee: 2000,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.basketAmount, 12000);
    });

    test('بلا حقول رسوم أو خصم في القاعدة = صفر، لا استثناء', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          fee: null,
          discount: null,
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          fee: null,
          discount: null,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, hasLength(1));
    });

    test('الأرقام الواردة نصّاً من JSON تُحلَّل كما هي', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          total: '12000',
          fee: '0',
          discount: '0',
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          total: '12000.0',
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, hasLength(1));
    });

    test('تقريب لأقرب دينار: فرق أقل من نصف دينار لا يُفلت التكرار', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', total: 10000.2, acceptedAt: '2026-10-27T09:00:00.000Z'),
        order(
          id: 'b',
          total: 10000.4,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, hasLength(1));
    });

    test('فرق دينارين كاملين = سلتان مختلفتان', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', total: 10000, acceptedAt: '2026-10-27T09:00:00.000Z'),
        order(
          id: 'b',
          total: 10002,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });

    test('السلة الفارغة المبلغ (طلبات المندوب الحر) مستثناة', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', total: 0, acceptedAt: '2026-10-27T09:00:00.000Z'),
        order(
          id: 'b',
          total: 0,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });

    test('صفْر المدفوع مع خصم حقيقي يظلّ سلة تُقارَن', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          total: 0,
          discount: 5000,
          fee: 0,
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          total: 0,
          discount: 5000,
          fee: 0,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      // السلة ليست صفرية (الخصم هو من صفّرها) فالتحذير مطلوب.
      expect(groups, hasLength(1));
      expect(groups.single.basketAmount, 5000);
    });

    test('سلة سالبة القيمة (رسوم بلا مجموع) تُتجاهل', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          total: 0,
          discount: 0,
          fee: 2000,
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          total: 0,
          discount: 0,
          fee: 2000,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });
  });

  group('النافذة الزمنية (ست ساعات)', () {
    test('فارق سبع ساعات = طلب لاحق حقيقي لا تكرار', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T08:00:00.000Z'),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T15:30:00.000Z',
        ),
      ]);
      expect(groups, isEmpty);
    });

    test('فارق ست ساعات بالضبط ما زال داخل النافذة', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T08:00:00.000Z'),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T14:00:00.000Z',
        ),
      ]);
      expect(groups, hasLength(1));
    });

    test('سلسلة ثلاث: الفجوة الكبيرة تقطعها فلا يمتد التكرار', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T08:00:00.000Z', serial: 1),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T10:00:00.000Z',
          serial: 2,
        ),
        order(
          id: 'c',
          driver: '07833333333',
          acceptedAt: '2026-10-27T20:00:00.000Z',
          serial: 3,
        ),
      ]);

      expect(groups, hasLength(1));
      expect(groups.single.receipts.map((r) => r.orderId), ['a', 'b']);
    });

    test('سلسلة تُقطع إلى مجموعتين كلٌّ بمندوبين', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T08:00:00.000Z'),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(id: 'c', acceptedAt: '2026-10-27T20:00:00.000Z'),
        order(
          id: 'd',
          driver: '07833333333',
          acceptedAt: '2026-10-27T21:00:00.000Z',
        ),
      ]);
      expect(groups, hasLength(2));
    });

    test('المجموعات تُرتَّب الأحدث أولاً', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'old',
          phone: '07830000001',
          acceptedAt: '2026-10-20T08:00:00.000Z',
        ),
        order(
          id: 'old2',
          phone: '07830000001',
          driver: '07832222222',
          acceptedAt: '2026-10-20T09:00:00.000Z',
        ),
        order(
          id: 'new',
          phone: '07830000002',
          total: 25000,
          acceptedAt: '2026-10-27T08:00:00.000Z',
        ),
        order(
          id: 'new2',
          phone: '07830000002',
          total: 25000,
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
      ]);

      expect(groups, hasLength(2));
      expect(groups.first.customerPhone, '07830000002');
      expect(groups.last.customerPhone, '07830000001');
    });
  });

  group('وقت الاستلام المعروض', () {
    test('بلا accepted_at يُستعمل وقت الإنشاء مع علامة أنه إنشاء', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: null, createdAt: '2026-10-27T09:00:00.000Z'),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: null,
          createdAt: '2026-10-27T09:30:00.000Z',
        ),
      ]);

      final g = groups.single;
      expect(g.receipts.first.hasReceiptStamp, isFalse);
      expect(
        g.receipts.first.receivedAt.toUtc(),
        DateTime.parse('2026-10-27T09:00:00.000Z'),
      );
      expect(OrderDuplicates.stampLabel(g.receipts.first), startsWith('إنشاء'));
    });

    test('مع accepted_at تكون الوسم «استلام» وبالتاريخ والساعة', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          acceptedAt: '2026-10-27T13:05:00.000Z',
          createdAt: '2026-10-27T08:00:00.000Z',
        ),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T13:40:00.000Z',
        ),
      ]);

      final label = OrderDuplicates.stampLabel(groups.single.receipts.first);
      expect(label, startsWith('استلام'));
      // اليوم والشهر بالمنطقة الزمنية للجهاز، والساعة بمفردة ١٢ مع صباحاً/مساءً.
      final local = DateTime.parse('2026-10-27T13:05:00.000Z').toLocal();
      expect(
        label,
        contains(
          '${local.day.toString().padLeft(2, '0')}/'
          '${local.month.toString().padLeft(2, '0')}',
        ),
      );
      expect(label, matches(RegExp(r'\d{1,2}:\d{2} (صباحاً|مساءً)')));
      // الاستلام هو المعتمد لا وقت الإنشاء: 13:05 UTC لا 08:00 UTC.
      expect(groups.single.receipts.first.receivedAt.toUtc().hour, 13);
    });

    test('وقت غير مقروء لا يُسقط الصلح: يرجع وقت الإنشاء أو الصفر', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          acceptedAt: 'ليس وقتاً',
          createdAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T11:20:00.000Z',
        ),
      ]);
      expect(groups.single.receipts.first.hasReceiptStamp, isFalse);
    });
  });

  group('قراءة حقول العرض بلا انهيار', () {
    test('رقم الطلب بلا تسلسل يرجع من الرقم القديم أو علامة خالية', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', driver: null, serial: null),
        order(id: 'b', driver: '07832222222'),
      ]);
      // بلا مستلِمَين لا مجموعة، لكن قراءة الوسم وحدها يجب ألّا ترمي استثناء.
      expect(groups, isEmpty);
      final withLegacy = OrderDuplicates.find([
        {
          'id': 'a',
          'user_phone': '07830000001',
          'total_amount': 12000,
          'order_number': 'ORD-9',
          'assigned_driver_phone': '07831111111',
          'created_at': '2026-10-27T09:00:00.000Z',
        },
        {
          'id': 'b',
          'user_phone': '07830000001',
          'total_amount': 12000,
          'assigned_driver_phone': '07832222222',
          'created_at': '2026-10-27T09:20:00.000Z',
        },
      ]);
      expect(withLegacy.single.receipts.first.serial, '#ORD-9');
    });

    test('مندوب بلا اسم يُعرض برقمه، وبلا مندوب يُسمّى «لم يُستلَم بعد»', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T09:00:00.000Z', serial: 1),
        order(
          id: 'b',
          driver: '',
          acceptedAt: null,
          createdAt: '2026-10-27T09:10:00.000Z',
          serial: 2,
        ),
        order(
          id: 'c',
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
          serial: 3,
        ),
      ]);

      final g = groups.single;
      expect(g.receipts.first.driverName, '07831111111');
      expect(g.receipts[1].driverName, 'لم يُستلَم بعد');
      // العدد يحسب المندوبين الحقيقيين فقط، فسطر بلا مندوب لا يضيف واحداً.
      expect(g.driverCount, 2);
    });

    test('الحالة تُنقل كما هي في السطر (ليراها الأدمن مع التكرار)', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'a',
          status: 'delivered',
          acceptedAt: '2026-10-27T09:00:00.000Z',
        ),
        order(
          id: 'b',
          status: 'cancelled',
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);

      expect(groups.single.receipts.first.status, 'delivered');
      expect(groups.single.laterOnes.single.status, 'cancelled');
    });

    test('قائمة فارغة أو سطر واحد = بلا تحذير ولا استثناء', () {
      expect(OrderDuplicates.find([]), isEmpty);
      expect(OrderDuplicates.find([order(id: 'a')]), isEmpty);
    });
  });

  group('سلامة الاستخدام من الشاشة', () {
    test('الناتج غير قابل للتعديل: لا يختلّ التحذير بتعديل من الواجهة', () {
      final groups = OrderDuplicates.find([
        order(id: 'a', acceptedAt: '2026-10-27T09:00:00.000Z'),
        order(
          id: 'b',
          driver: '07832222222',
          acceptedAt: '2026-10-27T09:20:00.000Z',
        ),
      ]);
      expect(() => groups.add(groups.first), throwsUnsupportedError);
    });

    test('البيانات الأصلية لا تتبدل (الترتيب داخل الشاشة يبقى للمعاينة)', () {
      final rows = [
        order(
          id: 'late',
          driver: '07832222222',
          acceptedAt: '2026-10-27T11:30:00.000Z',
        ),
        order(id: 'first', acceptedAt: '2026-10-27T10:15:00.000Z'),
      ];
      OrderDuplicates.find(rows);
      expect(rows.first['id'], 'late');
    });

    test('مئات السطور تُفحص بلا نداء شبكة وبزمن مقبول', () {
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < 600; i++) {
        rows.add(
          order(
            id: 'x$i',
            phone: '0783000${i % 40}',
            total: 5000 + (i % 7) * 1000,
            driver: '07831${i % 5}',
            acceptedAt: '2026-10-27T0${i % 9}:0${i % 6}:00.000Z',
          ),
        );
      }
      final watch = Stopwatch()..start();
      final groups = OrderDuplicates.find(rows);
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1000));
      // لا ادّعاء على عدد محدّد: المهم ألّا يستثني وألّا ينهار.
      for (final g in groups) {
        expect(g.receipts.length, greaterThanOrEqualTo(2));
        expect(g.driverCount, greaterThanOrEqualTo(2));
      }
    });

    test('النافذة ثابتة ست ساعات (تُقرأ في شرح اللوحة)', () {
      expect(OrderDuplicates.window, const Duration(hours: 6));
    });
  });

  group('الترتيب بالخطر (اللوحة «مخربطة» بلا ترتيب)', () {
    DuplicateReceipt rec(String id, String status, String driver, String at) =>
        DuplicateReceipt(
          orderId: id,
          serial: '#$id',
          driverPhone: driver,
          driverName: driver,
          receivedAt: DateTime.parse(at),
          hasReceiptStamp: true,
          status: status,
        );

    dupGroup(List<DuplicateReceipt> rs) => DuplicateGroup(
      customerPhone: '07830000001',
      customerName: 'زبون',
      basketAmount: 12000,
      receipts: rs,
    );

    test('مكتمل = الأخطر، ثم في الطريق، ثم مقبول، ثم ما عداه', () {
      expect(
        OrderDuplicates.urgency(
          dupGroup([
            rec('a', 'accepted', '07831111111', '2026-10-27T10:00:00Z'),
            rec('b', 'delivered', '07832222222', '2026-10-27T10:30:00Z'),
          ]),
        ),
        DuplicateUrgency.settled,
      );
      expect(
        OrderDuplicates.urgency(
          dupGroup([
            rec('a', 'accepted', '07831111111', '2026-10-27T10:00:00Z'),
            rec('b', 'delivering', '07832222222', '2026-10-27T10:30:00Z'),
          ]),
        ),
        DuplicateUrgency.onTheWay,
      );
      expect(
        OrderDuplicates.urgency(
          dupGroup([
            rec('a', 'accepted', '07831111111', '2026-10-27T10:00:00Z'),
            rec('b', 'pending', '07832222222', '2026-10-27T10:30:00Z'),
          ]),
        ),
        DuplicateUrgency.accepted,
      );
      // مرفوض/ملغى بلا أي نسخة حيّة: أدرج قائمة، لا أولها.
      expect(
        OrderDuplicates.urgency(
          dupGroup([
            rec('a', 'rejected', '07831111111', '2026-10-27T10:00:00Z'),
            rec('b', 'cancelled', '07832222222', '2026-10-27T10:30:00Z'),
          ]),
        ),
        DuplicateUrgency.other,
      );
    });

    test('الخطر يسبق الزمن: المكرر المكتمل الأقدم قبل المقبول الأحدث', () {
      final settledOld = dupGroup([
        rec('a', 'delivered', '07831111111', '2026-10-20T09:00:00Z'),
        rec('b', 'delivered', '07832222222', '2026-10-20T09:20:00Z'),
      ]);
      final freshAccepted = dupGroup([
        rec('c', 'accepted', '07831111111', '2026-10-27T09:00:00Z'),
        rec('d', 'accepted', '07832222222', '2026-10-27T09:20:00Z'),
      ]);

      // مُرَّرة الأحدث أولاً: الترتيب يجب أن يقلبها بالخطر لا بالوارد.
      final sorted = OrderDuplicates.sortGroups([freshAccepted, settledOld]);
      expect(sorted.first.receipts.first.orderId, 'a');
      expect(sorted.last.receipts.first.orderId, 'c');
    });

    test('متساويا الخطر: الأكثر نسخاً أولاً ثم الأحدث استلاماً', () {
      final two = dupGroup([
        rec('a', 'accepted', '07831111111', '2026-10-27T09:00:00Z'),
        rec('b', 'accepted', '07832222222', '2026-10-27T09:20:00Z'),
      ]);
      final threeNewer = dupGroup([
        rec('c', 'accepted', '07831111111', '2026-10-27T11:00:00Z'),
        rec('d', 'accepted', '07832222222', '2026-10-27T11:10:00Z'),
        rec('e', 'accepted', '07833333333', '2026-10-27T11:20:00Z'),
      ]);
      final threeOlder = dupGroup([
        rec('f', 'accepted', '07831111111', '2026-10-26T11:00:00Z'),
        rec('g', 'accepted', '07832222222', '2026-10-26T11:10:00Z'),
        rec('h', 'accepted', '07833333333', '2026-10-26T11:20:00Z'),
      ]);

      final byCount = OrderDuplicates.sortGroups([two, threeNewer]);
      expect(byCount.first.receipts, hasLength(3));

      // نفس العدد ونفس الخطر: يرجح الأحدث — وهو الترتيب القديم.
      final byTime = OrderDuplicates.sortGroups([threeOlder, threeNewer]);
      expect(byTime.first.receipts.first.orderId, 'c');

      // sortGroups لا يبدّل المُدخل: الشاشة تستعمل القائمة أصلها للمعاينة.
      final input = [two, threeNewer];
      OrderDuplicates.sortGroups(input);
      expect(input.first.receipts, hasLength(2));
    });

    test('find() يُرجع المجموعات بالخطر أصلاً: اللوحة لا تُعاد ترتيبها', () {
      final groups = OrderDuplicates.find([
        order(
          id: 'new_accepted',
          phone: '07830000002',
          total: 25000,
          status: 'accepted',
          acceptedAt: '2026-10-27T12:00:00.000Z',
        ),
        order(
          id: 'new_accepted_2',
          phone: '07830000002',
          total: 25000,
          status: 'accepted',
          driver: '07832222222',
          acceptedAt: '2026-10-27T12:20:00.000Z',
        ),
        order(
          id: 'old_delivered',
          phone: '07830000001',
          status: 'delivered',
          acceptedAt: '2026-10-21T08:00:00.000Z',
        ),
        order(
          id: 'old_delivered_2',
          phone: '07830000001',
          status: 'delivered',
          driver: '07832222222',
          acceptedAt: '2026-10-21T08:30:00.000Z',
        ),
      ]);

      expect(groups, hasLength(2));
      expect(groups.first.customerPhone, '07830000001');
      expect(OrderDuplicates.urgency(groups.first), DuplicateUrgency.settled);
      expect(groups.last.customerPhone, '07830000002');
    });
  });
}
