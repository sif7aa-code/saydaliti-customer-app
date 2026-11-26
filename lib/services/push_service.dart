import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/firebase_web.dart';
import '../core/utils/account_name.dart';
import 'auth_service.dart';
import 'device_sound.dart';
import 'fcm_background_handler.dart';
import 'fcm_router.dart';
import 'notification_center.dart';
import 'notification_dedup.dart';
import 'realtime_service.dart';
import 'status_center.dart';
import 'supabase_service.dart';

/// إشعارات Firebase (FCM) — الاستقبال داخل التطبيق.
///
/// ملاحظة: الإرسال يتم من السيرفر (Service Account) أو من لوحة Firebase.
/// هذا الملف يهيّئ الاستقبال:
///  - يطلب إذن الإشعارات (أندرويد 13+).
///  - يسجّل توكن الجهاز في حساب المستخدم داخل Supabase (عمود fcm_token).
///  - يعرض الإشعار فوراً فوق أي شاشة أثناء تشغيل التطبيق.
///  - يعالج الإشعارات التي تصل والتطبيق مغلق (في الخلفية).
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const String _kToken = 'fcm_token_v1';

  /// آخر (توكن|قناة) أُبلغ بهما السيرفر — فلا إعادة إرسال بلا تغيير.
  static const String _kSoundSynced = 'fcm_sound_synced_v1';

  bool _ready = false;
  String? _token;

  /// هل تم تهيئة Firebase بنجاح.
  bool get isReady => _ready;

  /// آخر توكن جهاز (يصلح للاختبار والإرسال من السيرفر).
  String? get token => _token;

  /// هل مدعوم على هذا الجهاز (أندرويد/آيفون/الويب).
  static bool get isSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// تهيئة Firebase. آمنة عند التكرار، ولا تُسقط التطبيق عند الفشل
  /// (مثلاً بدون google-services.json).
  ///
  /// ★ الويب يحتاج إعداداً صريحاً: لا يوجد `google-services` في المتصفح،
  ///   و`initializeApp()` بلا خيارات ترمي. فيُمرَّر [FirebaseWebConfig.options]
  ///   (مشروع diqarapp) والتوكنات تُرسل من السيرفر بمفتاح الخدمة نفسه.
  Future<void> init() async {
    if (_ready) return;
    // ★ آيفون يمرّ بـFirebase الآن: تطبيق iOS مسجّل في مشروع `diqarapp`
    //   ومعه `GoogleService-Info.plist`، فالتهيئة تقرأه من الحزمة.
    //   وإن غاب الملف (بناء قديم أو تجريبي) تُرمى استثناءات هنا وتُلتقط
    //   فتبقى `isReady=false`، وعندها يستعمل `main` جسر APNs المباشر.
    try {
      await Firebase.initializeApp(
        options: kIsWeb ? FirebaseWebConfig.options : null,
      );
      _ready = true;
    } catch (e) {
      _ready = false;
      if (kDebugMode) print('Firebase init failed: $e');
    }
  }

  /// يبدأ الاستقبال: الإذن + معالجة الرسائل + تسجيل التوكن.
  Future<void> start() async {
    if (!isSupported) return;
    await init();
    if (!_ready) return;

    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (kDebugMode) {
        // ignore: avoid_print
        print('FCM permission: ${settings.authorizationStatus}');
      }
    } catch (e) {
      if (kDebugMode) print('FCM permission error: $e');
    }

    // رسالة تصل والتطبيق مغلق/مُقتل ⇒ معالج الخلفية المستقل
    // (دالة top-level في ملفها الخاص، سجّلناها في main قبل runApp).
    // إعادة التسجيل هنا آمنة وتغطي أي احتمال أن تسبقها main.
    // ★ على الويب لا يوجد «معالج خلفية» بهذا المعنى: الإشعار يعرضه
    //   عامل الخدمة `firebase-messaging-sw.js` في المتصفح.
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(fcmBackgroundMessageHandler);
    }

    // رسالة والتطبيق مفتوح.
    FirebaseMessaging.onMessage.listen(_onMessage);

    // الضغط على الإشعار.
    FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpened);

    // ══ بدء التشغيل من إشعار (Terminated / Killed State) ══
    // `getInitialMessage` هي القناة الوحيدة التي تعطي رسالة الإشعار
    // الذي فُتح منه التطبيق بعد أن كان مقفلاً/مُقتلاً. نمرّرها مرة واحدة
    // فقط إلى `_onMessageOpened` (وهي بدورها توجّه عبر FcmRouter).
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _onMessageOpened(initial);
    } catch (e) {
      if (kDebugMode) print('FCM initial message error: $e');
    }

    await _registerToken();

    // تغيّر التوكن (إعادة تسجيل / حذف التطبيق).
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      unawaited(_saveToken(newToken));
    });
  }

  /// إشعار والتطبيق مفتوح/في الخلفية: نعرضه فوق الشاشة عبر مركز الحالات،
  /// أو كإشعار نظام حقيقي بصوت القناة وشعار الحساب إذا كان في الخلفية.
  ///
  /// مهم: لا نكتب الإشعار مرة أخرى في Supabase — الإشعار جاء أصلاً
  /// من جدول notifications، ولو أعدنا كتابته لدخلنا في حلقة لا نهائية
  /// (worker ← push ← app ← write ← worker ← …).
  void _onMessage(RemoteMessage message) {
    unawaited(_handleMessage(message));
  }

  Future<void> _handleMessage(RemoteMessage message) async {
    // ★★ «عند تسجيل الخروج لا تُرسَل إشعارات»: شاشة الدخول تعني أن
    //   صاحب الحساب خرج من التطبيق، فأي دفعة تصل الآن هي لحسابٍ لا
    //   يريده أحد على هذا الجهاز — تُطرَد بلا عرض وبلا صوت وبلا حجز
    //   في سجلّ المنع (فلا تُسكِت إشعار الحساب الذي سيسجّل بعده).
    if (!AuthService.instance.isLoggedIn) return;

    // ★★ الفورية المزدوجة: وصول رسالة FCM يعني أن الصف كُتب للتو في
    //   الطابور، وغالباً له أشقاء (صف الحالة + صفوف البنود + صفوف
    //   المندوبين). نفحص **الآن** بدل انتظار الدورة، والبوابة الموحّدة في
    //   `NotificationDedup` تضمن أن قناة واحدة فقط تعرض، بصوت واحد.
    NotificationCenter.instance.scanNow();

    final data = message.data;
    final title =
        (message.notification?.title ?? data['title'] ?? '').toString().trim();
    final body =
        (message.notification?.body ?? data['body'] ?? '').toString().trim();
    if (title.isEmpty && body.isEmpty) return;

    final orderId = data['orderId']?.toString();
    final status = data['status']?.toString();
    final link = (data['link'] ?? '').toString().trim();
    // ★★ نوع الصفّ (`type`) من الخادم هو أساس المفتاح — لا الحالة:
    //   صفوف الجديد/الإرجاع اسمها `new_order` و`reopened` في جدول
    //   notifications، فلو بنينا المفتاح من اسم الحالة لظهر مفتاح
    //   ثانٍ لا يطابق ما يبنيه الاستطلاع ⇒ الإشعار مرتين.
    final rowType = (data['type']?.toString().trim() ?? '').isNotEmpty
        ? data['type']!.toString().trim()
        : status;

    // ★★ شعار الحساب وحده — ولا بديل ولا بديل مشترك.
    //   كان `bigImage` من السيرفر بديلاً: وهو في `push-worker` إمّا
    //   شعار الحساب **المُرسَل إليه** (وهو يحتاجه) أو `app_icon.png`
    //   المشتركة، فكان حساب بلا صورته يعرض شعار غيره. الآن الإشعار
    //   يحمل شعار صاحبه فقط، ومن لا شعار له فبلا صورة كبيرة.
    // ★ استثناء الدردشة: الشعار المطلوب هو شعار **الطرف الآخر**
    //   (المُرسِل) الذي يضعه الخادم في صورة الإشعار؛ وشعار المستقبِل
    //   هنا سيعرض صورة نفسه أمام رسالة غيره.
    final logo = rowType == 'chat'
        ? (message.notification?.android?.imageUrl ??
            message.notification?.apple?.imageUrl ??
            message.notification?.web?.image ??
            '')
        : NotificationCenter.instance.brandImage;
    final sound = data['sound']?.toString() ?? status;

    // ★★ توحيد: المفتاح يُبنى بـNotificationDedup.keyFor — وهو المعيار
    //   الوحيد — لا يدوياً، وهو نفسه ما يبنيه الاستطلاع.
    //   ★ بلا معرّف طلب يُستعمل `rowId` الذي يرسله الخادم (معرّف صف
    //   الإشعار) لا `messageId`: الاستطلاع يبني المفتاح من معرّف الصف،
    //   فمفتاحان مختلفان لصف واحد ⇒ بطاقتان لحدث واحد (حجز العيادة مثلاً).
    final rowId = (data['rowId'] ?? '').toString().trim();
    final dedupeKey = (orderId == null || orderId.isEmpty)
        ? NotificationDedup.keyFor(
            type: rowType,
            rowId: rowId.isNotEmpty ? rowId : message.messageId,
          )
        : NotificationDedup.keyFor(orderId: orderId, type: rowType);

    // ★★ الحجز **قبل** أي عرض وبانتظار نتيجته: إن كان الصفّ قد
    //   حُجز (عرضه الاستطلاع أو وصل نسخة أخرى) لا نعرض شيئاً —
    //   صوت واحد واهتزاز واحد لكل حدث مهما تعددت المسارات.
    if (!await NotificationDedup.claim(dedupeKey)) return;

    // في الخلفية: نظام FCM يعرض الإشعار بصوت قناته بنفسه (بلا صورة)،
    // فيكفي الحجز أعلاه حتى لا يكرّره الاستطلاع بعد ثوانٍ.
    if (!NotificationCenter.instance.isForeground) {
      StatusCenter.claimOnce(dedupeKey);
      return;
    }

    unawaited(
      StatusCenter.instance.broadcast(
        title: title.isEmpty ? 'إشعار جديد' : title,
        body: body,
        status: status,
        orderId: orderId,
        imageUrl: logo,
        sound: sound,
        dedupeKey: dedupeKey,
        // ★ علامة داخلية (شاشة الموافقات/حجوزاتي) أو دردشة — لا رابط خارجي.
        onTap: link == 'appointments'
            ? () => NotificationCenter.onAppointmentsTap?.call()
            : (link == 'bookings'
                  ? () => NotificationCenter.onBookingsTap?.call()
                  : (link.startsWith('chat:')
                        ? () => NotificationCenter.onChatTap?.call(link)
                        : null)),
      ),
    );
  }

  /// الضغط على الإشعار:
  ///  - إن كان يحمل orderId ⇒ الموجّه يفتح شاشة التتبع داخل التطبيق
  ///    (هذا هو مسار البدء من إشعار والتطبيق مغلق).
  ///  - وإلا ومع وجود رابط ⇒ نفتحه خارجياً.
  void _onMessageOpened(RemoteMessage message) {
    unawaited(FcmRouter.instance.onNotificationTapped(message));

    final hasOrder = (message.data['orderId'] ?? '').toString().trim().isNotEmpty;
    if (hasOrder) return;

    final link = message.data['link']?.toString().trim() ?? '';
    // ★ علامة داخلية (شاشة الموافقات/حجوزاتي) أو دردشة فتحها الموجّه
    //   أعلاه — فلا نحاول فتحها في المتصفح.
    if (link.isEmpty ||
        link == 'appointments' ||
        link == 'bookings' ||
        link.startsWith('chat:')) {
      return;
    }
    final uri = Uri.tryParse(link.startsWith('http') ? link : 'https://$link');
    if (uri == null) return;
    unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
  }

  /// يسجّل توكن الجهاز في حساب المستخدم (يُستعمل للإرسال من السيرفر).
  ///
  /// ★ الويب يحتاج مفتاح VAPID علناً عند طلب التوكن، وإلا رمى
  ///   `getToken` استثناءً فلا يُسجَّل أي جهاز ويبقى المتصفح أصمّ.
  Future<void> _registerToken() async {
    try {
      // ★ آيفون: توكن FCM لا يصدر قبل وصول توكن APNs من آبل؛ الطلب
      //   المبكر يرمي "APNS token has not been set yet" ثم يمرّ صامتاً
      //   فلا يُسجَّل الجهاز. ننتظر جهوز التوكن (حتى ~5 ثوانٍ) قبل الطلب.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        for (var i = 0; i < 10; i++) {
          try {
            final apns = await FirebaseMessaging.instance.getAPNSToken();
            if (apns != null && apns.isNotEmpty) break;
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      final token = await FirebaseMessaging.instance.getToken(
        vapidKey: kIsWeb ? FirebaseWebConfig.vapidKey : null,
      );
      if (token == null || token.isEmpty) return;
      await _saveToken(token);
    } catch (e) {
      if (kDebugMode) print('FCM getToken error: $e');
    }
  }

  /// ضمان حفظ التوكن في السيرفر — يُستدعى عند كل فتح للتطبيق
  /// (يصلح لو حُذف الصف أو تغيّر الجهاز)، فيبقى التوكن محفوظاً دائماً.
  Future<void> ensureTokenSaved() async {
    if (!isSupported) return;
    await init();
    if (!_ready) return;
    await _registerToken();
  }

  /// يحفظ التوكن محلياً وفي حساب المستخدم (ول-device فقط).
  Future<void> _saveToken(String token) async {
    _token = token;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kToken, token);
    } catch (e) {
      if (kDebugMode) print('FCM local save error: $e');
    }
    // ★ نغمة هذا الهاتف: السيرفر يحتاج قناتها كي يرنّ الإشعار بصوت
    //   الاختيار والتطبيق مغلق (والنظام هو من يرسمه، لا التطبيق).
    //   رسالة واحدة عند التغيّر فقط — لا شيء في كل إشعار.
    unawaited(_syncSound(token));
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) return;
    try {
      final brand = await SupabaseService.instance.fetchNotificationBrand(phone);
      // ★★ الكتابة تُشترط بما **تغيّر فعلاً**، لا في كل عودة للتطبيق.
      //   `ensureTokenSaved` يعمل عند كل `resumed` (تبديل تطبيق، إطفاء
      //   الشاشة،…) ⇒ كان ٤ طلبات شبكة بلا داعٍ في كل مرة: رقمان
      //   PATCH/POST + قراءة العلامة + PATCH رابع.
      // ★ عنوانٌ حقيقي فقط: اللقب العام لا يُكتب في الحساب ولا يُرسل.
      final titleWanted =
          AccountName.isGeneric(brand.title) ? null : brand.title;
      // ★★ والتفعيل يُشترط بالرقم لا بالتوكن وحده: الخروج يُبطل صفّ
      //   الجهاز في `push_tokens` (`deactivate_own_push_tokens`)، والدخول
      //   من جديد **في نفس العملية** كان يمرّ بلا كتابة لأن التوكن لم
      //   يتغيّر ⇒ يبقى الصفّ `is_active=false`، والسيرفر لا يرسل FCM
      //   لصفّ معطّل ⇒ هاتف صامت عن إشعار الطلبات والتطبيق مغلق، ولا
      //   يرجع إلا بإغلاق التطبيق من المهام وفتحه.
      final tokenWanted = needsTokenWrite(
        token: token,
        phone: phone,
        savedToken: _savedRemoteToken,
        activatedPhone: _activatedPhone,
      )
          ? token
          : null;

      if (tokenWanted != null) {
        // 1) توكن الجهاز في حسابه (يبقى دائماً — لا نمسحه أبداً).
        //
        // ★★ كان `updateUser(phone, {'fcm_token': ...})` أي PATCH مباشر
        //   بـanon ⇒ يرد `42501 permission denied for table users`، فلا
        //   يُسجَّل أي جهاز ⇒ `push-api` يجد `tokens: 0` ⇒ لا إشعار
        //   إطلاقاً حتى والتطبيق مغلق.
        //
        //   الاستدعاء عبر دالة مخوّضة تتحقق أن الجلسة تخص نفس الرقم،
        //   فلا يستطيع أحد كتابة توكن لحساب غيره.
        await SupabaseService.instance.registerFcmToken(phone, tokenWanted);
        // 2) تسجيل الجهاز في جدول push_tokens (نفس التوكن لكل حساب).
        // ★ وسم المنصة يقرره السيرفر: المنصات الثلاث كلها تُرسل من
        //   مشروع diqarapp وحده (٢٠٢٦-١١-٢٤)، والوسم للصيغة فقط
        //   (ويب/أندرويد/آيفون) وللتشخيص.
        //   ★ آيفون يُوسم «ios» كي يرسل الخادم بصيغة APNs لا أندرويد.
        await SupabaseService.instance.registerPushToken(
          phone,
          tokenWanted,
          platform: kIsWeb
              ? 'web'
              : (defaultTargetPlatform == TargetPlatform.iOS
                  ? 'ios'
                  : 'android'),
        );
        _savedRemoteToken = tokenWanted;
        _activatedPhone = phone;
      }
      if (titleWanted != null && titleWanted != _savedRemoteTitle) {
        await SupabaseService.instance
            .updateUser(phone, {'notification_title': titleWanted});
        _savedRemoteTitle = titleWanted;
      }
      if (tokenWanted != null || titleWanted != _savedRemoteTitle) {
        NotificationCenter.instance.invalidateBrand();
      }
    } catch (e) {
      if (kDebugMode) print('FCM server save error: $e');
    }
  }

  Future<void> _syncSound(String token) async {
    // التحميل أولاً: قد يسبق `_saveToken` اكتمال `DeviceSound.load` عند
    // الإقلاع، وإرسال '' حينها يمحو ربط الجهاز بقناته على السيرفر.
    await DeviceSound.load();
    await syncSoundChannel(DeviceSound.channelId, token: token);
  }

  /// يربط توكن هذا الجهاز بقناة نغمته المحلية على سيرفر الإشعارات.
  ///
  /// لماذا على السيرفر: الإشعار والتطبيق مغلق يرسمه أندرويد عبر FCM،
  /// وصوته يقرأ من `channel_id` الذي يرسله السيرفر — لا يقرأ الهاتف
  /// قناته المحلية بنفسه. فيُرسَل الربط مرة واحدة عند تغيّر النغمة
  /// (أو تغيّر التوكن) ويُحفظ على القرص هناك، فلا رحلة لكل إشعار.
  ///
  /// فشل الشبكة غير ضار: يُعاد المحاولة عند أول فتح (`_saveToken`).
  Future<void> syncSoundChannel(String? channel, {String? token}) async {
    final t = (token ?? _token ?? '').trim();
    if (t.isEmpty) return;
    final ch = (channel ?? '').trim();
    final marker = '$t|$ch';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_kSoundSynced) == marker) return;
      final res = await http
          .post(
            Uri.parse('${RealtimeService.host}/api/sound'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': RealtimeService.apiKey,
            },
            body: jsonEncode({'token': t, 'channel': ch}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        await prefs.setString(_kSoundSynced, marker);
      }
    } catch (e) {
      if (kDebugMode) print('FCM sound sync error: $e');
    }
  }

  /// ★ التوكن والعنوان كما هما على الخادم آخر مرة — فيقارَن بهما قبل
  ///   الكتابة. ذاكرة فقط: أسوأ حالة هي كتابة زائدة مرّة عند الإقلاع.
  String? _savedRemoteToken;
  String? _savedRemoteTitle;

  /// ★ الرقم الذي فُعِّل توكنه آخر مرة — فالدخول بحساب (أو بنفس الحساب
  ///   بعد خروج) يعيد التفعيل ولو كان التوكن لم يتغيّر.
  String? _activatedPhone;

  /// هل يلزم كتابة التوكن على الخادم (تفعيل صفّ الجهاز)؟
  ///
  /// المعيار: تغيّر **التوكن** أو تغيّر **الحساب المفعَّل**. الثاني هو
  /// ما كان ناقصاً — الخروج يُبطل الصفّ في `push_tokens`، والدخول من جديد
  /// في نفس العملية يمرّ بالتوكن نفسه، فبقي الهاتف صامتاً عن FCM حتى
  /// يُقتل التطبيق ويُفتح.
  static bool needsTokenWrite({
    required String token,
    required String phone,
    String? savedToken,
    String? activatedPhone,
  }) =>
      savedToken != token || activatedPhone != phone;

  /// يُنسى ما كُتب على الخادم. يُستدعى عند الخروج وحذف الحساب: الخروج
  /// يُبطل صفّ الجهاز (`deactivate_own_push_tokens`)، فالدخول التالي —
  /// ولو في نفس العملية — يعيد تفعيله، وإلا بقي الهاتف صامتاً عن
  /// إشعارات FCM حتى يُقتل التطبيق ويُفتح من جديد.
  void forgetRegisteredToken() {
    _savedRemoteToken = null;
    _activatedPhone = null;
  }
}
