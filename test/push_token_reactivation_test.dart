import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/push_service.dart';

/// انحدار لعطل «المندوب لا يصله إشعار الطلب الجديد والتطبيق مغلق»:
/// الخروج يُبطل صفّ الجهاز في `push_tokens`، والدخول من جديد في نفس
/// العملية كان يمرّ بلا كتابة لأن التوكن لم يتغيّر ⇒ `is_active=false`
/// يبقى، والسيرفر لا يرسل FCM لصفّ معطّل.
void main() {
  group('كتابة توكن الجهاز على الخادم', () {
    test('أول مرة في العملية: تُكتب', () {
      expect(
        PushService.needsTokenWrite(
          token: 'T1',
          phone: '07700000001',
          savedToken: null,
          activatedPhone: null,
        ),
        isTrue,
      );
    });

    test('نفس التوكن ونفس الحساب: لا تُكتب (بلا ٤ طلبات عند كل عودة)', () {
      expect(
        PushService.needsTokenWrite(
          token: 'T1',
          phone: '07700000001',
          savedToken: 'T1',
          activatedPhone: '07700000001',
        ),
        isFalse,
      );
    });

    test('توكن جديد لنفس الحساب: تُكتب', () {
      expect(
        PushService.needsTokenWrite(
          token: 'T2',
          phone: '07700000001',
          savedToken: 'T1',
          activatedPhone: '07700000001',
        ),
        isTrue,
      );
    });

    test('الدخول بعد الخروج (نسيان التفعيل): تُكتب ولو بالتوكن نفسه', () {
      // `forgetRegisteredToken` يصفّر الحقلين، فتصير الحالة كأول كتابة.
      PushService.instance.forgetRegisteredToken();
      expect(
        PushService.needsTokenWrite(
          token: 'T1',
          phone: '07700000001',
          savedToken: null,
          activatedPhone: null,
        ),
        isTrue,
      );
    });

    test('حساب آخر على نفس الجهاز ونفس التوكن: تُكتب', () {
      expect(
        PushService.needsTokenWrite(
          token: 'T1',
          phone: '07700000002',
          savedToken: 'T1',
          activatedPhone: '07700000001',
        ),
        isTrue,
      );
    });
  });
}
