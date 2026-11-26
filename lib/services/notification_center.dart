import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_service.dart';
import 'background_poller.dart';
import 'chat_service.dart';
import 'notification_dedup.dart';
import 'notification_history.dart';
import 'notification_sound.dart';
import 'real_data_service.dart';
import 'realtime_service.dart';
import 'status_center.dart';
import 'supabase_service.dart';
import 'system_notification.dart';
import 'tab_refresh.dart';

/// مركز إشعارات يعمل على مستوى التطبيق كله:
/// يراقب إشعارات المستخدم (الخاصة والعامة) ويعرض أي الجديد فوراً
/// على أي شاشة، مع النغمة وفتح الرابط عند الضغط.
///
/// ثلاث قواعد مهمة:
///  1) كل إشعار يحمل شعار الحساب الحالي (شعار خاص بكل حساب).
///  2) لا يُنطق ولا يُنبه على إشعارات قديمة عند فتح التطبيق: نحفظ
///     «آخر لحظة تنبيهنا» لكل حساب فلا نعيد تنبيه القديم ولا يتكرر الصوت.
///  3) في الخلفية ⇒ إشعار نظام؛ إن أرسله السيرفر عبر FCM نتخطّاه
///     (لأن نظام التشغيل عرضه)، وإلا عرضناه نحن بعد مهلة قصيرة.
class NotificationCenter {
  NotificationCenter._();

  static final NotificationCenter instance = NotificationCenter._();

/// فترات الاستطلاع.
  ///
  /// ★ الحقيقة المُتحقَّق منها من الخادم نفسه (فحص `/api/health`
  ///   ٢٠٢٦-١٠-٢٨): `fcmEnabled: true` و`fcmSent: 242` — أي أن
  ///   `notify.service` يرسل FCM فعلاً ويشمل المندوبين والأدمن
  ///   (فشل ٧ فقط). ما كان مكتوباً هنا سابقاً عن «لا FCM من الخادم»
  ///   كان يصف `push-worker` الموقوف، لا المسار الحيّ. فالمسارات
  ///   الثلاثة كلها تعمل: FCM للتطبيق المغلق، البث (SSE) للتطبيق
  ///   الحيّ، والاستطلاع شبكة أمان للثغرات بينهما.
  ///
  /// ★ لماذا يبقى الاستطلاع إذن؟ لأن كل قناة منها تسقط بصمت:
  ///   · البث يقطعه وسطاء الشبكة بلا إعلان ⇒ حارس الحياة في
  ///     `RealtimeService` يكشفه خلال ٣٥ ثانية، وبلا استطلاع سريع
  ///     تضيع الإشعارات في تلك النافذة.
  ///   · FCM يتأخر على البطاريات المقيدة (Doze) ولا يصل لأجهزة بلا
  ///     خدمات Google.
  ///   · صفوف تُكتب في القاعدة من دوال (أكواد الخصم، العجلة،
  ///     الإعلانات) لا يمرّ بها المُرسِل.
  ///   فأسوأ حال مضمون الآن: **ثانيتان** في الأمامية و**أربع** في
  ///   الخلفية، والمجرى الفعلي (البث/FCM) أقل من ثانية.
  ///
  /// الاستهلاك: الطلب أرخص ما يكون (`get_my_notifications` يقصّ
  /// صفوف رقمك فقط)، والفارق بين ٤ ثوانٍ وثانيتين لا يُذكر أمام
  /// وصول الطلب قبل أن يسبقه العميل إلى الشاشة.
  static const Duration _fgInterval = Duration(seconds: 3);
  static const Duration _bgInterval = Duration(seconds: 2);

  /// ★ الخلفية بلا بثّ لكن **مع توكن FCM**: ٣٠ ثانية بدل ثانيتين.
  ///
  ///   القياس (٢٠٢٦-١١-٠٩، `/api/health`): الخادم حيّ والبثّ يعمل، فأي
  ///   جهاز ينقطع بثّه في الخلفية كان يسأل القاعدة كل ثانيتين على مدار
  ///   الليل ⇒ ١٨٠٠ طلب/ساعة للهاتف النائم الواحد، وهو ما يملأ حصة
  ///   Egress وسجلات Supabase بلا إشعار واحد إضافي: الخادم يرسل FCM
  ///   خلال أقل من ثانية من الكتابة (ومعه نبضة `/api/poke` من الجهاز
  ///   الذي كتب)، فالاستطلاع هنا شبكة أمان لا قناة توصيل.
  ///
  ///   بلا توكن FCM تبقى الثانيتين كما هما: هناك الاستطلاع هو القناة
  ///   الوحيدة، وتخفيضه يعني إشعاراً ضائعاً لا توفيراً.
  ///   والأمامية لم تُمسّ: ١ و٣ ثوانٍ كما طلبها صاحب العمل.
  static const Duration _bgPushInterval = Duration(seconds: 30);

  /// ★ عند اتصال بثّ السيرفر (SSE) يبقى الاستطلاع خطّ أمان، لكنه
  ///   **قصير**: البث قد ينقطع صامتاً (شبكة، سكون نظام، نفق VPN)،
  ///   فلو اعتمدنا عليه وحده يتأخر الإشعار بلا نهاية. من ٥/٨ إلى
  ///   ٣/٤ ثانية (طلب ٢٠٢٦-١٠-٢٨ «فائقة السرعة لكل التطبيق»):
  ///   أسوأ حال عند انقطاع البث ٣ ثوانٍ أمامية و٤ خلفية.
  ///   ★ `isConnected` الآن يعني «وصلت آخر نبضة فعلياً» لا «لم يُغلق
  ///     المقبس» — انظر الحارس في `realtime_service.dart`.
  ///
  ///   ★★ الخلفية مع بثّ حيّ (٢٠٢٦-١١-٠٦): ٤ ثوانٍ ⇒ ٦٠. لسبب واحد
  ///     مقيس: هذا الاستطلاع لا يوصل إشعاراً في هذه الحالة — البثّ
  ///     نفسه يوصله خلال أقل من ثانية، و FCM يوصله و الهاتف مقفل.
  ///     هو خطّ أمان لتحفّظ انقطاع البثّ صامتاً، و الانقطاع الصامت
  ///     له حارس خاص (`realtime_service.dart` يعيد الاتصال حين تتوقف
  ///     النبضات) و له أصلاً نبضة كل ١٠ ثوانٍ تفضحه.
  ///     النتيجة على السرعة: لا شيء في الحالة السليمة، و على
  ///     الاستهلاك: ٢١ ميغابايت/يوم لكل هاتف نائم ⇒ ١٫٤ (كل طلب ١٫١٧
  ///     كيلوبايت، أغلبه ترويسة لا جسم).
  ///     أمامية الهاتف لم تُمسّ: ١ و ٣ ثوانٍ كما طلبها صاحب العمل.
  /// ★★ 2026-11-25 («لا مكلف ولا متأخر»): مع حدث `notify.new` عبر
  ///   البثّ صار الفحص شبكةَ أمان فقط ⇒ ٣ ثوانٍ عند انقطاع البثّ
  ///   (بدل ثانية)، و**٢٠ ثانية** والبثّ حيّ (بدل ٣): الوصول عبر
  ///   الحدث فوري، والاستهلاك الثابت ينخفض أضعافاً.
  static const Duration _realtimeFgInterval = Duration(seconds: 20);
  static const Duration _realtimeBgInterval = Duration(seconds: 60);
  StreamSubscription<RealtimeEvent>? _rtSub;

  /// مهلة الانتظار قبل العرض المحلي حين يكون هناك توكن FCM
  /// (دورة مُرسِل السيرفر).
  ///
  /// الخادم يرسل FCM خلال نفس الدورة التي يكتشف فيها التغيير، والعلامة
  /// `pushed_at` تُكتب بعد نجاح الإرسال مباشرة. ٦٠٠ مللي تكفي لتمرير
  /// تلك الكتابة قبل أن نعرض نسخة ثانية بصوت ثانٍ — وهي الحدّ الأدنى
  /// عملياً على شبكة بطيئة، فالتقليل أكثر يفتح باب التكرار الذي كرهه
  /// صاحب العمل أكثر من التأخير.
  static const Duration _pushedGrace = Duration(milliseconds: 600);

  /// إذا لم نجد شيئاً عدة مرات متتالية ⇒ نتراجع تدريجياً، فالهاتف
  /// النائم لا يستهلك سجلات بلا فائدة.
  ///
  /// ★ السقف ثانيتان فقط (كان ٤ ⇒ التأخير الأقصى ضعف المطلوب).
  ///   الملاحظة الحسابية: `delay = أطول(_idleBackoff[i], الأساس)`،
  ///   فأي قيمة أصغر من الأساس لا معنى لها؛ لذلك بدأت القائمة من
  ///   ثانية واحدة وحذفنا ما دونها.
  static const List<Duration> _idleBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];
  int _idleStreak = 0;

  Timer? _timer;
  bool _running = false;
  bool _ticking = false;
  final Set<String> _seen = <String>{};
  String? _phone;

  /// شعار الحساب الحالي (شعار خاص بكل حساب) لعرضه في كل إشعاراته.
  String? _brandImage;

  /// عنوان الحساب (اسمه أو اسم صيدليته).
  String _brandTitle = '';

  /// وقت آخر جلب للعلامة، لتفادي طلب شبكة متكرر.
  DateTime _brandFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// هل التطبيق في المقدمة؟ (في الخلفية ⇒ إشعار نظام لا بطاقة داخلية)
  bool _foreground = true;

  /// هل لهذا الحساب توكن FCM؟ (نعرض محلياً فوراً إن لم يكن لديه توكن،
  /// لأن FCM لن يصله من السيرفر أصلاً).
  bool hasFcmToken = false;

  /// هل جُلبت هوية الحساب مرة واحدة على الأقل.
  bool get hasBrand => _brandFetchedAt.millisecondsSinceEpoch > 0;

  /// ★★ شعار الحساب — **وليس إلا وهو داخل التطبيق**.
  ///
  /// القاعدة: «لا شعار إلا لمن هو داخل». خارجَ الحساب (بعد تسجيل
  /// الخروج) ترجع سلسلة فارغة، فلا يبقى شعاره عالقاً على الجهاز
  /// ولا يُستعمل في أي إشعار بعد خروجه.
  String get brandImage =>
      (AuthService.instance.isLoggedIn && _brandImage != null)
          ? _brandImage!
          : '';

  String get brandTitle =>
      AuthService.instance.isLoggedIn ? _brandTitle : '';

  bool get isForeground => _foreground;

  /// هل هناك إشعار وصل ولم يُعرض بعد؟ (لشارة الجرس — بلا طلب إضافي)
  bool get hasUndelivered => _pendingCount > 0;
  int _pendingCount = 0;

  /// يربطه `app.dart` حيث يتوفر الـ navigator: فتح شاشة «موافقات
  /// الحجوزات» عند الضغط على إشعار السكرتير. الإشعار يحمل
  /// `link_url = 'appointments'` — علامة داخلية لا رابطاً خارجياً.
  static VoidCallback? onAppointmentsTap;

  /// ★ إشعار المريض بحجزه/دوره (`link_url = 'bookings'`): يفتح
  ///   «حجوزاتي» داخل التطبيق. تختفي بطاقة الدور وحدها بعد الانتهاء،
  ///   والسجل يبقى هناك.
  static VoidCallback? onBookingsTap;

  /// ★ إشعار دردشة العيادة (`link_url = 'chat:<doctorId>:<patient>'`):
  ///   يفتح شاشة المحادثة داخل التطبيق لا رابطاً خارجياً.
  static void Function(String link)? onChatTap;

  /// يُستدعى عند أي تغيّر في حالة دورة حياة التطبيق.
  ///
  /// نُبطل المؤقت ونستأنف فوراً: هكذا أول استطلاع بعد الفتح يقع **الآن**
  /// بدل انتظار بقية الفترة (⑧ ثوانٍ ⇒ ٣ ثوانٍ)، فيظهر أي إشعار متأخر
  /// فور فتح التطبيق.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _idleStreak = 0; // إعادة ضبط ⇒ أسرع وتيرة عند العودة للمقدمة
    // ★ عند العودة للمقدمة: نعيد محاولة البث فوراً إن كان مقطوعاً،
    //   وإلا بقي الجهاز على الاستطلاع حتى تنتهي مدة إعادة المحاولة.
    if (value) RealtimeService.instance.retryNow();
    _rearm();
    unawaited(_tick());
  }

  void _rearm() {
    _timer?.cancel();
    if (!_running) return;
    // الأرقام مبيّنة أعلى الملف؛ القاعدة هنا: الأساس حسب الحالة،
    // وتراجع الخمول **حدّ أدنى فوقه** لا بديل عنه ⇒ لا يتأخر الجهاز
    // عن الأسوأ المكتوب في الثوابت أبداً.
    //
    // ★ `isConnected` = «وصلت آخر نبضة خلال ٤٥ ثانية» (حارس الحياة
    //   في `realtime_service.dart`)، لا «المقبس لم يُغلق». بلا ذلك
    //   كان اتصال ميت صامت يُبطئ الاستطلاع إلى ٣/٤ ثوانٍ بينما
    //   لا يأتي منه شيء — وهو وجه «الإشعارات بطيئة» الحقيقي.
    final live = RealtimeService.instance.isConnected;
    final base = live
        ? (_foreground ? _realtimeFgInterval : _realtimeBgInterval)
        : (_foreground
              ? _fgInterval
              : (hasFcmToken ? _bgPushInterval : _bgInterval));
    final i = _idleStreak.clamp(0, _idleBackoff.length - 1);
    final backed = _idleBackoff[i];
    final delay = backed > base ? backed : base;
    _timer = Timer.periodic(delay, (_) => _tick());
  }

  /// ★ فحص **الآن** وتراجع إلى أسرع وتيرة.
  ///
  /// تُستدعى من كل «حدث للتو»: رسالة FCM وصلت (`PushService`)، أو
  /// البث انقطع/عاد (حارس الحياة)، أو انقطاع متوقع بعد رجوع الجهاز
  /// للنشاط. لا تنتظر المؤقّت الحالي: الجهاز الذي وصلت له رسالة
  /// يعرف أن في القاعدة أشقاءها، فيسحبهم في نفس اللحظة.
  void scanNow() {
    if (!_running) return;
    _idleStreak = 0;
    _rearm();
    unawaited(_tick());
    _reconcileCatalogOnLiveness();
  }

  /// ★ مصالحة الكتالوج عند تغيّر حالة البثّ فقط — لا دورياً.
  ///
  /// كان هنا جلب كل ٦٠ ثانية ما دام البثّ مقطوعاً: قائمة منتجات كاملة
  /// كل دقيقة لهاتف مفتوح، وهو أكبر بند نقل متكرر في التطبيق. الآن
  /// التحميل مرات معدودات لا غير: أول فتح (قرص ثم شبكة)، وعند حدث منتج
  /// من البثّ (إضافة/تعديل/حذف) مرة واحدة تدمجها نافذة الثلاث ثوانٍ،
  /// وهنا مرة عند انقطاع البثّ ومرة عند عودته لالتقاط ما فات في الفجوة.
  /// بين ذلك لا شيء: [_tick] يجلب الإشعارات وحدها.
  bool _rtWasLive = false;

  void _reconcileCatalogOnLiveness() {
    final live = RealtimeService.instance.isConnected;
    if (live == _rtWasLive) return;
    _rtWasLive = live;
    if (!AuthService.instance.isLoggedIn) return;
    // الخلفية لا تعرض كتالوجاً: لا جلب لهاتف نائم. العودة للمقدمة تعيد
    // محاولة البثّ فوراً، وعودته تُطلق المصالحة مرة واحدة من هنا.
    if (!_foreground) return;
    unawaited(RealDataService.instance.refreshProducts());
  }

  /// يشترك في البث: حدث واحد ⇒ استطلاع فوري + تحديث الشارة.
  ///
  /// ★ لا نبني الإشعار من حمولة البث (معرّف ونوع فقط) — نسحب
  ///   التفاصيل بـ `_tick()` فتُعرض نفس النافذة ونفس الأيقونة والشعار
  ///   بلا ازدواج. البث أسرع في الوصول، والاستطلاع يبقى في ترتيب واحد.
  ///
  /// ★ استثناء `product.deleted`: هنا لا صف في القاعدة (حُذف)، فلا
  ///   شيء نطالبه. لذلك نبني الإشعار من حمولة البث مباشرة، ونمرر
  ///   شعار الحساب (`_brandImage`) كما تفعل بقية الإشعارات.
  void _listenRealtime() {
    _rtSub?.cancel();
    _rtSub = RealtimeService.instance.events.listen((event) {
      // ★★ صفّ إشعار جديد لرقمي (بثّ السيرفر): اسحب الآن. هذا المسار
      //   هو ما يجعل الفحص الدوري بطيئاً (20 ثانية) بلا تأخير فعلي.
      if (event.topic == RtEvent.notifyNew) {
        // ★★ إشارة تحديث الحساب (اسم/صورة/دور/تعطيل من لوحة الأدمن):
        //   المشغّل في القاعدة يكتب صفّاً صامتاً `type = profile`
        //   ويبثّه السيرفر هنا. نقرأ الحساب في هذه اللحظة فيظهر الاسم
        //   والدور الجديدان فوراً — بلا نغمة ولا بطاقة ولا صفّ في
        //   الجرس (الصفّ is_global).
        if (event.data['type']?.toString() == 'profile') {
          invalidateBrand();
          unawaited(AuthService.instance.refreshAccountSignal());
        }
        _idleStreak = 0;
        unawaited(_tick());
        _rearm();
        return;
      }
      if (event.topic == RtEvent.productDeleted) {
        // ★ حذف الأدمن لمنتج ليس خبراً للزبائن: لا إشعار ولا صوت.
        //   حدث البث صار هنا لتحديث القوائم بصمت فقط.
        //
        // ★ لكن يجب إبطال كاش **المنتجات** أيضاً: بلاه يبقى المنتج
        //   المحذوف ظاهراً للزبون حتى إعادة تشغيل التطبيق، لأن
        //   `_tick()` يحدّث الإشعارات لا الكتالوج.
        //
        // ★ ونمسح سطره من نسخ القرص قبل الجلب: الحذف قد يصل والجهاز
        //   بلا شبكة كافية للسحب، فيكفي المسح المحلي ليختفي فوراً.
        final deletedId = event.data['id']?.toString() ?? '';
        if (deletedId.isNotEmpty) {
          // ★ الترتيب متسلسل عمداً، لا متوازٍ: كان المسح والجلب يُطلقان
          //   معاً في نفس اللحظة فيرجع الجلب — المنطلق قبل الحذف أو بالتوازي
          //   معه — بالسطر المحذوف ويكتبه في الذاكرة والقرص من جديد.
          //   النتيجة التي شكا منها الأدمن ٢٠٢٦-١٠-٢٨: «حذفت منتجاً وبقي
          //   ظاهراً في الشاشة الرئيسية». الآن: امسح وانتظر، ثم اجلب.
          unawaited(() async {
            await RealDataService.instance
                .purgeProductFromCaches(deletedId, refetch: true);
            // ثم نتأكد من القاعدة نفسها: إن كان المعرّف ما زال فيها فهذا
            // الحدث كان إنذاراً كاذباً، فنُرجع المنتج ولا ندعه مخفيّاً
            // خمس عشرة دقيقة بلا سبب.
            await RealDataService.instance.recheckDeletedProduct(deletedId);
          }());
        } else {
          unawaited(RealDataService.instance.refreshProducts());
        }
        // ★ وصيدليةٌ حُذف تختفي بطاقته أيضاً: حذفه يُسقط منتجاته فتُبَث
        //   كحذف، فنغتنمها لتحديث قائمة الصيدليات (مدمجة كل ٣ ثوانٍ).
        unawaited(RealDataService.instance.refreshShops());
        unawaited(_tick());
        _rearm();
        return;
      }
      if (event.topic == RtEvent.orderItemRemoved) {
        unawaited(_announceItemRemoved(event.data));
        return;
      }
      if (event.topic == RtEvent.priceChanged ||
          event.topic == RtEvent.productChanged) {
        // ★ إطفاء منتج أو تغيير سعره يجب أن يختفي/يتغيّر عند
        //   الزبون **الآن** — لا عند فتح التطبيق. بدون هذا يبقى
        //   المنتج ظاهراً من الكاش حتى إعادة تشغيل.
        unawaited(RealDataService.instance.refreshProducts());
      }
      final relevant =
          event.topic == RtEvent.orderNew ||
          event.topic == RtEvent.orderStatus ||
          event.topic == RtEvent.priceChanged ||
          event.topic == RtEvent.productChanged ||
          event.topic == RtEvent.brandChanged;
      if (!relevant) return;
      // البث أسرع ⇒ نخفّض التراجع ونجلب الآن.
      _idleStreak = 0;
      unawaited(_tick());
      _rearm();
    });
    RealtimeService.instance.onLiveness = scanNow;
    _rtWasLive = RealtimeService.instance.isConnected;
    RealtimeService.instance.start();
  }

  /// إشعار «حُذف/نقص صنف من طلبك» — بشعار **الصيدلية** لا شعار حسابك.
  ///
  /// ★ هذا هو "الشعار الخارجي": صورة الصيدلية الذي كان الصنف عنده،
  ///   فيعرف الزبون أي صيدلية ألغى أي صنف. بلا ذلك يعرف الرسالة بلا
  ///   مَن صاحبها.
  Future<void> _announceItemRemoved(Map<String, dynamic> data) async {
    final orderId = data['orderId']?.toString() ?? '';
    final itemId = data['itemId']?.toString() ?? '';
    if (orderId.isEmpty || itemId.isEmpty) return;

    // ★★ المفتاح من `NotificationDedup.keyFor` — المعيار الموحّد.
    //   كان `'item_rm_${kind}_$itemId'`: نطاق خاص لا يلتقي أبداً
    //   بـ`order:{oid}:item_changed` التي يبنيه الخادم (FCM) و
    //   الاستطلاع لنفس الحدث الواحد.
    //   ★ والنوع واحد `item_changed` لكل أنواع البنود — تماماً
    //   كما يكتب الصفّ في القاعدة وكما يرسله الخادم؛ تعدّد الأنواع
    //   كان يعطي مفتاحاً ثالثاً لا يلتقي بأيٍّ منهما.
    final key = NotificationDedup.keyFor(
      orderId: orderId,
      type: 'item_changed',
    );
    if (_seen.contains(key)) return;
    _seen.add(key);
    if (_seen.length > 400) _seen.remove(_seen.first);
    if (!await NotificationDedup.claim(key)) return;

    final name = (data['productName']?.toString() ?? '').trim();
    final shop = (data['shopName']?.toString() ?? '').trim();
    final kind = data['kind']?.toString() ?? 'removed';
    final from = data['from'];
    final to = data['to'];
    final item = name.isEmpty ? 'صنف' : name;

    // ★ الرسالة والنغمة معاً حسب نوع الحدث. `sound` هنا يختار
    //   النغمة المناسبة للحدث. 
    String title;
    String body;
    String soundKey;
    switch (kind) {
      case 'price_changed':
        title = shop.isEmpty ? 'تغيّر سعر' : 'تغيّر سعر — $shop';
        body =
            'عُدّل سعر «$item»'
            '${(from is num && to is num) ? ' من ${from.toInt()} إلى ${to.toInt()}' : ''}';
        soundKey = 'price_changed';
        break;
      case 'reduced':
        title = shop.isEmpty ? 'تحديث طلبك' : 'تحديث طلبك — $shop';
        body =
            'عُدّلت كمية «$item»'
            '${(from is num && to is num) ? ' إلى ${to.toInt()}' : ''}';
        soundKey = 'replaced';
        break;
      default:
        title = shop.isEmpty ? 'تحديث طلبك' : 'تحديث طلبك — $shop';
        body = 'أُزيل «$item» من طلبك';
        soundKey = 'replaced';
    }

    // ★★ شعار الحساب وحده — لا شعار الصيدلية.
    //   كان `shopImage` (شعار الصيدلية) يتقدّم على شعار الحساب، وهو
    //   صورة **مشتركة** بين كل زبائن ذلك الصيدلية ⇒ تُقرأ كأنها شعار
    //   كل حساب منهم. الآن `brandImage` وحدها (وداخلاً فقط)؛ واسم
    //   الصيدلية موجود في العنوان أصلاً.
    final logo = brandImage;

    // ★★★ في الأمامية: **شريط داخل التطبيق فقط**.
    //    كان `_announceLocally` ⇒ `SystemNotification.show` ⇒ إشعار
    //    نظام فوق التطبيق المرئي. أي أن تغيير السعر كان يصدر إشعار
    //    شريط الإشعارات والتطبيق مفتوح — وهو تكرار مرئي صريح،
    //    والأسوأ أن الـFCM يرسله أيضاً فنحصل على ثالث.
    if (isForeground) {
      await StatusCenter.instance.broadcast(
        title: title,
        body: body,
        status: soundKey,
        orderId: orderId,
        imageUrl: logo.isEmpty ? null : logo,
        sound: soundKey,
        dedupeKey: key,
      );
      return;
    }

    await _announceLocally(
      id: 'rt_item_$itemId',
      title: title,
      body: body,
      sound: soundKey,
      serial: null,
    );
  }

  /// إشعار «حُذف منتج» — أُلغي كلياً:
  ///   كان `product.deleted` يُبَث لكل مستخدم، فيستقبل إشعاراً وصوتاً
  ///   لمجرد أن الأدمن حذف منتجاً. البث صار تحديثاً صامتاً للقوائم.

  /// يبدأ المراقبة فور إقلاع التطبيق.
  void start() {
    if (_running) return;
    _running = true;
    _phone = AuthService.instance.phone;
    _idleStreak = 0;
    unawaited(_loadBrand(force: true));
    unawaited(_tick());
    _listenRealtime();
    _rearm();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _rtSub?.cancel();
    _rtSub = null;
    // ★ فكّ ربط حارس الحياة: لا يجوز أن يبقى البث نادياً على مركز
    //   أُوقف (كان يستأنف مؤقّتات ميتة بعد تسجيل الخروج).
    RealtimeService.instance.onLiveness = null;
    // ★ إغلاق الاتصال مع الإيقاف: ترك البث يعمل بلا مستهلك
    //   يستهلك ذاكرة ويبقي اتصالاً مفتوحاً بلا فائدة.
    unawaited(NotificationSound.instance.stopAll());
    RealtimeService.instance.reset();
  }

  /// يُستدعى عند تغيّر الحساب: ننسق القائمة ونبدأ بماء «الآن»
  /// حتى لا ننبّه على إشعارات الحساب السابق أو القديم.
  void onAccountChanged() {
    _seen.clear();
    // ★ إصلاح "تعلّق الأصوات": النغمة المعلّقة في NotificationSound
    //   كانت تبقى من الحساب السابق، فبعد انتهائها تُشغَّل تلقائياً
    //   ويسمع الحساب الجديد نغمات الحساب القديم تلاحق بعضها.
    //   لا بد من الإلغاء قبل أي شيء آخر.
    unawaited(NotificationSound.instance.stopAll());
    _phone = AuthService.instance.phone;
    // ★★ الشعار يُصفَّر **قبل** إعادة الجلب، لا بعده: كان `_brandImage`
    //   يبقى محفوظاً أثناء التبديل، فيعرض إشعار الحساب **السابق**
    //   بشعاره. ⇒ «شعار واحد لكل حساب» بلا تسرّب بين الحسابات.
    _brandImage = null;
    _brandTitle = '';
    _brandFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
    SupabaseService.instance.clearBrandCache();
    unawaited(_loadBrand(force: true));
    unawaited(_tick());
    // ★ تبديل الحساب = بثّ جديد: الإيقاف ثم البدء، وإلا استقبل
    //   الجهاز أحداثَ الحساب السابق عبر اتصال قديم.
    RealtimeService.instance.reset();
    _listenRealtime();
  }

  /// يُستدعى بعد تغيير صورة الحساب أو شعار الصيدلية.
  void invalidateBrand() {
    _brandFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(_loadBrand(force: true));
  }

  /// ★ مسح هوية الحساب كلياً — عند تسجيل الخروج.
  ///
  /// القاعدة: «لا شعار إلا لمن هو داخل». خارج الحساب لا شعار له،
  /// فلا يجوز أن يبقى محفوظاً على الجهاز.
  void clearBrand() {
    _brandImage = null;
    _brandTitle = '';
    _brandFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
    hasFcmToken = false;
  }

  // ==================================================================
  //  علامة الماء: آخر لحظة تنبيهنا لهذا الحساب
  // ==================================================================

  static String _k(String phone, String suffix) => 'notify_wm_${suffix}_$phone';

  /// آخر لحظة تنبيهنا لهذا الحساب (بلا كتابة سابقة ⇒ 1970).
  Future<DateTime> _watermark(String phone, {bool create = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_k(phone, 'last'));
      if (raw == null) {
        if (!create) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        final now = DateTime.now().toUtc().toIso8601String();
        await prefs.setString(_k(phone, 'last'), now);
        return DateTime.now().toUtc();
      }
      return DateTime.tryParse(raw)?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  Future<void> _markWatermark(String phone, DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_k(phone, 'last'), at.toUtc().toIso8601String());
    } catch (_) {}
  }

  // ==================================================================
  //  الهوية
  // ==================================================================

  /// يجلب شعار الحساب وعنوانه (مرة كل عشر دقائق على الأقل).
  Future<void> _loadBrand({bool force = false}) async {
    final phone = AuthService.instance.phone;
    // ★★ خارج التطبيق ⇒ لا هوية ولا شعار: نمسح ونخرج.
    if (!AuthService.instance.isLoggedIn || phone == null || phone.isEmpty) {
      clearBrand();
      // لا حساب ⇒ لا أحد يُنبَّه، فلا مبرر لبقاء أي شيء يعمل خلف
      // الشاشة. (الخروج كان يترك الخدمة الأمامية تشتغل وتطنّ بصمت.)
      unawaited(BackgroundMonitor.instance.stop());
      return;
    }
    final fresh = DateTime.now().difference(_brandFetchedAt).inMinutes < 10;
    if (!force && fresh) return;
    final brand = await SupabaseService.instance.fetchNotificationBrand(phone);
    // بعد الانتظار قد يكون قد خرج أو تبدّل ⇒ نهمل الردّ.
    if (!AuthService.instance.isLoggedIn ||
        AuthService.instance.phone != phone) {
      clearBrand();
      unawaited(BackgroundMonitor.instance.stop());
      return;
    }
    _brandImage = brand.image;
    _brandTitle = brand.title;
    _brandFetchedAt = DateTime.now();
    hasFcmToken = await SupabaseService.instance.hasFcmToken(phone);
    // ★★ 2026-11-06: الخدمة الأمامية تعمل **دائماً** ما دام هناك حساب
    //   (عكس قرار 11-02 الذي كان يُطفئها عمن يصله FCM). هذه العلامة لم
    //   تعد إذنَ تشغيل، بل مقياسَ **الفاصل** وحده: دقيقة لمن يصله FCM
    //   و١٠ ثوانٍ لمن لا يصله (بلا خدمات جوجل، أو أول تشغيل قبل تسجيل
    //   التوكن). التفصيل في `BackgroundMonitor.sync`.
    unawaited(BackgroundMonitor.instance.sync(pushDeliverable: hasFcmToken));
  }

  /// هل صف الإشعار مُرسَل بالفعل عبر FCM من السيرفر؟
  static bool _wasPushed(Object? pushedAt) {
    final s = pushedAt?.toString().trim() ?? '';
    return s.isNotEmpty && s != 'null';
  }

  // ==================================================================
  //  الاستطلاع
  // ==================================================================

  Future<void> _tick() async {
    if (_ticking) return;
    final phone = AuthService.instance.phone;
    if (phone == null || phone.isEmpty) {
      _phone = null;
      _seen.clear();
      return;
    }
    final switched = phone != _phone;
    if (switched) {
      _phone = phone;
      _seen.clear();
      unawaited(_loadBrand(force: true));
    }

    _ticking = true;
    try {
      // أول دورة لهذا الحساب: نبدأ علامة الماء من «الآن» ⇒
      // لا ننبّه على أي إشعار قديم ولا يتكرر الصوت عند كل فتح.
      var mark = await _watermark(phone, create: switched);
      if (switched) mark = DateTime.now().toUtc();

      final rows = await SupabaseService.instance.fetchNotifications(phone);
      if (rows.isEmpty) {
        // لا جديد ⇒ نتراجع في وتيرة الاستطلاع (توفير لسجلات Supabase).
        if (_idleStreak < _idleBackoff.length - 1) {
          _idleStreak++;
          _rearm();
        }
        _pendingCount = 0;
        return;
      }
      _idleStreak = 0;
      // كان السطر مشروطاً بالواجهة: فبعد وصول إشعار والتطبيق في
      // الخلفية لا يُعاد ضبط المؤقّت، فيبقى على أبطأ تراجع (٤٥ ثانية).
      _rearm();
      _pendingCount = rows.length;

      var newest = mark;
      for (final n in rows) {
        final id = n['id'].toString();
        if (!_seen.add(id)) continue;
        if (_seen.length > 150) _seen.remove(_seen.first);

        final created = DateTime.tryParse(n['created_at']?.toString() ?? '');
        final createdUtc = created?.toUtc() ?? mark;
        if (createdUtc.isAfter(newest)) newest = createdUtc;

        // قديم ⇒ في القائمة فقط، بلا صوت ولا بطاقة.
        if (!createdUtc.isAfter(mark)) continue;

        await _deliver(n, id: id);
      }
      await _markWatermark(phone, newest);
    } catch (_) {
      // الشبكة قد تكون متقطعة — نكمل في الدورة التالية.
    } finally {
      _ticking = false;
    }
  }

  /// يعرض إشعاراً واحداً حسب حالة التطبيق.
  ///
  /// **يُحذف الصف من السيرفر فور تسليمه** (لا تخزين دائم).
  Future<void> _deliver(Map<String, dynamic> n, {required String id}) async {
    final link = n['link_url']?.toString().trim() ?? '';
    final type = _nonEmpty(n['type']);
    // ★ رسالة دردشة جديدة ⇒ نُبلغ الدردشة فوراً فتشحن الشاشة المفتوحة
    //   وقائمة المحادثات الآن، بلا انتظار استطلاعها الدوري.
    if (type == 'chat') ChatService.instance.noteIncoming();
    // ★★ إشارة دور (تعيين/تغيير/حذف سكرتير) ⇒ نقرأ الدور الآن، فيتحول
    //   جهاز السكرتير إلى واجهة العيادة (أو يخرج منها) في ثوانٍ.
    if (type == 'role') AuthService.instance.refreshClinicRoleNow();
    // ★ حدث حجز/دور: نحدّث «الرئيسية» (بطاقة الدور) و«حجوزاتي» فوراً،
    //   فيتغيّر الرقم والمتبقي أو تختفي البطاقة بعد الانتهاء بلا انتظار.
    if (type == 'appointment_approved' ||
        type == 'queue_near' ||
        type == 'queue_called' ||
        type == 'appointment_done' ||
        type == 'appointment_rejected') {
      TabRefresh.fire('home');
      TabRefresh.fire('bookings');
    }
    // ★★ الشعار من الحساب وحده وداخلاً فقط: `brandImage` ترجع
    //   فارغة خارجَ الحساب، فلا يُستعمل `image_url` إلا إن كان
    //   داخلاً — وهو ما كتبه الخادم أصلاً (`account_is_online`).
    // ★ استثناء الدردشة: `image_url` هو شعار **الطرف المُرسِل**،
    //   وشعار الحساب هنا سيعرض صورة المستقبِل أمام رسالة غيره.
    final own = brandImage;
    final sentLogo = _nonEmpty(n['image_url']);
    final logo = type == 'chat'
        ? (sentLogo ?? '')
        : (own.isNotEmpty ? own : sentLogo);
    final sound = _nonEmpty(n['sound']) ?? type;
    final serial = _nonEmpty(n['serial']);
    final orderId = _nonEmpty(n['order_id']);
    final isDriverRequest = type == 'driver_request';
    // ★ مفتاح موحّد (المعيار الوحيد لكل القنوات) ⇒ يمنع تكرار
    //   الشعار والصوت بين استطلاع المقدمة والاستطلاع الخلفي و FCM.
    final dedupeKey = NotificationDedup.keyFor(
      orderId: orderId,
      type: type,
      rowId: id,
    );
    final title = n['title']?.toString() ?? 'إشعار';
    final body = n['body']?.toString() ?? '';

    VoidCallback? onTap;
    if (link == 'appointments') {
      // علامة داخلية: لا تُفتح خارجياً، بل شاشة الموافقات.
      onTap = () => onAppointmentsTap?.call();
    } else if (link == 'bookings') {
      // علامة داخلية لحجوزات الزبون — لا رابط خارجي.
      onTap = () => onBookingsTap?.call();
    } else if (link.startsWith('chat:')) {
      onTap = () => onChatTap?.call(link);
    } else if (link.isNotEmpty) {
      onTap = () async {
        final uri = Uri.tryParse(
          link.startsWith('http') ? link : 'https://$link',
        );
        if (uri != null) await launchUrlSafe(uri);
      };
    }

    // ── في المقدمة: بطاقة داخل التطبيق + نطق/نغمة ──
    if (_foreground) {
      // ★★ أرسله السيرفر عبر FCM فعلاً (عرضه النظام في الشريط حين
      //   كان التطبيق خارج الواجهة)؟ ⇒ نستهلكه بصمت: عرض بطاقة فوق
      //   شاشة مفتوحة + صوت ثانٍ تكرارٌ صريح لما رآه قبل لحظات.
      if (_wasPushed(n['pushed_at'])) {
        await _consume(id, title: title, body: body, type: type, logo: logo);
        return;
      }
      // ★ البوابة الموحّدة: إن عرضه إشعار آخر (FCM أو استطلاع خلفي)
      //   فلا نعيد الصوت والشعار. نحذف الصف ونخرج.
      if (!await NotificationDedup.claim(dedupeKey)) {
        await _consume(id, title: title, body: body, type: type, logo: logo);
        return;
      }
      await StatusCenter.instance.broadcast(
        title: title,
        body: body,
        status: n['is_global'] == true ? 'broadcast' : type,
        orderId: orderId,
        imageUrl: logo,
        sound: sound,
        serial: serial,
        isDriverRequest: isDriverRequest,
        dedupeKey: dedupeKey,
        duration: const Duration(seconds: 6),
        onTap: onTap,
      );
      await _consume(id, title: title, body: body, type: type, logo: logo);
      return;
    }

    // ── في الخلفية ──
    // أرسلها السيرفر عبر FCM؟ ⇒ نظام التشغيل عرضها، فنكتفي بالحذف.
    if (_wasPushed(n['pushed_at'])) {
      await _consume(id, title: title, body: body, type: type, logo: logo);
      return;
    }

    // لا توكن FCM ⇒ لن تصل من السيرفر ⇒ نعرض فوراً بلا تأخير.
    if (!hasFcmToken) {
      if (await NotificationDedup.claim(dedupeKey)) {
        await _announceLocally(
          id: id,
          title: title,
          body: body,
          sound: sound,
          serial: serial,
        );
        await _consume(id, title: title, body: body, type: type, logo: logo);
      }
      return;
    }

    // فيه توكن ⇒ ننتظر المُرسِل قليلاً قبل العرض المحلي تفادياً للتكرار.
    unawaited(
      _deliverAfterGrace(
        rowId: id,
        dedupeKey: dedupeKey,
        title: title,
        body: body,
        sound: sound,
        serial: serial,
        isDriverRequest: isDriverRequest,
        logo: logo,
        type: type,
      ),
    );
  }

  /// بعد التسليم: نحفظ السجل على الجهاز ثم **نحذف الصف من السيرفر**.
  ///
  /// هكذا لا يتراكم شيء في قاعدة البيانات: الطابور يُستهلك فوراً.
  Future<void> _consume(
    String id, {
    required String title,
    required String body,
    String? type,
    String? logo,
  }) async {
    unawaited(
      NotificationHistory.instance.add(
        title: title,
        body: body,
        type: type,
        logo: logo,
      ),
    );
    await SupabaseService.instance.deleteNotification(
      id,
      AuthService.instance.phone,
    );
  }

  /// يعرض الإشعار بعد المهلة فقط إن لم يصل عبر FCM ولم يُقرأ،
  /// ثم يحذف الصف (الطابور يُستهلك فوراً).
  Future<void> _deliverAfterGrace({
    required String rowId,
    required String dedupeKey,
    required String title,
    required String body,
    required String? sound,
    required String? serial,
    required bool isDriverRequest,
    required String? logo,
    String? type,
  }) async {
    await Future<void>.delayed(_pushedGrace);
    // عدنا للمقدمة ⇒ البطاقة تكفي، فنكتفي بالحذف.
    final fresh = await SupabaseService.instance.notificationById(
      rowId,
      AuthService.instance.phone,
    );
    if (_foreground) {
      if (fresh != null) {
        await _consume(rowId, title: title, body: body, type: type, logo: logo);
      }
      return;
    }
    if (fresh == null) return; // حُذف مسبقاً (فقد سجّلناه) — لا داعي للعرض
    // ★★ أرسله السيرفر عبر FCM فعلاً (مثلاً خلال مهلة الانتظار)
    //   ⇒ النظام عرضه بصوته، فلا نعرض نسخة ثانية بصوت ثانٍ.
    if (_wasPushed(fresh['pushed_at'])) {
      await _consume(rowId, title: title, body: body, type: type, logo: logo);
      return;
    }
    if (fresh['is_read'] == true) {
      await _consume(rowId, title: title, body: body, type: type, logo: logo);
      return;
    }
    if (await NotificationDedup.claim(dedupeKey)) {
      // ★★ فحص أخير **بعد** الحجز وقبل العرض: لو أرسل السيرفر
      //   FCM في هذه اللحظات بالضبط (فحصُه قبل الإرسال رآه حيّاً)
      //   فلا نعرض نسخة ثانية فوق ما عرضه النظام بصوته.
      final last = await SupabaseService.instance.notificationById(
        rowId,
        AuthService.instance.phone,
      );
      if (last == null || _wasPushed(last['pushed_at'])) {
        await _consume(rowId, title: title, body: body, type: type, logo: logo);
        return;
      }
      await _announceLocally(
        id: rowId,
        title: title,
        body: body,
        sound: sound,
        serial: serial,
      );
    }
    await _consume(rowId, title: title, body: body, type: type, logo: logo);
  }

  /// إشعار النظام مع نغمة القناة المناسبة للحدث.
  Future<void> _announceLocally({
    required String id,
    required String title,
    required String body,
    required String? sound,
    required String? serial,
  }) async {
    await SystemNotification.instance.show(
      id: SystemNotification.notificationId(id),
      // ★ رقم الطلب في العنوان: هو أول ما يُقرأ في شريط الإشعارات
      //   خارج التطبيق، ومن دونه لا يعرف المندوب أي طلب.
      title: SystemNotification.withSerialTag(
        title,
        serial: serial,
        body: body,
      ),
      body: body,
      soundOrType: sound,
    );
  }

  static String? _nonEmpty(Object? v) {
    final s = v?.toString().trim() ?? '';
    return (s.isEmpty || s == 'null') ? null : s;
  }
}

/// فتح رابط خارجي بأمان (بدون استيراد url_launcher في كل مكان).
Future<bool> launchUrlSafe(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
