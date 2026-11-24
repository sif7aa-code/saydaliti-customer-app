import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/discount_service.dart';

/// ★ ثغرة «يفتح على ٣/٣ عند تسجيل الدخول» كانت تُقرَّر في الهاتف:
///   `delivered >= required` بعدّاد مطلق من أول التاريخ. هذه الاختبارات
///   تُغلق الباب أمام رجوعها — القرار يأتي من الخادم وحده، وأي حال أخرى
///   (حقق مفقود، ردّ قديم، اتصال فاشل) تعني **مقفول**.
DiscountUnlockStatus status(Map<String, dynamic> extra) =>
    DiscountUnlockStatus.fromJson(<String, dynamic>{
      'delivered': 0,
      'required': 3,
      'remaining': 3,
      'cycle_done': 0,
      'progress': '0/3',
      'unlocked': false,
      'message': '',
      ...extra,
    });

void main() {
  group('قرار الفتح يأتي من الخادم وحده', () {
    test('ثلاثة طلبات من أول التاريخ لا تفتح شيئاً', () {
      final s = status({'delivered': 3, 'unlocked': false});
      expect(s.unlocked, isFalse);
    });

    test('عشرة طلبات مع `unlocked: false` تبقى مقفولة', () {
      final s = status({
        'delivered': 10,
        'unlocked': false,
        'cycle_done': 1,
        'remaining': 2,
        'progress': '1/3',
      });
      expect(s.unlocked, isFalse);
      expect(s.left, 2);
      expect(s.done, 1);
    });

    test('قاعدة قديمة لا ترسل `unlocked` ⇒ مقفول (لا فتح احتياطاً)', () {
      final s = DiscountUnlockStatus.fromJson(<String, dynamic>{
        'delivered': 7,
        'required': 3,
        'remaining': 0,
      });
      expect(s.serverUnlocked, isNull);
      expect(s.known, isTrue);
      expect(s.unlocked, isFalse,
          reason: 'الافتراض القديم كان يفتح هنا — وهو عين الثغرة');
    });

    test('تعذّر الاتصال ⇒ مقفول بلا عدّاد مفتعل', () {
      const s = DiscountUnlockStatus.unavailable();
      expect(s.known, isFalse);
      expect(s.unlocked, isFalse);
      expect(s.progress, isEmpty);
      expect(s.label, contains('تعذّر التحقق'));
    });

    test('الخادم قال مفتوحاً ⇒ مفتوح بلا حساب محلي', () {
      final s = status({
        'delivered': 6,
        'unlocked': true,
        'cycle_done': 3,
        'remaining': 0,
        'progress': '3/3',
      });
      expect(s.unlocked, isTrue);
      expect(s.left, 0);
      expect(s.done, 3);
      expect(s.progress, '3/3');
    });

    test('عدّاد الخادم يُعرض حرفياً ولا يُعاد حسابُه', () {
      final s = status({'progress': '٢/٣', 'cycle_done': 2, 'remaining': 1});
      expect(s.progress, '٢/٣');
      expect(s.done, 2);
      expect(s.left, 1);
    });

    test('رسالة الخادم تسبق النص المحلي', () {
      final s = status({
        'used': true,
        'message': 'استعملت كوداً — يرجع العدّاد إلى ٠/٣: تُفتح بعد ٣ طلبات مكتملة',
      });
      expect(s.label, contains('استعملت كوداً'));
    });
  });

  group('قرار الأدمن (إيقاف الإنشاء التلقائي)', () {
    test('حقل مفقود = شغّال، ولا رسالة نهاية كاذبة', () {
      final s = status({'auto_enabled': null});
      expect(s.autoStopped, isFalse);
    });

    test('إيقاف صريح ⇒ رسالة النهاية تُعرض', () {
      final s = status({'auto_enabled': false, 'end_message': 'توقفت العروض'});
      expect(s.autoStopped, isTrue);
      expect(s.stoppedMessage, 'توقفت العروض');
    });
  });

  /// ★ بقايا الدورة الطويلة بقيت مكتوبة في نصّ القاعدة («تُفتح بعد ٩ طلبات»،
  ///   «بعد ١٠ طلبات») لا تصل إلى عين الزبون: العرض يُردّ إلى طول الدورة،
  ///   والقرار يبقى قرار الخادم وحده.
  group('لا عدد فوق ٣ في نصّ الدورة', () {
    test('رسالة الخادم بـ«١٠ طلبات» تُعرض بـ«٣ طلبات»', () {
      final s = status({'message': 'تُفتح بعد ١٠ طلبات مكتملة بنجاح'});
      expect(s.label, contains('٣ طلبات'));
      expect(s.label, isNot(contains('١٠')));
      expect(s.label, isNot(contains('10')));
    });

    test('رسالة لاتينية بـ10 تُردّ إلى 3 بلا مساس بقرار الفتح', () {
      final s = status({'message': 'تُفتح بعد 10 طلبات مكتملة بنجاح'});
      expect(s.label, contains('3 طلبات'));
      expect(s.label, isNot(contains('10')));
      expect(s.unlocked, isFalse);
    });

    test('«المتبقّي ٩» من أساس قديم يصير ٣', () {
      final s = status({'remaining': 9, 'cycle_done': 0, 'message': ''});
      expect(s.left, 3);
      expect(s.done, 0);
      expect(s.label, isNot(contains('9')));
      expect(s.label, isNot(contains('٩')));
    });

    test('عدّاد «2/10» يصير «2/3» و«٢/١٠» تصير «٢/٣»', () {
      expect(status({'progress': '2/10'}).progress, '2/3');
      expect(status({'progress': '٢/١٠'}).progress, '٢/٣');
      expect(status({'progress': '12/10'}).progress, '3/3');
    });

    test('العدد بالحروف («عشرة طلبات») يُردّ هو الآخر', () {
      expect(DiscountCycle.text('تُفتح بعد عشرة طلبات مكتملة'),
          contains('٣ طلبات'));
      expect(DiscountCycle.text('تُفتح بعد عشرة طلبات مكتملة'),
          isNot(contains('عشرة')));
    });

    test('وصف الكود المخزَّن من زمن الدورة الطويلة', () {
      final cleaned =
          DiscountCycle.text('خصم ٥٪ — بعد ١٠ طلبات مكتملة');
      expect(cleaned, 'خصم ٥٪ — بعد ٣ طلبات مكتملة');
    });

    test('ما هو ٣ أو أقل يبقى كما كتبه الأدمن حرفياً', () {
      expect(DiscountCycle.text('تُفتح بعد طلبين مكتملين بنجاح'),
          'تُفتح بعد طلبين مكتملين بنجاح');
      expect(DiscountCycle.text('خصم ٥٪ — بعد ٣ طلبات مكتملة'),
          'خصم ٥٪ — بعد ٣ طلبات مكتملة');
      expect(DiscountCycle.text('أكملت 3 طلبات مكتملة — أكوادك المتاحة'),
          'أكملت 3 طلبات مكتملة — أكوادك المتاحة');
      expect(DiscountCycle.text('كود رمضان'), 'كود رمضان');
    });

    test('لو أُرسل `required` بعشرة فالعرض يبقى ٣ والقرار للخادم', () {
      final s = status({'required': 10, 'remaining': 9, 'message': ''});
      expect(s.required, 3);
      expect(s.left, 3);
      expect(s.unlocked, isFalse);
      final open = status({'required': 10, 'unlocked': true, 'remaining': 0});
      expect(open.unlocked, isTrue,
          reason: 'التنسيق نصّي فقط — لا يفتح ولا يغلق باباً');
    });

    test('رسالة النهاية من الأدمن لا تحمل عدداً فوق الدورة', () {
      final s = status({
        'auto_enabled': false,
        'end_message': 'تُفتح العروض بعد ١٠ طلبات مكتملة',
      });
      expect(s.stoppedMessage, contains('٣ طلبات'));
      expect(s.stoppedMessage, isNot(contains('١٠')));
    });
  });
}
