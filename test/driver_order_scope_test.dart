import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/supabase_service.dart';

/// ★ «كل مندوب وطلباته»: تبويبا المنتهي (مكتمل/مرفوض) لا يشتبكان للجميع.
///
/// الصيغة هنا هي القرار كلّه — الجلب مجرد تنفيذ لها، فتُختبر كنصّ بلا
/// شبكة. الهدف أن يبقى كل مندوب على رقمه، ولا يرى رفض غيره ولا إلغاءات
/// الإدارة التي لا تعنيه.
void main() {
  const phone = '07800000001';
  const other = '07800000002';

  group('مكتمل المندوب', () {
    test('مُسند لرقمه ومُسلَّم — لا طلبات غيره', () {
      expect(DriverOrderFilters.delivered(phone),
          'status=eq.delivered&assigned_driver_phone=eq.$phone');
    });

    test('رقم مختلف ⇒ فلتر مختلف، فلا تشابك بين المندوبين', () {
      expect(DriverOrderFilters.delivered(phone),
          isNot(DriverOrderFilters.delivered(other)));
    });

    test('الرموز والمسافات لا تدخل الفلتر (كانت تكسر الرابط)', () {
      expect(DriverOrderFilters.delivered(' +964 780 000 00 01 '),
          'status=eq.delivered&assigned_driver_phone=eq.9647800000001');
    });
  });

  group('مرفوض المندوب', () {
    test('المرشّح الأول: ما رفضه هو أو كان مسنداً إليه', () {
      expect(DriverOrderFilters.rejectedPrimary(phone),
          'status=in.(rejected,cancelled)'
          '&or=(rejected_by_phone.eq.$phone,assigned_driver_phone.eq.$phone)');
    });

    test('الاحتياطي بلا عمود الرافض: إسناد فقط، لا «كل المرفوض»', () {
      final fallback = DriverOrderFilters.rejectedFallback(phone);
      expect(fallback,
          'status=in.(rejected,cancelled)&assigned_driver_phone=eq.$phone');
      expect(fallback, isNot(contains('rejected_by_phone')));
    });

    test('لا مرشّح يترك التبويب عاماً', () {
      for (final f in [
        DriverOrderFilters.delivered(phone),
        DriverOrderFilters.rejectedPrimary(phone),
        DriverOrderFilters.rejectedFallback(phone),
      ]) {
        expect(f, contains('eq.$phone'));
      }
    });

    test('رقم فارغ ⇒ فلتر لا يطابق أحداً، لا فلتر يُرجع الكل', () {
      expect(DriverOrderFilters.delivered(''),
          'status=eq.delivered&assigned_driver_phone=eq.');
      expect(DriverOrderFilters.rejectedFallback(''),
          'status=in.(rejected,cancelled)&assigned_driver_phone=eq.');
      expect(DriverOrderFilters.rejectedPrimary(''),
          'status=in.(rejected,cancelled)'
          '&or=(rejected_by_phone.eq.,assigned_driver_phone.eq.)');
    });
  });

  group('العزل من داخل القاعدة (دالة الجلسة أولاً، النصي احتياطاً)', () {
    test('اسما الدالتين كما في SQL_DRIVER_ORDER_ISOLATION.sql', () {
      expect(SupabaseService.deliveredRpcFn, 'driver_delivered_orders');
      expect(SupabaseService.rejectedRpcFn, 'driver_rejected_orders');
    });

    test('٢xx = نجحت ⇒ لا نزول للاحتياط', () {
      for (final code in [200, 201, 204, 206]) {
        expect(rpcAvailabilityFor(code), RpcAvailability.available);
      }
    });

    test('٤٠٤ = الدالة غير موجودة (الملف لم يُشغَّل) ⇒ نثبت الغياب', () {
      expect(rpcAvailabilityFor(404), RpcAvailability.notCreatedYet);
    });

    test('انقطاع و٤٠١ و٥٠٠ عابرة: لا تُسجَّل كغياب للدالة', () {
      for (final code in [0, 400, 401, 403, 500, 502, 503]) {
        expect(rpcAvailabilityFor(code), RpcAvailability.transientFailure);
      }
    });
  });
}
