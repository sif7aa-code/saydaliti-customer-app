import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/auth_fields.dart';

/// ★ حراسة «كل الحقول إجبارية» في الدخول وإنشاء الحساب.
///
///   الدوال في `auth_fields.dart` صرفة بلا شبكة ولا ويجِت، فالحجة كلها
///   تُختبر هنا: أن الحقل الفارغ لا يمرّ، وأن الناقص لا يمرّ، وأن
///   اللقب العام («حساب») لا يُقبل اسماً، وأن رسالة الخطأ عربية واحدة
///   مصدرها الملف نفسه الذي تستدعيه الشاشات الثلاث.
void main() {
  const okPhone = '07857683066';

  group('رقم الهاتف', () {
    test('فارغ ⇒ إجباري، ورسالة غير رسالة الناقص', () {
      expect(AuthFields.phoneError(''), 'أدخل رقم الهاتف');
      expect(AuthFields.phoneError('   '), 'أدخل رقم الهاتف');
      expect(
        AuthFields.phoneError('0785'),
        'يجب أن يكون الرقم 11 رقماً بالضبط',
      );
    });

    test('مكتمل ⇒ بلا خطأ، ومع الفواصل والرموز كذلك', () {
      expect(AuthFields.phoneError(okPhone), isNull);
      expect(AuthFields.phoneError('  0785-7683-066 '), isNull);
    });

    test('الكامل لكنه ليس موبايل عراقي ⇒ يمرّ عند الدخول', () {
      expect(AuthFields.phoneError('12345678901'), isNull);
    });

    test('التسجيل يشترط بادئة 07 وحده', () {
      expect(
        AuthFields.phoneError('12345678901', requireMobilePrefix: true),
        'رقم الهاتف يبدأ بـ07 مثل 07800000000',
      );
      expect(AuthFields.phoneError(okPhone, requireMobilePrefix: true), isNull);
    });

    test('أحد عشر رقماً دولية ليست رقماً محلياً', () {
      expect(
        AuthFields.phoneError('9647857683066'),
        'يجب أن يكون الرقم 11 رقماً بالضبط',
      );
    });
  });

  group('كلمة المرور', () {
    test('في الدخول: فراغ فقط ممنوع، ولا حدّ طول', () {
      expect(AuthFields.loginPasswordError(''), 'أدخل كلمة المرور');
      expect(AuthFields.loginPasswordError('    '), 'أدخل كلمة المرور');
      expect(AuthFields.loginPasswordError('abc'), isNull);
    });

    test('في التسجيل: إجبارية وبحدّ الاستعادة نفسه', () {
      expect(AuthFields.passwordError(''), 'أدخل كلمة المرور');
      expect(AuthFields.passwordError('123'), 'كلمة المرور 6 محارف على الأقل');
      expect(
        AuthFields.passwordError('12345'),
        'كلمة المرور 6 محارف على الأقل',
      );
      expect(AuthFields.passwordError('123456'), isNull);
    });

    test('الحدّ بايتات لا محارف — كلمة عربية طويلة تُرفض', () {
      // محرفان بايتان: ٣٦ محرفاً = ٧٢ بايت = الحدّ تماماً ⇒ مقبولة.
      expect(AuthFields.passwordError('ش' * 36), isNull);
      expect(
        AuthFields.passwordError('ش' * 40),
        'كلمة المرور طويلة — الحد 72 بايت',
      );
    });

    test('التأكيد إجباري ومطابق', () {
      expect(AuthFields.confirmError('123456', ''), 'أعد كتابة كلمة المرور');
      expect(
        AuthFields.confirmError('123456', '123457'),
        'كلمتا المرور غير متطابقتين',
      );
      expect(AuthFields.confirmError('123456', '123456'), isNull);
    });
  });

  group('اسم الحساب', () {
    test('فارغ ⇒ إجباري', () {
      expect(AuthFields.nameError(''), 'أدخل اسم الصيدلية أو اسمك');
      expect(AuthFields.nameError('   '), 'أدخل اسم الصيدلية أو اسمك');
    });

    test('لقب عام مرفوض — لا «حساب» ولا «زبون» ولا «مندوب»', () {
      expect(
        AuthFields.nameError('حساب'),
        'اكتب اسمه الحقيقي، لا لقباً مثل «حساب» أو «زبون»',
      );
      expect(
        AuthFields.nameError('زبون'),
        'اكتب اسمه الحقيقي، لا لقباً مثل «حساب» أو «زبون»',
      );
      expect(
        AuthFields.nameError('مندوب'),
        'اكتب اسمه الحقيقي، لا لقباً مثل «حساب» أو «زبون»',
      );
    });

    test('قصير جداً أو طويل مرفوض، وحقيقي مقبول', () {
      expect(AuthFields.nameError('أ'), 'الاسم 3 محارف على الأقل');
      expect(AuthFields.nameError('أم'), 'الاسم 3 محارف على الأقل');
      expect(AuthFields.nameError('مخبز أم علي'), isNull);
      expect(AuthFields.nameError('س' * 41), 'الاسم طويل — الحد 40 محرفاً');
    });
  });

  group('كود واتساب', () {
    test('فارغ وناقص رسالتان مختلفتان', () {
      expect(AuthFields.codeError('', codeLength: 6), 'أدخل كود التحقق');
      expect(
        AuthFields.codeError('123', codeLength: 6),
        'أدخل الكود كاملاً (6 أرقام)',
      );
      expect(AuthFields.codeError('123456', codeLength: 6), isNull);
    });

    test('المسافات والشرطات لا تُحتسب أطولاً', () {
      expect(
        AuthFields.codeError('12-34', codeLength: 6),
        'أدخل الكود كاملاً (6 أرقام)',
      );
    });
  });
}
