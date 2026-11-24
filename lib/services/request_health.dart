import 'package:http/http.dart' as http;

/// عدّاد صغير لطلبات الشبكة **الفاشلة**، ليكون «نجح التحديث» حقيقة لا
/// انطباعًا.
///
/// ★ لماذا لا تكتفي الواجهة بـ«السحب انتهى»؟
///   `RefreshIndicator.onRefresh` يكتفي بأن تُرجع الدالة `Future` مكتملًا،
///   وكل دوال `_load()` في التطبيق تبتلع خطأها (`catch (_)`) وتضع نصًّا في
///   `_error`. أي أن السحب ينتهي بنفس الشكل سواء وصل الجديد أو سقط الطلب
///   بـ500/404/انقطاع. رنّة «تم التحديث» بعد فشل تعني كذبًا على المستخدم،
///   وهذا أسوأ من الصمت.
///
/// ★ نقطة واحدة للعدّ لا ٢٦ شاشة:
///   كل نداءات الشبكة في التطبيق تمرّ من العميل المشترك
///   `SupabaseService._http`، فهو المكان الوحيد الذي يُقرَّر فيه «هذا الطلب
///   لم ينجح». الشاشات لا تُعدّ شيئًا، ولا يُطلب من أي دالة أن تُرجع
///   نجاحًا — فلا تعديل على عشرات الدوال ولا احتمال نسيان واحدة.
///
/// تُقرأ العدادات من [AppRefresh] (`lib/widgets/app_refresh_indicator.dart`)
/// حول جسم التحديث:snapshot قبل، ومقارنة بعد.
abstract final class RequestHealth {
  /// عدد الردود غير 2xx + الاستثناءات (انقطاع، DNS، timeout) منذ تشغيل التطبيق.
  static int failures = 0;

  /// علامة قبل بدء التحديث.
  static int mark() => failures;

  /// هل سقط أي طلب خلال التحديث؟
  static bool failedSince(int since) => failures != since;

  /// يلفّ عميل HTTP ليسجّل الفاشل منه. يرجع نفس واجهة [http.Client] تمامًا،
  /// فاستبدال العميل الحالي لا يغيّر أي سطر نداء.
  static http.Client track(http.Client inner) => _TrackingClient(inner);
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final res = await _inner.send(request);
      // 4xx/5xx ⇒ لم تحصل على بياناتك. (204/205/206 نجاح عند PostgREST.)
      if (res.statusCode >= 400) RequestHealth.failures++;
      return res;
    } catch (_) {
      RequestHealth.failures++;
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
