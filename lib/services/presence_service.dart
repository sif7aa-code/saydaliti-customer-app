import 'dart:async';

import 'auth_service.dart';
import 'supabase_service.dart';

/// ★ حضور التطبيق (٢٠٢٦-١١-٢٦): «متصل الآن» يُعلَن عند فتح التطبيق
///   ويُجدَّد كل ٣٠ ثانية، و«آخر ظهور» يُختم عند مغادرته — بلا حاجة
///   لخروج ودخول.
///
///   القاعدة تعتبر الحساب متصلاً إن أعلن الدخول ونبض خلال ٩٠ ثانية؛
///   فإن انقطع الجهاز بلا وداع (بطارية/شبكة) انتهت صلاحية النبضة
///   وحدها فيظهر «آخر ظهور» تلقائياً.
class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  static const Duration _every = Duration(seconds: 30);

  Timer? _timer;

  /// فتح التطبيق أو العودة للمقدمة: نبضة فوراً ثم كل ٣٠ ثانية.
  void markOnline() {
    _timer ??= Timer.periodic(_every, (_) => unawaited(_ping(true)));
    unawaited(_ping(true));
  }

  /// مغادرة التطبيق: نبضة خروج (وقت آخر ظهور) ثم إيقاف المؤقّت.
  void markOffline() {
    _timer?.cancel();
    _timer = null;
    unawaited(_ping(false));
  }

  /// قبل تسجيل الخروج: الجلسة لا تزال قائمة، فيُختم «آخر ظهور» الآن
  ///   بانتظار النداء (بعد تفريغ الجلسة لا يستطيع النداء إثبات هويته).
  Future<void> markOfflineNow() async {
    _timer?.cancel();
    _timer = null;
    await _ping(false);
  }

  Future<void> _ping(bool online) async {
    if (!AuthService.instance.isLoggedIn) return;
    // ٣ ثوانٍ فقط: النبضة تجميلية — إن تأخرت الشبكة فالصلاحية ٩٠ ثانية
    //   تغطيها، ولا يجوز أن تُعلّق تسجيل الخروج.
    await SupabaseService.instance.rpcCall(
      'chat_presence_set',
      <String, dynamic>{'p_online': online},
      timeoutSeconds: 3,
    );
  }
}
