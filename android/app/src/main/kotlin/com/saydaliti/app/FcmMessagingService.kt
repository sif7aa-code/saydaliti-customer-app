package com.saydaliti.app

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * خدمة استقبال FCM على مستوى Android.
 *
 * لماذا نُعرّفها يدوياً رغم أن إضافة firebase_messaging تُسجّل خدمتها هي؟
 *  1) ضمان بقائها في المانيفست بعد أي عملية دمج/تنظيف (proguard/R8) —
 *     فوجودها صريح لا يترك الأمر لمُحسّن الملفات.
 *  2) التقاط حمولة الرسالة **قبل** أن يستلمها محرك Flutter، وحفظها في
 *     [FcmLaunchStore]. هذا ما يجعل الضغط على إشعار بعد إغلاق التطبيق
 *     بالكامل (Killed State) لا يفقد بياناته: عند إقلاع المحرك لاحقاً
 *     يقرأها من هناك، تماماً كما يفعل `getInitialMessage` في Dart.
 *  3) التقاط تغيّر التوكن على مستوى Android قبل أن يلتقطه محرك Flutter
 *     (فإن مات التطبيق فور التحديث يُضيع التوكن لو اعتمدنا على Dart فقط).
 *
 * ملاحظة مهمة: عندما تكون الرسالة JSON فيها كتلة `notification` فإن
 * **النظام** يعرض الإشعار (صوت قناته وصورته) وسلّمنا الاستدعاء إلى
 * عزل الخلفية فقط — ونحن لا نعرض شيئاً إضافياً حتى لا يتكرر الإشعار.
 *
 * اسم الصنف = `FcmMessagingService` ليطابق المانيفست:
 *   <service android:name=".FcmMessagingService" ... />
 */
class FcmMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        val data = message.data ?: emptyMap()
        // ⚠️ لا نحفظ هنا إلا رسالة **بيانات بلا كتلة notification**:
        //    - إن وُجدت كتلة notification ⇒ عرض النظام تكفّل بها، والضغط
        //      عليها يمرّ إلينا عبر Intent الإقلاع (MainActivity).
        //    - حفظ كل رسالة واردة هنا كان سيجعل التطبيق يفتح الطلب
        //      تلقائياً عند الإقلاع **دون أن يضغط المستخدم** على الإشعار.
        if (message.notification == null) {
            FcmLaunchStore.stash(
                orderId = data["orderId"].orEmpty(),
                status = (data["status"] ?: data["kind"]).orEmpty(),
                title = data["title"].orEmpty(),
                body = data["body"].orEmpty(),
                link = data["link"].orEmpty(),
                serial = data["serial"].orEmpty()
            )
            Log.d(TAG, "data-only message stashed: ${data.keys}")
        } else {
            Log.d(TAG, "notification message: shown by the system")
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // يُدار التوكن في Dart (PushService) ويسجّل في Supabase؛
        // نحفظه هنا أيضاً احتياطاً حتى لا يضيع لو مات التطبيق فجأة.
        FcmLaunchStore.stashToken(token)
        Log.d(TAG, "FCM token refreshed")
    }

    override fun onDeletedMessages() {
        super.onDeletedMessages()
        Log.d(TAG, "messages deleted by FCM (device offline)")
    }

    companion object {
        private const val TAG = "StrasopaFCM"
    }
}

/**
 * مخزن ثابت بسيط لآخر رسالة إشعار + آخر توكن.
 *
 * يعيش داخل عملية التطبيق: إن كانت العملية حيّة قرأه محرك Flutter
 * مباشرة، وإن ماتت العملية فستُملأ القيمة عند وصول الرسالة عبر
 * [FcmMessagingService] قبل أن يُنشأ Intent الإقلاع.
 */
object FcmLaunchStore {
    @Volatile
    var orderId: String? = null

    @Volatile
    var status: String? = null

    @Volatile
    var title: String? = null

    @Volatile
    var body: String? = null

    @Volatile
    var link: String? = null

    @Volatile
    var serial: String? = null

    @Volatile
    var lastToken: String? = null

    fun stash(
        orderId: String,
        status: String,
        title: String,
        body: String,
        link: String,
        serial: String
    ) {
        if (orderId.isNotEmpty() || link.isNotEmpty() || title.isNotEmpty()) {
            this.orderId = orderId
            this.status = status
            this.title = title
            this.body = body
            this.link = link
            this.serial = serial
        }
    }

    fun stashToken(token: String) {
        lastToken = token
    }

    /** قراءة ثم تفريغ (تُستدعى مرة واحدة عند الإقلاع). */
    fun consume(): Map<String, String>? {
        val o = orderId
        if (o.isNullOrEmpty() && link.isNullOrEmpty() && title.isNullOrEmpty()) {
            return null
        }
        val map = mapOf(
            "orderId" to o.orEmpty(),
            "status" to status.orEmpty(),
            "title" to title.orEmpty(),
            "body" to body.orEmpty(),
            "link" to link.orEmpty(),
            "serial" to serial.orEmpty()
        )
        orderId = null
        status = null
        title = null
        body = null
        link = null
        serial = null
        return map
    }
}
