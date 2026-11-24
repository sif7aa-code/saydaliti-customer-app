import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/driver_wallet_pending.dart';

/// ★ معلَّق محفظة المندوب — القاعدة التي يقرأ منها المندوب ولوحة الأدمن.
///
///   الطلب (٢٠٢٦-١٠-٢٩): «كود خصم عجلة الحظ أضف خصم المبلغ للمندوب
///   الموافق على الطلب للمحفظة»، وقراراته: معلَّق عند الموافقة ثم يُثبَّت
///   عند التوصيل · كل أكواد الخصم · المبلغ كاملاً.
///
///   المحرس هنا أربعة أمور، كلها كانت كذبة مالية لو تُركت:
///     ١) نسخة SQL القديمة (بلا الحقول) ⇒ **لا سطر**، لا «معلَّق ٠».
///     ٢) السالب لا يُعرض.
///     ٣) عدّاد البطاقة `orders` (طلبات الدفتر) لا يُخلط بعدّاد المعلَّق.
///     ٤) ما ثبت في الدفتر لا يبقى معلَّقًا — القاعدة تحرسه، والواجهة
///        تحرس عرضه.
void main() {
  Map<String, dynamic> row({
    String label = '#13',
    String code = 'WHEEL7X',
    Object amount = 10000,
    String status = 'مقبول',
    bool wheel = true,
  }) => {
    'order_label': label,
    'coupon_code': code,
    'amount': amount,
    'status_label': status,
    'from_wheel': wheel,
    'note': 'يُضاف إلى رصيدك عند تسليم الطلب',
  };

  group('غياب المعلَّق (نسخة قاعدة قديمة)', () {
    test('ردّ بلا أي حقل معلَّق ⇒ known=false ولا سطر', () {
      final p = DriverWalletPending.from({
        'balance': 13500,
        'entries': 5,
        'rows': <Object>[],
      });
      expect(p.known, isFalse);
      expect(p.hasMoney, isFalse);
      expect(p.hasRows, isFalse);
      expect(p.totalsLabel, isNull);
    });

    test('الحصيلة العلوية بلا total_pending ⇒ لا تُكذب', () {
      final p = DriverWalletPending.from({
        'total_discount': 13500,
        'total_paid': 4000,
        'total_due': 9500,
      });
      expect(p.known, isFalse);
      expect(p.amount, 0);
    });

    test('null آمن (شاشة قبل أول جلب)', () {
      expect(DriverWalletPending.from(null).known, isFalse);
      expect(DriverWalletPending.none.hasMoney, isFalse);
    });
  });

  group('المعلَّق موجود', () {
    test('بطاقة مندوب: مبلغه وعدد سطوره', () {
      final p = DriverWalletPending.from({
        'phone': '07700000001',
        'discount_total': 13500,
        'pending_amount': 10000,
        'pending_orders': 1,
        'pending_rows': [row()],
      });
      expect(p.known, isTrue);
      expect(p.amount, 10000);
      expect(p.orders, 1);
      expect(p.rows.length, 1);
      expect(p.hasMoney, isTrue);
      expect(p.hasRows, isTrue);
    });

    test('صفر مُرسل صراحة ⇒ معرّف لكنه بلا مال', () {
      final p = DriverWalletPending.from({
        'pending_amount': 0,
        'pending_orders': 0,
        'pending_rows': <Object>[],
      });
      expect(p.known, isTrue);
      expect(p.hasMoney, isFalse);
      expect(p.totalsLabel, 'لا معلَّق الآن');
    });

    test('الأرقام النصية تُقرأ (PostgREST يمدّد أحياناً كنص)', () {
      final p = DriverWalletPending.from({
        'pending_amount': '20000.00',
        'pending_orders': '2',
      });
      expect(p.amount, 20000);
      expect(p.orders, 2);
    });

    test('★ السالب لا يُعرض إطلاقاً', () {
      final p = DriverWalletPending.from({
        'pending_amount': -5000,
        'pending_orders': 3,
        'pending_rows': [row()],
      });
      expect(p.amount, 0);
      expect(p.hasMoney, isFalse);
    });

    test('★ عدّاد الدفتر `orders` لا يسرق عدّاد المعلَّق', () {
      final p = DriverWalletPending.from({
        'orders': 9,
        'earned': 13500,
        'pending_amount': 10000,
        'pending_rows': [row()],
      });
      expect(p.known, isTrue);
      expect(p.orders, 1);
    });

    test('بلا pending_orders ⇒ عدد السطور المرسلة', () {
      final p = DriverWalletPending.from({
        'pending_amount': 30000,
        'pending_rows': [row(), row(label: '#14', code: 'SHTR-A1')],
      });
      expect(p.orders, 2);
    });

    test('الحصيلة العلوية تُقرأ من total_pending', () {
      final p = DriverWalletPending.from({
        'total_pending': 30000,
        'pending_orders': 2,
      });
      expect(p.amount, 30000);
      expect(p.orders, 2);
      expect(p.totalsLabel, contains('30,000'));
    });
  });

  group('صيغة العدد', () {
    test('طلب / طلبان / طلبات', () {
      DriverWalletPending at(int n) => DriverWalletPending(
        known: true,
        amount: n * 1000.0,
        orders: n,
        rows: const <Map<String, dynamic>>[],
      );
      expect(at(1).ordersWord, 'طلب');
      expect(at(2).ordersWord, 'طلبان');
      expect(at(3).ordersWord, 'طلبات');
      expect(at(11).ordersWord, 'طلبات');
      expect(at(1).totalsLabel, contains('طلب'));
      expect(at(2).totalsLabel, contains('طلبان'));
    });
  });

  group('سطر المعلَّق للتفصيل', () {
    test('رقم الطلب وكوده وحالته وكونه من العجلة', () {
      final r = DriverWalletPending.row(row());
      expect(r.label, '#13');
      expect(r.code, 'WHEEL7X');
      expect(r.amount, 10000);
      expect(r.status, 'مقبول');
      expect(r.fromWheel, isTrue);
      expect(r.note, contains('تسليم'));
    });

    test('كود الأدمن ليس من العجلة، والوسم الفارغ لا يظهر', () {
      final r = DriverWalletPending.row(
        row(code: '—', wheel: false, status: 'قيد التوصيل'),
      );
      expect(r.code, isNull);
      expect(r.fromWheel, isFalse);
      expect(r.status, 'قيد التوصيل');
    });

    test('ردّ ناقص لا يرمي استثناء', () {
      final r = DriverWalletPending.row(const <String, dynamic>{});
      expect(r.label, '—');
      expect(r.code, isNull);
      expect(r.amount, 0);
      expect(r.status, '');
    });

    test('★ سطر صفر المبلغ لا يجعل للواجهة «مالاً معلَّقًا»', () {
      // القاعدة هي الحارس («not exists في الدفتر»)؛ والواجهة تحرس
      // المبلغ: سطر صفر لا يُرسم كمال.
      final p = DriverWalletPending.from({
        'pending_amount': 0,
        'pending_orders': 1,
        'pending_rows': [row(amount: 0)],
      });
      expect(p.hasMoney, isFalse);
      expect(p.hasRows, isTrue);
      expect(DriverWalletPending.row(p.rows.first).amount, 0);
    });
  });
}
