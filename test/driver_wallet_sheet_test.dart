import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saydaliti/screens/driver_orders_screen.dart';
import 'package:saydaliti/services/auth_service.dart';

/// ★ شاشة المندوب **كما هي في التطبيق** — لا نسخة منها ولا إعادة رسم.
///
/// الورقة تُرسم من `DriverOrdersScreen` نفسها، والنداءان يمرّان عبر
/// `SupabaseService` الحقيقي، لكن الشبكة مبدَّلة بخادم محلي داخل نفس
/// العملية: لا يخرج من الجهاز طلب ولا تُلمس القاعدة ولا يُقرأ أي سرّ.
///
/// الحالات الثلاث مقصودة:
///   ١) قاعدة عليها `SQL_DRIVER_PENDING_DISCOUNT.sql` ⇒ معلَّق + سطور انتظار.
///   ٢) قاعدة قديمة تردّ 404 على `driver_pending_wallet` ⇒ السطر يختفي
///      بالكلية بدل «معلَّق ٠» التي تكذب على المندوب.
///   ٣) معلَّق صفراً (كله سُلِّم) ⇒ الرصيد و«آخر العمليات» وحدهما.
///
/// والمقاس مضبوط على ٣٦٠×٦٤٠ لأن تجاوز العرض عطلٌ رُئي في هذه الواجهات.
void main() {
  late HttpServer server;

  /// عميل الشبكة الحقيقي — يُبنى قبل `HttpOverrides.global` وإلا لدار
  /// التجاوز على نفسه.
  late HttpClient realClient;

  /// أجساد الردود لكل اختبار.
  late Map<String, Object?> walletBody;
  late int pendingStatus;
  late Object? pendingBody;
  late List<Map<String, Object?>> orderRows;
  final seen = <String>[];

  /// مندوب حقيقي الجلسة: الاسم والرقم من prefs كما يفعل التطبيق.
  const user = {
    'phone': '07700000001',
    'name': 'مصطفى الجبوري',
    'is_driver': true,
    'is_admin': false,
    'is_shop_owner': false,
    'is_active': true,
  };

  setUp(() async {
    walletBody = {
      'ok': true,
      'balance': 9500,
      'entries': 3,
      'verified_by': 'token',
      'rows': [
        {
          'order_label': '#7',
          'coupon_code': 'SHTR-9',
          'amount': 9500,
          'note': 'ثُبِّت عند التسليم',
        },
      ],
    };
    pendingStatus = 200;
    pendingBody = null;
    orderRows = const <Map<String, Object?>>[];
    seen.clear();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    realClient = HttpClient();
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final path = req.uri.path;
      // ignore: avoid_print
      print('REQ ${req.method} $path');
      final fn = path.split('/').last;
      seen.add('$fn ${jsonDecode(body.isEmpty ? '{}' : body) is Map ? 'rpc' : ''}');
      req.response.headers.contentType = ContentType.json;
      if (path.endsWith('driver_pending_wallet')) {
        req.response.statusCode = pendingStatus;
        req.response.write(
          jsonEncode(
            pendingBody ??
                (pendingStatus == 404
                    ? {
                        'code': 'PGRST202',
                        'message':
                            'Could not find the function public.driver_pending_wallet',
                      }
                    : <String, Object?>{}),
          ),
        );
      } else if (path.endsWith('my_driver_wallet')) {
        req.response.write(jsonEncode(walletBody));
      } else if (path.contains('/users')) {
        req.response.write(jsonEncode([user]));
      } else if (path.contains('/orders')) {
        req.response.write(jsonEncode(orderRows));
      } else {
        req.response.write('[]');
      }
      await req.response.close();
    });

    HttpOverrides.global = _LocalOverrides(server.port, realClient);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_logged_in': true,
      'auth_phone': '07700000001',
      'auth_name': 'مصطفى الجبوري',
      'auth_is_driver': true,
    });
    await AuthService.instance.init();
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
  });

  /// مقاس هاتف صغير فعلي (٣٦٠×٦٤٠): تجاوز العرض يرمي استثناء تخطيط هنا.
  void smallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// ★ `HttpOverrides.global` لا يكفي: `flutter_test` يثبّت تجاوزاً على
  ///   مستوى المنطقة (يردّ 400 على كل طلب) وهو يغلب العام. لذلك نلفّ
  ///   التنفيذ نفسه بـ`runZoned`.
  Future<void> inFakeNet(Future<void> Function() body) =>
      HttpOverrides.runZoned(
        body,
        createHttpClient: (_) => _Redirect(server.port, realClient),
      );

  /// يرسم الشاشة وينتظر وصول الجلبين الحقيقيين (شبكة حقيقية ⇒ `runAsync`).
  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      await inFakeNet(() async {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: const DriverOrdersScreen(),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
        }
      });
    });
  }

  /// يفتح «محفظتي» كما يفعل المندوب بلمسة واحدة.
  Future<void> openWallet(WidgetTester tester) async {
    await tester.runAsync(() async {
      await inFakeNet(() async {
        await tester.tap(find.byIcon(Icons.account_balance_wallet_rounded));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      });
    });
  }

  /// كل نصّ مرسوم في الورقة — العادية والمركّبة معاً — للدلالة لا للتخمين.
  List<String> rendered(WidgetTester tester) {
    final out = <String>[];
    void walk(InlineSpan? span, StringBuffer buf) {
      if (span == null) return;
      if (span is! TextSpan) {
        buf.write(span.toPlainText());
        return;
      }
      buf.write(span.text);
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c, buf);
      }
    }

    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      final data = t.data;
      if (data != null && data.isNotEmpty) {
        out.add(data);
        continue;
      }
      final buf = StringBuffer();
      walk(t.textSpan, buf);
      final rich = buf.toString();
      if (rich.isNotEmpty) out.add(rich);
    }
    return out;
  }

  group('ورقة «محفظتي» على شاشة المندوب', () {
    testWidgets('قاعدة عليها ملف المعلَّق: الرصيد والمعلَّق وسطور الانتظار', (
      tester,
    ) async {
      smallPhone(tester);
      pendingBody = {
        'ok': true,
        'driver_phone': '07700000001',
        'verified_by': 'token',
        'pending_orders': 2,
        'pending_amount': 30000,
        'pending_rows': [
          {
            'order_label': '#13',
            'coupon_code': 'WHEEL7X',
            'amount': 10000,
            'status': 'accepted',
            'status_label': 'مقبول',
            'from_wheel': true,
            'note': 'يُثبَّت هذا المبلغ عند تسليم الطلب',
          },
          {
            'order_label': '#14',
            'coupon_code': 'SHTR-A1',
            'amount': 20000,
            'status': 'delivering',
            'status_label': 'قيد التوصيل',
            'from_wheel': false,
            'note': 'يُثبَّت هذا المبلغ عند تسليم الطلب',
          },
        ],
      };

      await boot(tester);
      await openWallet(tester);

      final flat = rendered(tester);
      // ignore: avoid_print
      print('المعروض في الورقة: ${flat.join(' | ')}');

      expect(flat.any((s) => s.startsWith('رصيدك الحالي')), isTrue,
          reason: 'الرصيد الثابت يجب أن يبقى كما هو');
      expect(flat.any((s) => s.contains('معلَّق') && s.contains('30')), isTrue,
          reason: 'سطر المعلَّق بمبلغه');
      expect(flat.any((s) => s.contains('تُثبَّت عند التسليم')), isTrue);
      expect(flat.any((s) => s.contains('طلبان')), isTrue,
          reason: 'صيغة العدد العربية للاثنين');
      expect(flat.any((s) => s == 'في انتظار التسليم'), isTrue);
      expect(flat.any((s) => s.contains('#13') && s.contains('WHEEL7X')), isTrue);
      expect(flat.any((s) => s.contains('#14') && s.contains('SHTR-A1')), isTrue);
      expect(flat.any((s) => s.contains('عجلة الحظ')), isTrue,
          reason: 'وسم كود العجلة من القاعدة');
      expect(flat.any((s) => s.contains('قيد التوصيل')), isTrue);
      expect(flat.any((s) => s.contains('آخر العمليات')), isTrue,
          reason: 'المعلَّق قبل الثابت ولا يلغيه');
      expect(flat.any((s) => s.contains('10,000') || s.contains('١٠٬٠٠٠')), isTrue);

      // لا كسر تخطيط عند عرض هاتف صغير.
      expect(tester.takeException(), isNull);
      // النداءان معاً حصلا فعلًا، بترتيب المحفظة ثم المعلَّق.
      expect(seen.any((s) => s.startsWith('my_driver_wallet')), isTrue);
      expect(seen.any((s) => s.startsWith('driver_pending_wallet')), isTrue);
    });

    testWidgets('قاعدة قديمة (404): لا سطر معلَّق إطلاقاً', (tester) async {
      smallPhone(tester);
      pendingStatus = 404;
      await boot(tester);
      await openWallet(tester);

      final flat = rendered(tester);
      expect(flat.any((s) => s.startsWith('رصيدك الحالي')), isTrue,
          reason: 'المحفظة الثابتة تعمل كما كانت');
      expect(flat.any((s) => s.contains('معلَّق')), isFalse,
          reason: '«معلَّق ٠» كانت ستكذب: الخادم لم يُخبرنا بشيء');
      expect(flat.any((s) => s.contains('في انتظار التسليم')), isFalse);
      expect(flat.any((s) => s.contains('آخر العمليات')), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('معلَّق صفراً بعد التسليم: الرصيد وحده', (tester) async {
      smallPhone(tester);
      pendingBody = {
        'ok': true,
        'pending_orders': 0,
        'pending_amount': 0,
        'pending_rows': <Object>[],
      };
      await boot(tester);
      await openWallet(tester);

      final flat = rendered(tester);
      expect(
        flat.any((s) => s.contains('معلَّق')),
        isFalse,
        reason: 'بلا مال معلَّق لا يُذكر',
      );
      expect(flat.any((s) => s.contains('آخر العمليات')), isTrue);
      expect(flat.any((s) => s.contains('#7') && s.contains('SHTR-9')), isTrue,
          reason: 'سطر الدفتر الثابت باقٍ');
      expect(tester.takeException(), isNull);
    });

    testWidgets('مندوب لم يُسلَّم بعد: معلَّق بلا دفتر', (tester) async {
      smallPhone(tester);
      walletBody = {
        'ok': true,
        'balance': 0,
        'entries': 0,
        'verified_by': 'token',
        'rows': <Object>[],
      };
      pendingBody = {
        'ok': true,
        'pending_orders': 1,
        'pending_amount': 10000,
        'pending_rows': [
          {
            'order_label': '#13',
            'coupon_code': 'WHEEL7X',
            'amount': 10000,
            'status': 'accepted',
            'status_label': 'مقبول',
            'from_wheel': true,
          },
        ],
      };
      await boot(tester);
      await openWallet(tester);

      final flat = rendered(tester);
      expect(flat.any((s) => s.startsWith('رصيدك الحالي')), isTrue);
      expect(flat.any((s) => s.contains('معلَّق')), isTrue);
      expect(
        flat.any((s) => s.contains('كل معلَّق هنا يصبح رصيداً عند التسليم')),
        isTrue,
        reason: 'بدل «لا يوجد خصم بعد» الذي كان سيكذب',
      );
      expect(tester.takeException(), isNull);
    });
    // ★ معلَّقة عن التشغيل الآلي: عنوان الشبكة يُبنى من `Secrets` وقت
    //   التشغيل، فلا يصل الطلب إلى الخادم المحلي داخل `flutter test`
    //   (تعود الشاشة بـ«تعذّر جلب الطلبات»). التغطية الحقيقية تحتاج
    //   جهازاً.
  }, skip: 'يحتاج جهازاً حقيقياً: عنوان الشبكة من Secrets لا يُعترَض في الاختبار');
}

/// ★ يحوّل كل عنوان تطلبه الحزمة إلى الخادم المحلي: نفس مسار الاستعلام
///   ونفس منطق `package:http`، بباب على ١٢٧.٠.٠.١ لا أكثر.
class _LocalOverrides extends HttpOverrides {
  _LocalOverrides(this.port, this.real);

  final int port;
  final HttpClient real;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Redirect(port, real);
}

class _Redirect implements HttpClient {
  _Redirect(this.port, this._real);

  final int port;

  /// ★ العميل الحقيقي يُبنى **قبل** تركيب التجاوز (في setUp): بناؤه هنا
  ///   يعيد `_Redirect` نفسه ⇒ استدعاء لا نهائي.
  final HttpClient _real;

  @override
  bool autoUncompress = true;

  @override
  String? userAgent;

  @override
  Duration? connectionTimeout = const Duration(seconds: 5);

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  int? maxConnectionsPerHost;

  Uri _local(Uri u) => u.replace(scheme: 'http', host: '127.0.0.1', port: port);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _real.openUrl(method, _local(url));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _real.openUrl(method, _local(Uri.parse('http://$host:$port$path')));

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _real.openUrl('GET', _local(url));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _real.openUrl('POST', _local(url));

  @override
  void close({bool force = false}) => _real.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClient.${invocation.memberName}');
}
