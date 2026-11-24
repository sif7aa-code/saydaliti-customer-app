// =====================================================================
//  معالج رسائل FCM في الخلفية — يعمل والتطبيق مغلق / مُقتل (Terminated)
// =====================================================================
//
//  لماذا هذا الملف منفصل؟
//  ─ `FirebaseMessaging.onBackgroundMessage` يجب أن يستقبل **دالة على
//    مستوى الملف (top-level)** موسومة بـ `@pragma('vm:entry-point')`،
//    وإلا حذفها مُحسّن الشجرة (tree-shaker) في نسخة Release ولم تعد
//    تعمل إلا في وضع Debug — وهو أشهر سبب لـ "الإشعار لا يظهر والتطبيق
//    مغلق".
//  ─ الدالة تعمل في **عزل (isolate) منفصل** لا ترى `main()` ولا
//    `WidgetsBinding`، لذلك نُهيّئ Firebase داخلها بشكل مستقل، ونحتاج
//    أن نعرض الإشعار بأنفسنا في حالة data-only.
//
//  متى نعرض الإشعار بأنفسنا؟
//  ─ إن كان في الرسالة كتلة `notification` ⇒ النظام يعرضها تلقائياً
//    (بصوت قناتها وبصورتها) ولا نفعل شيئاً — التكرار هنا يضاعف الإشعار.
//  ─ إن كانت الرسالة **data فقط** (بلا `notification`) ⇒ لا يعرض النظام
//    شيئاً، وهنا فقط نعرض نحن ⇒ هذا هو ما يجعل الإشعارات تعمل
//    في حالة القتل الكامل (Killed State).
// =====================================================================

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'system_notification.dart';

/// معالج الخلفية — نقطة الدخول التي تستدعيها FCM عند Killed State.
///
/// ملاحظة مهمة: يجب أن تبقى **ثابتة الاسم** ومسجّلة في `main()`
/// قبل `runApp`، وأي إعادة تسمية هنا تكسر الإشعارات الخلفية.
@pragma('vm:entry-point')
Future<void> fcmBackgroundMessageHandler(RemoteMessage message) async {
  // 1) تهيئة Firebase مستقلة داخل عزل الخلفية (لا نعتمد على main()).
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // مهيّأة مسبقاً أو تعذّرت — نكمل على أي حال.
  }

  try {
    // 2) كتلة notification موجودة ⇒ عرض النظام هو المسؤول.
    if (message.notification != null) return;

    // ★★ لا حساب داخل التطبيق ⇒ لا نعرض شيئاً (طلب ٢٠٢٦-١٠-١٢:
    //   «عند تسجيل الخروج لا تُرسَل إشعارات»). العزل الخلفي لا يرى
    //   `AuthService.instance` هذه النسخة — فهو isolate جديد يبدأ من
    //   الصفر — لذلك يُقرأ المفتاح من القرص مباشرة.
    //   ★ الحدّ honest: هذا يغطي رسائل **data فقط** وهي التي نعرضها
    //   بأنفسنا. أما رسالة `notification` فيعرضها نظام أندرويد قبل
    //   أن يستيقظ أي كود لنا، فيوقفها الخادم وحده — وهو ما صار:
    //   الخروج يُبطِل `push_tokens.is_active`، و`watcher` صار لا يرسل
    //   لصفّ معطّل إلا إذا كان نفس التوكن حيّاً على حساب آخر في
    //   الجهاز نفسه (تبديل حسابات)، فلا ينزل شيء لمن خرج.
    try {
      final prefs = await SharedPreferences.getInstance();
      final inside = prefs.getBool(AuthService.loggedInPrefKey) ?? false;
      if (!inside) return;
    } catch (_) {
      // تعذّرت قراءة القرص: نعرض كما كنّا نفعل — الإشعار أهم من
      // الشكّ، والفشل هنا ليس دليلاً على أن المستخدم خرج.
    }

    // 3) رسالة data فقط ⇒ نحن نعرضها (يعمل والتطبيق مغلق تماماً).
    final data = message.data;
    final title = (data['title'] ?? '').toString().trim();
    final body = (data['body'] ?? '').toString().trim();
    if (title.isEmpty && body.isEmpty) return;

    await showBackgroundNotification(message, title, body);
  } catch (e) {
    if (kDebugMode) print('FCM background handler failed: $e');
  }
}

/// يعرض إشعاراً محلياً لرسالة data فقط، بنفس القنوات والأصوات المستعملة
/// داخل التطبيق ⇒ نفس النغمة تماماً سواء كان التطبيق يعمل أو مغلقاً.
Future<void> showBackgroundNotification(
  RemoteMessage message,
  String title,
  String body,
) async {
  final plugin = FlutterLocalNotificationsPlugin();

  // معرّف ثابت لكل رسالة ⇒ تحديث بدل تكرار.
  final rawId = message.messageId ?? '$title|$body';
  final id = rawId.hashCode & 0x3fffffff;

  // قناة الحدث ⇒ لكل حالة نغمة خاصة.
  final kind = (message.data['kind'] ??
          message.data['sound'] ??
          message.data['status'] ??
          '')
      .toString();
  final channel = SystemNotification.channelFor(kind);
  final label = SystemNotification.channelName(channel);

  // حمولة النقر: orderId|serial|kind — تقرأها `FcmRouter` عند الضغط
  // (سواء كان التطبيق يعمل أو مغلقاً) فتفتح شاشة الطلب مباشرة.
  final routePayload = [
    (message.data['orderId'] ?? '').toString(),
    (message.data['serial'] ?? '').toString(),
    kind,
  ].join('|');

  await plugin.show(
    id,
    title.isEmpty ? 'إشعار جديد' : title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        channel,
        label,
        channelDescription: 'تنبيه: $label',
        importance: Importance.high, // ⇐ يستيقظ النظام ويعرض فوراً
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList(const [0, 250, 150, 250]),
        ticker: body,
        autoCancel: true,
        styleInformation: const DefaultStyleInformation(true, true),
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: true,
      ),
    ),
    payload: routePayload,
  );
}
