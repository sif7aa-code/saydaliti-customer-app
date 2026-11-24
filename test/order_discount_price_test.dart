import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/order_display.dart';

/// ★ أسعار الطلب عند وجود كود خصم — صفحة الزبون «تفاصيل الطلب».
///
///   الأدمن طلب (٢٠٢٦-١٠-٢٩): «احفظ سعر الطلب بعد الخصم في صفحة
///   الزبون واكتب تم تطبيق كود خصم». الحفظ موجود في `total_amount`
///   (يُكتب بعد طرح الكود)، فالاختبار يحرس أمرين:
///     ١) أن يُقرأ المدفوع كما هو، وأن يشتقّ الأصلي بجمع الخصم.
///     ٢) أن يبقى نصّ «تم تطبيق كود خصم» حرفياً في ملاحظة الزبون.
void main() {
  Map<String, dynamic> order({
    double total = 45000,
    double discount = 5000,
    String? code = 'SAVE5K',
  }) => {
    'total_amount': total,
    'coupon_discount': discount,
    'coupon_code': code,
  };

  group('سعر الطلب بعد الخصم', () {
    test('المدفوع = total_amount بلا حساب في الواجهة', () {
      expect(OrderDisplay.priceAfterDiscount(order()), 45000);
    });

    test('الأصلي = المدفوع + الخصم، فيُقرأ قبل/بعد معاً', () {
      expect(OrderDisplay.priceBeforeDiscount(order()), 50000);
    });

    test('بلا خصم: الأصلي هو المدفوع ولا اختراع لرقم', () {
      final o = order(discount: 0, code: null);
      expect(OrderDisplay.priceBeforeDiscount(o), 45000);
      expect(OrderDisplay.priceAfterDiscount(o), 45000);
      expect(OrderDisplay.hasDiscount(o), isFalse);
    });

    test('خصم أكبر من المدفوع (تقاطع بيانات): لا سعر أصلي سالب', () {
      final o = order(total: 0, discount: 5000);
      expect(OrderDisplay.priceBeforeDiscount(o), 5000);
      expect(OrderDisplay.priceAfterDiscount(o), 0);
    });

    test('الأرقام قد تصل نصاً من القاعدة', () {
      final o = <String, dynamic>{
        'total_amount': '45000.5',
        'coupon_discount': '5000',
        'coupon_code': 'X',
      };
      expect(OrderDisplay.priceAfterDiscount(o), 45000.5);
      expect(OrderDisplay.priceBeforeDiscount(o), 50000.5);
    });

    test('نصف الأعمدة غائب: لا انهيار ولا رقم وهمي', () {
      const o = <String, dynamic>{'total_amount': 20000};
      expect(OrderDisplay.priceAfterDiscount(o), 20000);
      expect(OrderDisplay.priceBeforeDiscount(o), 20000);
      expect(OrderDisplay.discountNote(o, showCode: true), isEmpty);
    });
  });

  group('نصّ «تم تطبيق كود خصم»', () {
    test('للزبون: الجملة الحرفية ثم اسم الكود ثم المبلغ', () {
      final note = OrderDisplay.discountNote(order(), showCode: true);
      expect(note, startsWith('تم تطبيق كود خصم'));
      expect(note, contains('SAVE5K'));
      expect(note, contains('5,000'));
    });

    test('للمندوب: الجملة الحرفية بلا اسم الكود', () {
      final note = OrderDisplay.discountNote(order(), showCode: false);
      expect(note, startsWith('تم تطبيق كود خصم'));
      expect(note, isNot(contains('SAVE5K')));
      expect(note, contains('5,000'));
    });

    test('كود بغير مبلغ: لا يُختلق خصم صفري', () {
      final note = OrderDisplay.discountNote(
        order(discount: 0),
        showCode: true,
      );
      expect(note, 'تم تطبيق كود خصم SAVE5K على هذا الطلب');
    });

    test('لا كود ولا خصم ⇒ لا سطر أصلاً (الشاشة لا تُحشو)', () {
      expect(
        OrderDisplay.discountNote(order(discount: 0, code: null),
            showCode: true),
        isEmpty,
      );
    });

    test('المبلغ الكسري لا يفقد أرقامه', () {
      final note = OrderDisplay.discountNote(
        order(discount: 1250.5),
        showCode: false,
      );
      expect(note, contains('1,250.5'));
    });
  });
}
