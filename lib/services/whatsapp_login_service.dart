import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/secrets.dart';

/// نتيجة إرسال الكود، وفيها المدة المتبقية لإعادة الإرسال بالثواني.
class WhatsappSendResult {
  const WhatsappSendResult({required this.ok, this.retryAfter = 0, this.error});
  final bool ok;
  final int retryAfter;
  final String? error;
}

/// نتيجة التحقق، وفيها التوكن عند النجاح.
class WhatsappVerifyResult {
  const WhatsappVerifyResult({
    required this.ok,
    this.token,
    this.error,
    this.attemptsLeft,
  });
  final bool ok;
  final String? token;
  final String? error;
  final int? attemptsLeft;
}

/// خدمة تسجيل الدخول بكود واتساب.
///
/// تتصل بسيرفر `qrlogn` الذي يرسل كود التحقق عبر واتساب، ثم تتحقق منه
/// وتعيد توكناً. التوكن يُحفظ محلياً ليصير الدخول قائماً على الجهاز.
class WhatsappLoginService {
  WhatsappLoginService._();
  static final WhatsappLoginService instance = WhatsappLoginService._();

  /// عنوان السيرفر.
  ///
  /// ★ على الويب لا يُستدعى مباشرة: صفحة HTTPS تمنع نداء HTTP
  ///   (mixed content) فيُعرض «تحقق من الإنترنت» والسيرفر يعمل.
  ///   فنسخة الويب تمر عبر بروكسي Netlify بنفس النطاق
  ///   (`/wa/api/...` → السيرفر) — انظر `netlify.toml` في جذر المشروع.
  ///   والتطبيق المحلي (localhost صفحة HTTP) يبقى على النداء المباشر.
  static const String _directBaseUrl = 'http://162.35.126.155';

  static bool get _useWebProxy => kIsWeb && Uri.base.scheme == 'https';

  static String get baseUrl =>
      _useWebProxy ? Uri.base.origin : _directBaseUrl;

  /// مسار النقطة: على الويب HTTPS يُسبق بـ`/wa` ليمر عبر البروكسي.
  static String _endpoint(String path) => _useWebProxy ? '/wa$path' : path;

  /// ★★ مفتاح الـAPI مُجزّأ (لا نص صريح في التطبيق).
  /// ⚠️ أي مفتاح داخل حزمة عميلة يمكن استخراجه نظرياً، فحمايته
  ///   الحقيقية: **غيّر المفتح على الخادم + تقييد الـIP +ssl**.
  ///   التجزئة هنا توقف الاستخراج المباشر بـ`strings` فقط.
  static final String apiKey = Secrets.realtimeApiKey;

  /// طول الكود المُرسل من السيرفر.
  static const int codeLength = 4;

  /// مهلة الطلب الواحد.
  static const Duration _timeout = Duration(seconds: 20);

  static final http.Client _http = http.Client();

  static Map<String, String> get _headers => {
    'x-api-key': apiKey,
    'Content-Type': 'application/json',
  };

  /// يطلب من السيرفر إرسال كود تحقق إلى الرقم.
  Future<WhatsappSendResult> sendCode(String normalizedPhone) async {
    try {
      final res = await _http
          .post(
            Uri.parse('$baseUrl${_endpoint('/api/auth/code')}'),
            headers: _headers,
            body: jsonEncode({'phone': normalizedPhone}),
          )
          .timeout(_timeout);

      final body = _decode(res);
      if (res.statusCode == 200 && body['ok'] == true) {
        return const WhatsappSendResult(ok: true);
      }

      final error = body['error']?.toString() ?? 'server_error';
      var retryAfter = 0;
      final raw = body['retryAfter'];
      if (raw is num) retryAfter = raw.toInt();
      return WhatsappSendResult(ok: false, error: error, retryAfter: retryAfter);
    } catch (_) {
      return const WhatsappSendResult(ok: false, error: 'network_error');
    }
  }

  /// يتحقق من الكود المُدخل ويعيد توكن الدخول.
  Future<WhatsappVerifyResult> verifyCode(
    String normalizedPhone,
    String code,
  ) async {
    try {
      final res = await _http
          .post(
            Uri.parse('$baseUrl${_endpoint('/api/auth/verify')}'),
            headers: _headers,
            body: jsonEncode({'phone': normalizedPhone, 'code': code}),
          )
          .timeout(_timeout);

      final body = _decode(res);
      if (res.statusCode == 200 && body['ok'] == true) {
        return WhatsappVerifyResult(ok: true, token: body['token']?.toString());
      }

      final error = body['error']?.toString() ?? 'server_error';
      final left = body['attemptsLeft'];
      return WhatsappVerifyResult(
        ok: false,
        error: error,
        attemptsLeft: left is num ? left.toInt() : null,
      );
    } catch (_) {
      return const WhatsappVerifyResult(ok: false, error: 'network_error');
    }
  }

  Map<String, dynamic> _decode(http.Response res) {
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// ترجمة أخطاء السيرفر إلى جمل عربية مفهومة.
  static String describe(String? error, {int? attemptsLeft}) {
    switch (error) {
      case 'cooldown':
        return 'طلبات كثيرة، انتظر قليلاً ثم أعد المحاولة';
      case 'phone_limit':
        return 'وصلت للحد الأقصى للكودات على هذا الرقم، حاول بعد ساعة';
      case 'server_limit':
        return 'الخدمة مشغولة حالياً، حاول بعد قليل';
      case 'number_not_on_whatsapp':
        return 'هذا الرقم غير موجود على واتساب';
      case 'invalid_phone':
        return 'رقم الهاتف غير صحيح';
      case 'no_code':
        return 'لم يُرسل كود لهذا الرقم، اطلب كوداً جديداً';
      case 'expired':
        return 'انتهت صلاحية الكود، اطلب كوداً جديداً';
      case 'wrong_code':
        return attemptsLeft != null
            ? 'الكود غير صحيح، بقي $attemptsLeft محاولة'
            : 'الكود غير صحيح';
      case 'too_many_attempts':
        return 'محاولات كثيرة خاطئة، اطلب كوداً جديداً';
      case 'network_error':
        return 'تعذّر الاتصال بالسيرفر، تحقق من الإنترنت';
      case 'whatsapp_not_connected':
        return 'واتساب غير مربوط حالياً، أعد ربطه من لوحة السيرفر';
      case 'send_timeout':
      case 'check_timeout':
        return 'السيرفر بطيء، أعد المحاولة';
      case 'send_failed':
        return 'فشل الإرسال، أعد المحاولة';
      case 'server_error':
        return 'خطأ في السيرفر، أعد المحاولة بعد قليل';
      default:
        return 'حدث خطأ غير متوقع، أعد المحاولة';
    }
  }
}
