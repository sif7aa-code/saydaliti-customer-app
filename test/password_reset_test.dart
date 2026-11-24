import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/password_reset.dart';

/// ★ حراسة «استعادة كلمة المرور».
///
/// الكتابة كلها داخل القاعدة في `reset_password_with_token` — انظر
/// `SQL_FIX_PASSWORD_RESET.sql` — فلا يملك التطبيق منها شيئاً. ما يملكه
/// وي يجب أن يثبت: أنه **لا يرسل** كلمة سيئة، وأنه **يشرح** سبب الرفض
/// بالعربية بدل «تعذّر الحفظ» الغامضة التي كانت تُسمع الزبون لكل عطل.
/// هذه الاختبارات كلها بلا شبكة.
void main() {
  const okPhone = '07857683066';

  group('تطبيع الرقم', () {
    test('يبقي الأرقام فقط ويحذف الفواصل والرموز', () {
      expect(PasswordReset.digits('  0785-7683-066 '), okPhone);
      expect(PasswordReset.digits('+964 785 768 3066'), '9647857683066');
      expect(PasswordReset.digits('abc'), '');
    });

    test('الرقم المحلي الكامل ١١ رقماً هو المقياس', () {
      expect(PasswordReset.digits(okPhone).length, 11);
      expect(
        PasswordReset.validate('123456', '123456', phone: '0785'),
        'أدخل رقم هاتف صحيح (١١ رقماً)',
      );
    });

    // الصيغة الدولية ١٣ رقماً تُقال هنا ولا تُرسَل: لو قصّها التطبيق إلى
    // ١١ لَصارت آخر ٩ أرقام مختلفة، فترفضها القاعدة بـ«PHONE_MISMATCH»
    // وتُسمّع الزبون كذبة عن الكود لا عن رقمه.
    test('«+964…» مرفوضة بصريح العبارة قبل الشبكة', () {
      expect(PasswordReset.digits('+964 785 768 3066'), '9647857683066');
      expect(
        PasswordReset.validate('123456', '123456', phone: '9647857683066'),
        'أدخل رقم هاتف صحيح (١١ رقماً)',
      );
    });
  });

  group('التحقق قبل الإرسال', () {
    test('يقبل كلمة متطابقة ومعقولة', () {
      expect(
        PasswordReset.validate('123456', '123456', phone: okPhone),
        isNull,
      );
    });

    test('الفارغة مرفوضة ولا تخرج رحلة شبكة', () {
      expect(
        PasswordReset.validate('', '', phone: okPhone),
        'اكتب كلمة المرور الجديدة',
      );
    });

    test('أقل من ٦ محارف مرفوضة — نفس حدّ القاعدة', () {
      expect(
        PasswordReset.validate('12345', '12345', phone: okPhone),
        'كلمة المرور 6 محارف على الأقل',
      );
      expect(PasswordReset.minLength, 6);
    });

    test('غير متطابقتين مرفوضة', () {
      expect(
        PasswordReset.validate('123456', '123457', phone: okPhone),
        'كلمتا المرور غير متطابقتين',
      );
    });

    // ★ الحارس الذي لا يراه أحد: bcrypt يقصّ فوق ٧٢ **بايتاً** بصمت،
    //   والحرف العربي بايتان. فقياس المحارف وحده كان يمرّر كلمة تُحفظ
    //   أنصافها ويدخلها صاحبها كاملة فيُرفض دخوله.
    test('٣٦ حرفاً عربيّاً = ٧٢ بايتاً = على الحدّ تماماً', () {
      final atLimit = 'ع' * 36;
      expect(PasswordReset.byteLength(atLimit), 72);
      expect(PasswordReset.validate(atLimit, atLimit, phone: okPhone), isNull);
    });

    test('٣٧ حرفاً عربيّاً = ٧٤ بايتاً = مرفوضة قبل أن تُبتر', () {
      final over = 'ع' * 37;
      expect(over.length, lessThan(PasswordReset.maxLength));
      expect(PasswordReset.byteLength(over), 74);
      expect(
        PasswordReset.validate(over, over, phone: okPhone),
        'كلمة المرور طويلة — الحد 72 بايت',
      );
    });

    test('٧٣ حرفاً إنجليزيّاً مرفوضة هي الأخرى', () {
      final long = 'a' * 73;
      expect(
        PasswordReset.validate(long, long, phone: okPhone),
        'كلمة المرور طويلة — الحد 72 بايت',
      );
    });
  });

  group('سطر النجاح', () {
    test('يقول اسم الحساب نفسه لا لقباً عاماً', () {
      expect(
        PasswordReset.successLine({
          'ok': true,
          'name': 'زينب كريم',
          'phone': okPhone,
        }, phone: okPhone),
        'تم تغيير كلمة مرور زينب كريم — سجّل الدخول بها الآن',
      );
    });

    test('بلا اسم يذكر الرقم المخزّن كما ردّته القاعدة', () {
      expect(
        PasswordReset.successLine({
          'ok': true,
          'name': '',
          'phone': '9647857683066',
        }, phone: okPhone),
        'تم تغيير كلمة مرور 9647857683066 — سجّل الدخول بها الآن',
      );
    });

    test('ولا شيء منهما؟ آخر حيلة هي رقم المستخدم نفسه', () {
      expect(
        PasswordReset.successLine({'ok': true}, phone: ' $okPhone '),
        'تم تغيير كلمة مرور $okPhone — سجّل الدخول بها الآن',
      );
    });
  });

  group('رسائل الفشل — لكل رمز عبارة', () {
    const codes = <String, String>{
      'PW_SHORT': 'كلمة المرور 6 محارف على الأقل',
      'PW_LONG': 'كلمة المرور طويلة — الحد 72 بايت',
      'BAD_PHONE': 'أدخل رقم هاتف صحيح (١١ رقماً)',
      'MISSING_TOKEN': 'لم يتم تأكيد الرقم بعد — أرسل الكود وأكّده ثم احفظ',
      'BAD_TOKEN': 'لم يتم تأكيد الرقم بعد — أرسل الكود وأكّده ثم احفظ',
      'BAD_PAYLOAD': 'لم يتم تأكيد الرقم بعد — أرسل الكود وأكّده ثم احفظ',
      'BAD_CLAIMS': 'لم يتم تأكيد الرقم بعد — أرسل الكود وأكّده ثم احفظ',
      'BAD_SIGNATURE': 'لم يتم تأكيد الرقم بعد — أرسل الكود وأكّده ثم احفظ',
      'TOKEN_EXPIRED': 'انتهت صلاحية الكود — أرسل كوداً جديداً',
      'TOKEN_REPLAYED': 'هذا الكود استُخدم من قبل — أرسل كوداً جديداً',
      'PHONE_MISMATCH': 'الكود اكتمل لرقم غير هذا الرقم — أعد المحاولة برقمك',
      'NO_ACCOUNT': 'لا يوجد حساب بهذا الرقم — سجّل حساباً جديداً أولاً',
      'ACCOUNT_DISABLED': 'الحساب موقوف — راجع خدمة العملاء لرفعه',
      'AMBIGUOUS_PHONE': 'الرقم مطابق لأكثر من حساب — راجع خدمة العملاء',
      'NOT_CONFIGURED': 'خادم التحقق غير مضبوط — راجع خدمة العملاء',
      'NO_HASH_TRIGGER': 'تعذّر الحفظ على السيرفر — أعد المحاولة بعد قليل',
      'HASH_NOT_WRITTEN': 'تعذّر الحفظ على السيرفر — أعد المحاولة بعد قليل',
      'NOT_UPDATED': 'تعذّر الحفظ على السيرفر — أعد المحاولة بعد قليل',
      'TOKEN_STATE_FAILED': 'تعذّر الحفظ على السيرفر — أعد المحاولة بعد قليل',
      'LEGACY_FUNCTION':
          'دالة استعادة كلمة المرور قديمة — شغّل SQL_FIX_PASSWORD_RESET.sql',
      'BAD_RESPONSE': 'ردّ غير متوقع من السيرفر — أعد المحاولة بعد قليل',
      'EXCEPTION': 'تعذّر الاتصال بالسيرفر — تأكد من الشبكة وأعد المحاولة',
    };

    for (final e in codes.entries) {
      test('${e.key} ← «${e.value}»', () {
        expect(
          PasswordReset.failureLine({'ok': false, 'error': e.key}),
          e.value,
        );
      });
    }

    test('لا يجوز أن يبقى رمز بغير عبارة', () {
      // كل رمز تُرجعه الدالة يجب أن يكون مذكوراً أعلاه، وإلا رجع السطر
      // العام «تعذّر تغيير كلمة المرور (X)» ولا يعرف الزبون شيئاً.
      const fromSql = <String>{
        'BAD_PHONE',
        'PW_SHORT',
        'PW_LONG',
        'LOCKED',
        'NO_HASH_TRIGGER',
        'MISSING_TOKEN',
        'NOT_CONFIGURED',
        'BAD_TOKEN',
        'BAD_SIGNATURE',
        'BAD_PAYLOAD',
        'BAD_CLAIMS',
        'TOKEN_EXPIRED',
        'PHONE_MISMATCH',
        'TOKEN_REPLAYED',
        'NO_ACCOUNT',
        'AMBIGUOUS_PHONE',
        'ACCOUNT_DISABLED',
        'NOT_UPDATED',
        'HASH_NOT_WRITTEN',
        'TOKEN_STATE_FAILED',
      };
      final explained = <String>{...codes.keys, 'LOCKED', 'HTTP_404'};
      expect(fromSql.difference(explained), isEmpty);
    });

    test('قفّل المحاولات يذكر الوقت المتبقّي', () {
      expect(
        PasswordReset.failureLine({
          'ok': false,
          'error': 'LOCKED',
          'retry_after': '02:00',
        }),
        'كثرت المحاولات على هذا الرقم — حاول بعد 02:00',
      );
      expect(
        PasswordReset.failureLine({'ok': false, 'error': 'LOCKED'}),
        'المحاولات موقوفة مؤقتاً — حاول بعد قليل',
      );
    });

    test('404 = الملف لم يُشغّل بعد، وهذا حرفياً ما يجب أن يُقال', () {
      expect(
        PasswordReset.failureLine({'ok': false, 'error': 'HTTP_404'}),
        'دالة استعادة كلمة المرور غير منصّبة بعد — '
        'شغّل SQL_FIX_PASSWORD_RESET.sql',
      );
    });

    test('أي حالة أخرى برمزها فلا تُنسب للزبون', () {
      expect(
        PasswordReset.failureLine({'ok': false, 'error': 'HTTP_500'}),
        'تعذّر الحفظ على السيرفر (رمز 500) — أعد المحاولة بعد قليل',
      );
    });

    test('رمز مجهول يبقى مذكوراً في الجملة ولا يختفي', () {
      expect(
        PasswordReset.failureLine({'error': 'WHAT_IS_THIS'}),
        'تعذّر تغيير كلمة المرور (WHAT_IS_THIS)',
      );
      expect(PasswordReset.failureLine({}), 'تعذّر تغيير كلمة المرور');
    });
  });
}
