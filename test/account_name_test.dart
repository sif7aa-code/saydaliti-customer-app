import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/account_name.dart';
import 'package:saydaliti/core/utils/order_display.dart';

/// ★ لا لقب عام مكان اسم حساب: المعروض إمّا الاسم الحقيقي المخزَّن أو
///   الرقم الثابت — ولا كلمة تُخترع من عندنا («حساب»، «زبون»، «مندوب»).
///   الصيغة هنا هي القرار كلّه، فتُختبر كنصّ بلا شبكة.
void main() {
  const phone = '07800000001';

  group('الاسم الحقيقي يتقدّم', () {
    test('اسم موجود ⇒ هو المعروض، والرقم لا يزاحمه', () {
      expect(AccountName.real(name: 'أم علي', phone: phone), 'أم علي');
    });

    test('اسم المتجر يلي اسم الحساب مباشرةً', () {
      expect(
        AccountName.real(name: '', shop: 'بقالة الشطرة', phone: phone),
        'بقالة الشطرة',
      );
    });

    test('بلا اسم حقيقي ⇒ الرقم الثابت لا لقب', () {
      expect(AccountName.real(name: 'حساب', phone: phone), phone);
      expect(AccountName.real(name: null, phone: phone), phone);
      expect(AccountName.real(name: 'null', phone: phone), phone);
    });

    test('لا اسم ولا رقم ⇒ فراغ، والفراغ أصدق من اختراع اسم', () {
      expect(AccountName.real(name: 'زبون'), '');
      expect(AccountName.real(), '');
    });
  });

  group('الألقاب العامة مرفوضة في كل صيغة', () {
    const fakes = [
      'حساب',
      'حساب ',
      ' زبون',
      'عميل',
      'مستخدم',
      'مندوب',
      'تاجر',
      'account',
      'Account',
      'driver',
      'null',
      '',
    ];

    for (final label in fakes) {
      test('«$label» ليس اسماً ولا يُعرض', () {
        expect(AccountName.isGeneric(label), isTrue);
        expect(AccountName.real(name: label, phone: phone), phone);
      });
    }

    test('الأسماء الحقيقية تمرّ كما هي', () {
      for (final name in ['أم علي', 'أبو حسن', 'بقالة النور', 'حسن']) {
        expect(AccountName.isGeneric(name), isFalse);
        expect(AccountName.real(name: name, phone: phone), name);
      }
    });

    test('الفراغ واللا-شيء لقبٌ أيضاً', () {
      expect(AccountName.isGeneric(null), isTrue);
      expect(AccountName.isGeneric(''), isTrue);
      expect(AccountName.isGeneric('   '), isTrue);
    });
  });

  group('اسمٌ ورقم في سطر واحد', () {
    test('الاسم الحقيقي ثم رقمه', () {
      expect(AccountName.withPhone(name: 'أم علي', phone: phone),
          'أم علي · $phone');
    });

    test('لا اسم ⇒ الرقم مرة واحدة، لا مرتين ولا بلقب', () {
      expect(AccountName.withPhone(name: 'حساب', phone: phone), phone);
      expect(AccountName.withPhone(phone: phone), phone);
    });

    test('لا فراغ مكرر ولا نقطة يتيمة', () {
      expect(AccountName.withPhone(name: 'أم علي'), 'أم علي');
      expect(AccountName.withPhone(), '');
    });
  });

  group('اسم الزبون في البطاقات', () {
    test('لقبٌ مخزّن في الطلب ⇒ يُتجاهل ويُعرض الرقم', () {
      expect(
        OrderDisplay.customerName({'user_name': 'حساب', 'user_phone': phone}),
        phone,
      );
    });

    test('الاسم الحقيقي يبقى هو المعروض', () {
      expect(
        OrderDisplay.customerName({'user_name': 'أم علي', 'user_phone': phone}),
        'أم علي',
      );
    });

    test('لا «null» ولا لقب في أي حالة', () {
      for (final row in <Map<String, dynamic>>[
        {'user_name': null, 'user_phone': phone},
        {'user_name': 'null', 'user_phone': phone},
        {'user_name': '', 'user_phone': phone},
        {'user_name': 'زبون', 'user_phone': phone},
        {'user_name': 'مندوب', 'user_phone': '07800000002'},
      ]) {
        final shown = OrderDisplay.customerName(row);
        expect(AccountName.isGeneric(shown), isFalse,
            reason: 'صفّ $row أعاد «$shown»');
      }
    });

    test('ولا اسم ولا رقم ⇒ فراغ لا لقب', () {
      expect(OrderDisplay.customerName({'user_name': 'حساب'}), '');
    });
  });
}
