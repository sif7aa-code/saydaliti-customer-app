/// استطلاع الإشعارات في الخلفية — يعمل والتطبيق مغلق.
///
/// ★ لماذا خدمة أمامية (Foreground Service) وليست حزمة جاهزة؟
///   حزمة `workmanager` لا تُبنى مع نسخة Flutter/Gradle في هذا المشروع،
///   حتى لو استُوردت بنجاح. لذلك نفّذنا الخدمة بأنفسنا: خدمة أمامية
///   أصلية تبقي عملية التطبيق حيّة وتستدعي [pollNotificationsOnce] كل
///   دقيقة عبر قناة method، ⇒ استطلاع **دائم** بفاصل دقيقة واحدة،
///   وهو ما تعجز عنه WorkManager (١٥ دقيقة كحد أدنى).
///
///   الدور الأساسي للإشعار الفوري يبقى FCM من الخادم (أقل من ثانية)؛
///   وهذه شبكة أمان تعمل **دائماً** (قرار 2026-11-06): لو لم يصل FCM لأي
///   سبب، تلتقط الخدمة الإشعار خلال الفاصل — دقيقة لمن يصله FCM و١٠
///   ثوانٍ لمن لا يصله. وهي وحدها التي تُشغّل النغمة وتعرض الشريط
///   الداخلي داخل التطبيق.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_dedup.dart';
import 'notification_sound.dart';
import 'supabase_service.dart';
import 'system_notification.dart';

/// قناة التواصل مع الخدمة الأمامية الأصلية.
const MethodChannel _bgChannel = MethodChannel('strasopa/bg_monitor');

/// هل التطبيق يعمل على أندرويد؟ (الخدمة الأصلية موجودة هناك فقط)
bool get _supportsMonitor =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// جولة استطلاع واحدة: تجلب إشعارات المستخدم وتعرضها في شريط الإشعارات.
///
/// آمنة للاستدعاء المتكرر، وتبتلع الاستثناءات حتى لا يسقط الاستطلاع.
Future<void> pollNotificationsOnce() async {
  try {
    // ★★ 2026-11-08 — إزالة ازدواج مقيس:
    //   الخدمة الأمامية الأصلية تُنادي هذه الدالة كل ١٠/٦٠ ثانية، وفي
    //   الوقت نفسه `NotificationCenter` يستطلع كل ١–٣ ثوانٍ والتطبيق
    //   في المقدمة. أي أننا نطلب `get_my_notifications` مرتين لكل دورة
    //   بلا أن يرى المستخدم شيئاً إضافياً — سجلّ Supabase يدفع الثمن.
    //   الآن: إذا كان التطبيق **مرئياً** فمركز الإشعارات هو المسؤول
    //   وحده، ولا نستطلع من الخلفية. أمّا إذا كان التطبيق مطوياً أو
    //   ميتاً (`paused/detached/null`) فتبقى الخدمة تعمل كما هي تماماً،
    //   فلا يُفقد إشعار ولا يتأخر.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    // 1) من هو المستخدم؟ لا معنى للاستطلاع بدون حساب مسجَّل دخوله.
    final prefs = await SharedPreferences.getInstance();
    final loggedIn = prefs.getBool('auth_logged_in') ?? false;
    if (!loggedIn) return;
    final phone = prefs.getString('auth_phone') ?? '';
    if (phone.isEmpty) return;

    // 2) جلب الإشعارات غير المقروءة.
    final rows =
        await SupabaseService.instance.fetchNotifications(phone);
    if (rows.isEmpty) return;

    // 3) تجهيز القنوات والأصوات (بلا واجهة).
    await SystemNotification.instance.init();
    await NotificationSound.instance.load();
    // ★★ «لا شعار إلا لمن هو داخل» كانت بوابة هذا المتغير: الإشعار
    //   صار بلا صورة أصلاً (أمر الأدمن ٢٠٢٦-١١-٠٦)، فلا شعار يُنزَّل
    //   في الخلفية ولا رابط يُقرأ منه.
    for (final row in rows) {
      final id = (row['id']?.toString() ?? '').trim();
      if (id.isEmpty) continue;

      // ★ البوابة الموحيدة لمنع التكرار.
      //   كان هذا الملف يستعمل مفتاحاً خاصاً به (`bg:$id`) فيتجاوز
      //   حماية الاستطلاع الأمامي، ف.apps duplica. الآن كل القنوات
      //   تمرّ على نفس المفتاح ⇒ يُعرض الإشعار مرة واحدة فقط.
      final type = row['type']?.toString().trim() ?? '';
      final key = NotificationDedup.keyFor(
        orderId: row['order_id']?.toString().trim(),
        type: type.isEmpty ? null : type,
        rowId: id,
      );
      if (!await NotificationDedup.claim(key)) {
        // سبق عرضه ⇒ نحذف الصف فقط حتى لا يبقى يطنّ.
        await _drop(id, phone);
        continue;
      }

      // ★ هل أرسله السيرفر عبر FCM؟ ⇒ نظام التشغيل عرضه، فنكتفي بالحذف.
      //   (بدون هذا يُظهر الاستطلاع الخلفي إشعاراً مكرّراً رغم وصوله
      //    فورياً عبر FCM — وهو سبب تكرار الصوت في الخلفية.)
      final pushed = row['pushed_at']?.toString().trim() ?? '';
      if (pushed.isNotEmpty && pushed != 'null') {
        await _drop(id, phone);
        continue;
      }

      final title = row['title']?.toString() ?? 'إشعار';
      final body = row['body']?.toString() ?? '';
      final rawSound = row['sound']?.toString() ?? type;
      final serial = row['serial']?.toString() ?? '';

      // 4) إشعار نظام حقيقي في شريط الإشعارات بنغمة القناة.
      await SystemNotification.instance.show(
        id: id.hashCode & 0x3fffffff,
        // ★ رقم الطلب في العنوان (نفس قاعدة العرض في المقدمة)،
        //   ومن دونه لا يعرف المندوب أي طلب بعد فتح شريط الإشعارات.
        title: SystemNotification.withSerialTag(
          title,
          serial: serial,
          body: body,
        ),
        body: body,
        soundOrType: rawSound,
      );

      // 6) حذف الصف من السيرفر (طابور مؤقت بلا تخزين دائم).
      await _drop(id, phone);
    }
  } catch (e) {
    // استعلامات منتهية ⇒ نخرج بهدوء ولا نكرّر التحذير كل دقيقة.
    debugPrint('bg poll: $e');
  }
}

/// حذف صف الإشعار من السيرفر (الطابور يُستهلك فوراً، بلا تخزين دائم).
///
/// نمرّر رقم الحساب مع المعرّف: الخادم يتحقّق أن الصف لهذا الرقم
/// (وإلا كان يقدر يحذف إشعار غيره).
Future<void> _drop(String id, String phone) async {
  try {
    await SupabaseService.instance.deleteNotification(id, phone);
  } catch (e) {
    debugPrint('bg: delete failed $id: $e');
  }
}

/// تحكّم في خدمة المراقبة الأصلية (تشغيل/إيقاف).
class BackgroundMonitor {
  BackgroundMonitor._();
  static final BackgroundMonitor instance = BackgroundMonitor._();

  /// استقبال نداء `tick` من الخدمة الأمامية ثم تنفيذ جولة استطلاع.
  ///
  /// يُستدعى قبل `runApp` (تسجيل معالج القناة فقط).
  Future<void> init() async {
    if (!_supportsMonitor) return;
    try {
      _bgChannel.setMethodCallHandler((call) async {
        if (call.method == 'tick') {
          // ★ «أنا حيّ» قبل الاستطلاع: الجانب الأصلي يقيس بهذه
          //   الإشارة حياة المحرك؛ إن غابت ١٥٠ ثانية تحوّل للاستطلاع
          //   الأصلي (NativePoller) فلا يضيع إشعار التطبيق مقتولاً.
          try {
            await _bgChannel.invokeMethod<void>('tickAck');
          } catch (_) {}
          // لا ننتظر: الخدمة تتصل كل دقيقة، و`tick` قد يتكرر.
          unawaited(pollNotificationsOnce());
        }
        return null;
      });
    } catch (e) {
      debugPrint('bg monitor init: $e');
    }
  }

  /// تشغيل الخدمة الأمامية ⇒ استطلاع دائم كل دقيقة.
  Future<void> start() async {
    if (!_supportsMonitor) return;
    try {
      await _bgChannel.invokeMethod<void>('start');
    } catch (e) {
      debugPrint('bg monitor start: $e');
    }
  }

  /// إيقاف الخدمة (عند تسجيل الخروج) ⇒ لا استطلاع بلا حساب.
  Future<void> stop() async {
    if (!_supportsMonitor) return;
    try {
      await _bgChannel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// ★ قرار 2026-11-06 (طلبه: «اجعل التطبيق يعمل في الخلفية دائما
  ///   كالسابق يستقبل اشعارات ويرسل خارجيات او داخليات»): الخدمة تعمل
  ///   **دائماً** ما دام هناك حساب مسجَّل دخوله — عكس قرار 11-02 الذي
  ///   كان يُطفئها كلياً عن كل هاتف يصله FCM.
  ///
  /// لماذا تُركت دائماً وهي ليست المسار الأساسي؟
  ///   · FCM يعرضه نظام التشغيل والتطبيق ميت، لكنه يفشل بصمت عند
  ///     أسباب كثيرة: توكن أُبطل، هاتف بلا خدمات جوجل، مصنّع يخنق
  ///     العملية (هواوي)، أو صفّ `push_tokens` معطّل.
  ///   · والاستطلاع وحده يقدر أن يُنطق الصوت العربي ويعرض **الشريط
  ///     الداخلي** داخل التطبيق، وهو ما لا تفعله رسالة FCM.
  ///
  /// الذي يتغيّر هو الفاصل وحده، ويقرؤه الجانب الأصلي في كل جولة من
  ///   العلامة [_kPushOk]: دقيقة لمن يصله FCM (شبكة أمان)، و١٠ ثوانٍ
  ///   لمن لا يصله (مساره الحقيقي الوحيد). ١٠ ثوانٍ على كل الهواتف
  ///   = ٨٦٤٠ طلباً في اليوم للهاتف تُحسب من باقة Supabase المجانية.
  ///
  /// العلامة تُكتب في التفضيلات لأن الجانب الأصلي (كوتلن) يشغّل الخدمة
  /// بنفسه في موضعين لا يمرّان بـ دارت: إقلاع العملية وإقلاع الهاتف.
  Future<void> sync({required bool pushDeliverable}) async {
    if (!_supportsMonitor) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPushOk, pushDeliverable);
    } catch (_) {}
    await start();
  }

  /// مفتاح يقرأه `BackgroundMonitorService.kt` لقياس فاصل الاستطلاع.
  static const String _kPushOk = 'notify_push_deliverable';
}
