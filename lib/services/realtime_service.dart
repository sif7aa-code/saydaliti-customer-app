import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/secrets.dart';
import 'auth_service.dart';

/// أسماء أحداث البث — مطابقة لـ `src/events.js` في السيرفر.
class RtEvent {
  static const orderNew = 'order.new';
  static const orderStatus = 'order.status';
  static const priceChanged = 'price.changed';
  static const productChanged = 'product.changed';
  static const productDeleted = 'product.deleted';
  static const orderItemRemoved = 'order.item_removed';
  static const brandChanged = 'brand.changed';
  static const waState = 'wa.state';
  static const qr = 'wa.qr';

  static const all = <String>[
    orderNew,
    orderStatus,
    priceChanged,
    productChanged,
    productDeleted,
    orderItemRemoved,
    brandChanged,
    waState,
    qr,
  ];
}

/// حدث واحد وصل من السيرفر.
class RealtimeEvent {
  const RealtimeEvent(this.topic, this.data);

  final String topic;
  final Map<String, dynamic> data;
}

/// قناة بث فوري من سيرفر qrlogn، بدل استطلاع Supabase كل 3 ثوانٍ.
///
/// لماذا: الاستطلاع له حدّ أدنى (3 ثوانٍ) لا يُتسارع إلا بحرق البطارية.
/// البث يُوصّل الحدث خلال ~100 مللي بعد كشفه على السيرفر (≤ ثانيتين).
///
/// عند انقطاع البث لا يسقط شيء: [isConnected] يصبح false، فيعود
/// `NotificationCenter` إلى الاستطلاع — بلا فجوة إشعارات.
class RealtimeService {
  RealtimeService._();
  static final RealtimeService instance = RealtimeService._();

  static const String host = 'http://162.35.126.155';

  // ★★ مفتاح الـAPI مُجزّأ — لا نص صريح عند فكّ ضغط التطبيق.
  /// ⚠️ التجزئة توقف `strings` فقط. الحماية الحقيقية: تغيير المفتاح
  ///   على الخادم (`NOTIFY_API_KEY`) + تقييد الـIP + HTTPS.
  static final String apiKey = Secrets.realtimeApiKey;

  final StreamController<RealtimeEvent> _controller =
      StreamController<RealtimeEvent>.broadcast();

  http.Client? _client;
  StreamSubscription<String>? _lines;
  Timer? _retry;
  Timer? _keepAlive;

  /// ★★ حارس الحياة.
  ///
  /// المشكلة التي يحلّها: على شبكات الجوال يُقطع الاتصال الطويل
  /// **بلا أي إشعار** — لا `onDone` ولا `onError`، والمقبس يبدو حيّاً
  /// فيبقى `_connected = true` إلى الأبد. والمركز يقرأ هذه العلامة
  /// ويخفّض الاستطلاع إلى ٣/٤ ثوانٍ «لأن البث يأتي الفوري» ⇒ لا هذا
  /// ولا ذاك: إشعارات تتأخر دقائق بلا أي خطأ في السجلّات.
  ///
  /// الحل: نعتمد على نبضة الخادم (`: ping` كل ١٠ ثوانٍ في `hub.js`)
  /// فنقيس **آخر رزمة فعلية** لا حالة المقبس. إن صمتت أكثر من
  /// [_staleAfter] ⇒ الاتصال ميت: نطويه، نعيد المحاولة فوراً
  /// (بلا تدرّج)، ونُعلم مركز الإشعارات فيسحب الآن ويعود لثانية.
  DateTime _lastByteAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _watchdog;

  static const Duration _staleAfter = Duration(seconds: 35);
  static const Duration _watchdogEvery = Duration(seconds: 10);

  /// ★ يُنادى عند أي تغيّر في حياة البث: انقطاع صامت، انقطاع معلن،
  ///   أو عودة. مركز الإشعارات يستعمله ليفحص فوراً ويعيد ضبط الوتيرة.
  void Function()? onLiveness;

  String? _phone;
  String? _rolesKey;
  int _attempt = 0;
  bool _running = false;
  bool _connected = false;

  Stream<RealtimeEvent> get events => _controller.stream;

  /// هل البث متصل **وفعّال** الآن؟ (عنده فقط يُخفَّف الاستطلاع)
  ///
  /// ★ ليست `_connected` الخام: النبضة يجب أن تكون وصلت مؤخراً.
  bool get isConnected =>
      _connected &&
      DateTime.now().difference(_lastByteAt) < _staleAfter;

  /// آخر نبضة/حدث فعلي — للتشخيص في اللوحة والاختبارات.
  DateTime get lastByteAt => _lastByteAt;

  static const Duration _baseBackoff = Duration(seconds: 3);
  /// ★ كان الحد ٦٠ ثانية: بعد انقطاع ليلي طويل كان الجهاز ينتظر دقيقة
  ///   كاملة قبل إعادة محاولة البث، فلا يصله أي طلب في تلك الدقيقة
  ///   (يبقى على الاستطلاع وحده). خُفّض إلى ١٥ ⇒ تسلسل ٣/٦/١٢/١٥ ثوانٍ.
  static const Duration _maxBackoff = Duration(seconds: 15);
  static const Duration _recycleAfter = Duration(minutes: 30);

  /// ★ إعادة محاولة البث **الآن** — تُستدعى عند العودة للمقدمة.
  ///
  /// بدونها: التطبيق في الخلفية ينخفض البث ثم يقطع، وعند الفتح يبقى
  /// مؤقّت إعادة المحاولة (٣..١٥ ثانية) يعمل بلا مُلمِس، فمتأخر أول
  /// حدث بعد الفتح. هنا نلغي المؤقّت ونعيد الاتصال فوراً.
  void retryNow() {
    if (!_running || _phone == null) return;
    if (_connected) return;
    _retry?.cancel();
    _retry = null;
    _attempt = 0;
    _dropConnection();
    _connect();
  }

  /// يبدأ البث لهذا الحساب. آمن للاستدعاء المتكرر.
  void start({String? phone, String? roles}) {
    final target = phone ?? AuthService.instance.phone;
    if (target == null || target.isEmpty) return;
    final rolesKey = roles ?? _rolesFor();
    if (_running && _phone == target && _rolesKey == rolesKey) return;

    _teardown();
    _phone = target;
    _rolesKey = rolesKey;
    _running = true;
    _attempt = 0;
    _connect();
  }

  /// ★★ ما رُصد على الخادم (٢٠٢٦-١٠-٢٨، سجل `notify.log`): الرقم
  ///   `07870335759` فتح **أربعة** اشتراكات SSE في ١٢ مللي ثانية.
  ///   السبب أن `client.send()` مستقبلٌ لم يُنتظر: لو بدأت محاولة
  ///   جديدة قبل ردّ الأولى، فإن `_dropConnection` تُغلق العميل
  ///   المسجَّل حالياً فقط، ثم يردّ الردّ القديم ويجد `_running`
  ///   صحيحة فيبدأ قارئَين على تدفقين، ولا يبقى في `_lines` سوى
  ///   الأخير ⇒ التدفقات الأخرى حيّة بلا مالك: لا تُقطع أبداً،
  ///   وتستهلك بطارية الجهاز وعداد الاشتراكات على السيرفر.
  ///
  /// العلاج: كل محاولة اتصال تحمل جيلاً؛ أي ردّ يصل لجيل غير
  /// الحالي يُغلق ويُهمَل بلا أي أثر.
  int _generation = 0;

  void _connect() {
    if (!_running || _phone == null) return;
    final gen = ++_generation;

    final uri = Uri.parse('${host.replaceAll(RegExp(r'/$'), '')}/api/realtime'
        '?phone=${Uri.encodeQueryComponent(_phone!)}'
        '&roles=${Uri.encodeQueryComponent(_rolesKey ?? 'customer')}');

    final client = http.Client();
    _client = client;

    // نبضة إبقاء + إعادة بناء دورية: الوسطاء يقتلون الاتصال الطويل،
    // ولا يمرّروا نبضة بعد فترة. البناء أرخص من اكتشاف انقطاع متأخر.
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(
      _recycleAfter,
      (_) {
        if (_running) {
          _dropConnection();
          _connect();
        }
      },
    );

    final request = http.Request('GET', uri)
      ..headers['x-api-key'] = apiKey
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';

    client.send(request).then((response) {
      // ★ ردّ لجيل مُتجاوز ⇒ يُغلق في صمت.
      if (!_running || gen != _generation) {
        client.close();
        return;
      }
      if (response.statusCode != 200) {
        _scheduleRetry();
        return;
      }
      _connected = true;
      _lastByteAt = DateTime.now();
      _attempt = 0;
      _startWatchdog();
      onLiveness?.call();
      _read(response.stream);
    }).catchError((Object _) {
      if (_running && gen == _generation) _scheduleRetry();
    });
  }

  /// ★ حارس الصمت: كل [_watchdogEvery] يقارن آخر رزمة بـ[_staleAfter].
  ///
  /// لا ينتظر `onDone` — ذلك هو بالضبط ما لا يحدث في القطع الصامت.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(_watchdogEvery, (_) {
      if (!_running || !_connected) return;
      if (DateTime.now().difference(_lastByteAt) < _staleAfter) return;
      _retry?.cancel();
      _attempt = 0;
      _dropConnection();
      onLiveness?.call();
      _connect();
    });
  }

  void _read(Stream<List<int>> stream) {
    String? event;
    final data = <String>[];

    _lines = stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        // ★ أي سطر = الاتصال حيّ. نبضات `: ping` من الخادم تدخل هنا
        //   رغم أننا نتخطاها، فهي وحدها ما يُبقي الحارس هادئاً.
        _lastByteAt = DateTime.now();
        if (line.isEmpty) {
          _emit(event, data);
          event = null;
          data.clear();
          return;
        }
        if (line.startsWith(':')) return;
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).trim());
        }
      },
      onDone: () {
        _connected = false;
        onLiveness?.call();
        if (_running) _scheduleRetry();
      },
      onError: (Object _) {
        _connected = false;
        onLiveness?.call();
        if (_running) _scheduleRetry();
      },
      cancelOnError: true,
    );
  }

  void _emit(String? event, List<String> data) {
    if (event == null || data.isEmpty) return;
    if (event == 'hello') return;
    if (!RtEvent.all.contains(event)) return;
    try {
      final decoded = jsonDecode(data.join('\n'));
      if (decoded is Map) {
        _controller.add(RealtimeEvent(event, Map<String, dynamic>.from(decoded)));
      }
    } catch (_) {
      // إطار تالف: نتجاهله بدل كسر البث كله.
    }
  }

  String _rolesFor() {
    final a = AuthService.instance;
    final r = <String>['customer'];
    if (a.isDriver) r.add('driver');
    if (a.isAdmin) r.add('admin');
    if (a.isShopOwner) r.add('shop_owner');
    return r.join(',');
  }

  void _scheduleRetry() {
    final wasUp = _connected;
    _dropConnection();
    if (wasUp) onLiveness?.call();
    if (!_running) return;
    _retry?.cancel();
    _attempt = (_attempt + 1).clamp(1, 6);
    final ms = _baseBackoff.inMilliseconds * (1 << (_attempt - 1));
    _retry = Timer(
      Duration(
        milliseconds: ms > _maxBackoff.inMilliseconds
            ? _maxBackoff.inMilliseconds
            : ms,
      ),
      _connect,
    );
  }

  void _dropConnection() {
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_lines?.cancel());
    _lines = null;
    _client?.close();
    _client = null;
    _connected = false;
  }

  void _teardown() {
    _running = false;
    _retry?.cancel();
    _retry = null;
    _keepAlive?.cancel();
    _keepAlive = null;
    _watchdog?.cancel();
    _watchdog = null;
    _dropConnection();
  }

  void stop() {
    _teardown();
    _phone = null;
    _rolesKey = null;
    _attempt = 0;
  }

  /// يُستدعى عند تبديل الحساب أو الخروج.
  void reset() {
    stop();
    _attempt = 0;
  }
}
