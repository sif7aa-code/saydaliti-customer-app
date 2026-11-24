import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/shop_rename.dart';

/// ★ حراسة «الأدمن يغيّر اسم المتجر».
///
/// الكتابة الثقيلة (تحديث الاسم في نسخه الأربع) تحدث داخل
/// `admin_rename_shop` في القاعدة — انظر `SQL_ADMIN_RENAME_SHOP.sql`.
/// دور التطبيق أصغر لكنه ليس تجميلياً: يمنع الاسم الفارغ/الطويل/المكرر
/// قبل أن يخرج من الجهاز، ثم يترجم رمز الفشل إلى عربية يقرأها الأدمن.
/// هذه الاختبارات تثبت الترجمة كلها **بلا شبكة**.
void main() {
  group('تنظيف الاسم والتحقق منه', () {
    test('يطرف الحقلين ويضغط المسافات المتكررة', () {
      expect(ShopRename.clean('  محل  دوا  '), 'محل دوا');
      expect(ShopRename.clean('محل\t\nدوا'), 'محل دوا');
      expect(ShopRename.clean(''), '');
    });

    test('يقبل الاسم الجديد الصريح', () {
      expect(
        ShopRename.validate('سوبر مارش النور', current: 'سوبر مارش قديم'),
        isNull,
      );
    });

    test('الفارغ مرفوض حتى لو كان مسافات فقط', () {
      expect(
        ShopRename.validate('   ', current: 'زوزايه'),
        'اكتب اسم المتجر أولاً',
      );
    });

    test('الاسم نفسه لا يُرسَل — يعتبره «لم يتغيّر»', () {
      // المسافات المختلفة لا تُغيّر الحكم: «محل دوا» = «محل  دوا »
      expect(
        ShopRename.validate('محل  دوا  ', current: ' محل دوا'),
        'الاسم كما هو، لم يتغيّر',
      );
      expect(ShopRename.isSameAsCurrent('محل  دوا ', 'محل دوا'), isTrue);
    });

    test('الطول فوق حدّ الحقل مرفوض', () {
      final long = 'ا' * (ShopRename.maxNameLength + 1);
      expect(
        ShopRename.validate(long, current: 'زوزايه'),
        contains('${ShopRename.maxNameLength}'),
      );
    });
  });

  group('رسالة النجاح تقول الحصيلة', () {
    test('تعدّ المنتجات والسطور والأقسام التي تبعت الاسم', () {
      final line = ShopRename.resultLine({
        'ok': true,
        'name': 'مخبز النخيل',
        'products': 12,
        'order_items': 30,
        'sections': 1,
      }, oldName: 'مخبز الشطرة');
      expect(line, contains('من «مخبز الشطرة» إلى «مخبز النخيل»'));
      expect(line, contains('12 منتجاً'));
      expect(line, contains('30 سطر طلب'));
      expect(line, contains('1 قسم'));
    });

    test('متجر بلا منتجات ولا سطور يقول ذلك صراحة', () {
      final line = ShopRename.resultLine({
        'ok': true,
        'name': 'محل جديد',
      }, oldName: 'محل قديم');
      expect(line, contains('لا سطور ولا منتجات له'));
    });
  });

  group('رموز الدالة تتحوّل عربية', () {
    test('كل رمز له رسالته بالعربية', () {
      expect(ShopRename.failureLine({'error': 'NOT_ADMIN'}), contains('أدمن'));
      expect(ShopRename.failureLine({'error': 'NO_SESSION'}), contains('أدمن'));
      expect(ShopRename.failureLine({'error': 'EMPTY_NAME'}), isNotEmpty);
      expect(ShopRename.failureLine({'error': 'TOO_LONG'}), contains('60'));
      expect(
        ShopRename.failureLine({'error': 'NOT_FOUND'}),
        contains('الصيدلية'),
      );
      expect(ShopRename.failureLine({'error': 'BAD_ARGUMENT'}), isNotEmpty);
    });

    test('الاسم المكرر يسمّي صاحب الاسم إن أعطته الدالة', () {
      expect(
        ShopRename.failureLine({'error': 'DUP_NAME', 'taken_by': 'زوزايه'}),
        contains('زوزايه'),
      );
      expect(
        ShopRename.failureLine({'error': 'DUP_NAME'}),
        contains('اختر اسماً مختلفاً'),
      );
    });

    test('404 يعني أن الدالة لم تُنصب بعد — فيُقال للأدمن شغّل الملف', () {
      expect(
        ShopRename.failureLine({'error': 'HTTP_404'}),
        contains('SQL_ADMIN_RENAME_SHOP.sql'),
      );
    });

    test('رمز مجهول لا يترك الأدمن بلا نص', () {
      expect(ShopRename.failureLine({'error': 'WEIRD'}), contains('WEIRD'));
      expect(ShopRename.failureLine({}), 'تعذر تغيير الاسم');
    });
  });
}
