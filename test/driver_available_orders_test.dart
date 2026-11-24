import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/supabase_service.dart';

/// ★ «الطلبات الجديدة لا تظهر للمندوب — صوت بلا شيء».
///
/// الشاشة كانت ترى قائمة فارغة في ثلاث حالات لا تُميَّز: لا طلب فعلاً،
/// والقراءة سقطت، والحالة في القاعدة ليست كلمة `pending`. القرار كله في
/// [readDriverAvailableOrders]، فيُختبر هنا بوظيفة جلب وهمية بلا شبكة:
/// `null` = فشل الردّ، و`[]` = لا صفوف فعلاً.
void main() {
  Map<String, dynamic> order(String id, {String status = 'pending'}) =>
      {'id': id, 'status': status};

  /// جلب وهمي يسجّل المرشّحات التي طُلبت، ويردّ بما يُخزَّن لكل مرشّح
  /// (`null` = سقوط).
  Future<List<Map<String, dynamic>>?> Function(String) fake(
    Map<String, Object?> byFilter, {
    List<String>? calls,
  }) {
    return (filter) async {
      calls?.add(filter);
      final v = byFilter[filter];
      if (v == null) return null;
      return List<Map<String, dynamic>>.from(v as List);
    };
  }

  group('المرشّحان', () {
    test('المفتوح يبدأ بـ `pending`: الحالة المعهودة لا تُستثنى', () {
      expect(
        DriverOrderFilters.availableOpen,
        'status=in.(pending,new,open,placed,created)',
      );
      expect(
        DriverOrderFilters.availableOpen,
        contains('pending'),
      );
    });

    test('المرشّح الضيّق هو الصيغة القديمة حرفياً', () {
      expect(DriverOrderFilters.availableStrict, 'status=eq.pending');
    });

    test('لا تسريب لطلبات زميل: المقبولة والقيد التوصيل ليست متاحة', () {
      final f = DriverOrderFilters.availableOpen;
      expect(f, isNot(contains('accepted')));
      expect(f, isNot(contains('delivering')));
      expect(f, isNot(contains('delivered')));
      expect(f, isNot(contains('rejected')));
      expect(f, isNot(contains('cancelled')));
      // النفي كان يُرجع أي حالة غريبة (مثل `assigned`) فتُقبل مرتين.
      expect(f, isNot(contains('not.in')));
    });
  });

  group('المسار العادي: نداء واحد بلا حِمل إضافي', () {
    test('الحالات المفتوحة نجحت ⇒ صفوفها تُرجَع ولا محاولة ثانية', () async {
      final calls = <String>[];
      final read = await readDriverAvailableOrders(
        fake({
          DriverOrderFilters.availableOpen: [
            order('1'),
            order('2', status: 'new')
          ]
        }, calls: calls),
      );
      expect(read.orders.map((o) => o['id']).toList(), ['1', '2']);
      expect(read.usedStrict, isFalse);
      expect(read.failed, isFalse);
      expect(calls, [DriverOrderFilters.availableOpen]);
    });

    test('فارغ حقيقي بالمرشّح المفتوح ⇒ «لا طلبات»، لا فشل ولا نزول',
        () async {
      final calls = <String>[];
      final read = await readDriverAvailableOrders(
        fake({DriverOrderFilters.availableOpen: []}, calls: calls),
      );
      expect(read.orders, isEmpty);
      expect(read.failed, isFalse);
      expect(read.usedStrict, isFalse);
      expect(calls.length, 1);
    });
  });

  group('الحالة المكتوبة غير `pending`: الطلب لا يبقى مخفيّاً', () {
    test('طلب بحالة `open` يظهر في المتاحة', () async {
      final read = await readDriverAvailableOrders(
        fake({
          DriverOrderFilters.availableOpen: [
            order('7', status: 'open')
          ]
        }),
      );
      expect(read.orders.map((o) => o['id']), ['7']);
      expect(read.failed, isFalse);
    });

    test('مرشّح `in.` مرفوض من المخطّط ⇒ المرشّح القديم ينقذ القراءة',
        () async {
      final read = await readDriverAvailableOrders(
        fake({
          DriverOrderFilters.availableStrict: [order('8')],
        }),
      );
      expect(read.orders.map((o) => o['id']), ['8']);
      expect(read.usedStrict, isTrue);
      expect(read.failed, isFalse);
    });
  });

  group('سقوط القراءة: صراحة بلا محو', () {
    test('المرشّحان يسقطان ⇒ `failed` = true وقائمة فارغة', () async {
      final calls = <String>[];
      final read = await readDriverAvailableOrders(fake({}, calls: calls));
      expect(read.orders, isEmpty);
      expect(read.failed, isTrue);
      expect(read.usedStrict, isTrue);
      // المرشّح الضيّق جُرّب فعلاً قبل إعلان السقوط.
      expect(calls,
          [DriverOrderFilters.availableOpen, DriverOrderFilters.availableStrict]);
    });

    test('سقوط المفتوح ونجاح الضيّق بصفوف = قراءة سليمة لا فشل', () async {
      final read = await readDriverAvailableOrders(
        fake({
          DriverOrderFilters.availableStrict: [order('9'), order('10')],
        }),
      );
      expect(read.orders.length, 2);
      expect(read.failed, isFalse);
    });
  });
}
