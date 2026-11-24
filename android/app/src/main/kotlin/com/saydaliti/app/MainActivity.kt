package com.saydaliti.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * قناة إشعار واحدة: معرّف + اسم ظاهر + نغمة من res/raw.
 */
private data class ChannelSpec(
    val id: String,
    val label: String,
    val raw: String,
    val color: String
)

/**
 * قنوات إشعارات سنتر الشطرة.
 *
 * لكل نوع إشعار قناة مستقلة لأن Android لا يسمح بتغيير صوت القناة بعد
 * إنشائها (القناة إعدادات ثابتة يحددها المستخدم). لذلك لكل قناة معرّف
 * مستقر + نسخة (v2) حتى لو غيّرنا النغمة لاحقاً.
 *
 * القناة = ما يجعل الصوت يعمل خارج التطبيق (الخلفية / مقفل / مُقتل).
 * المعرّفات مطابقة تماماً لما يرسله tools/push_worker.js وما يقرأه
 * lib/services/system_notification.dart.
 */
object NotifyChannels {
    const val NEW_ORDER = "strasopa_v2_new_order"
    const val ACCEPTED = "strasopa_v2_accepted"
    const val DELIVERING = "strasopa_v2_delivering"
    const val REJECTED = "strasopa_v2_rejected"
    const val REPLACED = "strasopa_v2_replaced"

    /**
     * تغيير سعر — يرسلها الخادم (`notify-server/src/fcm.js`) بهذه المعرّف
     * بالضبط، وكذلك `SystemNotification.channelFor(priceChanged)`.
     *
     * ★ كانت **غير مُنشأة هنا** من قبل، والنظام يحذف الإشعار (بلا صوت)
     *   إذا وصل إلى معرّف قناة غير موجود ⇒ تغيير السعر كان يرنّ صامتاً.
     */
    const val PRICE_CHANGED = "strasopa_v2_price_changed"

    const val DELIVERED = "strasopa_v2_delivered"
    const val ALERT = "strasopa_v2_alert"

    /**
     * القناة الافتراضية العامة (high importance).
     *
     * معرّفها مربوط في AndroidManifest عبر
     * `com.google.firebase.messaging.default_notification_channel_id`، وهي
     * القناة التي يختارها FCM تلقائياً لأي رسالة تصل **بلا channelId**
     * (وكل رسائلنا تصل بـ channelId ⇒ تستعمل قنواتها الخاصة).
     * أهميتها HIGH ⇒ يوقظ النظام ويعرض الإشعار فوراً حتى والتطبيق
     * مغلق/مُقتل.
     */
    const val HIGH_IMPORTANCE = "high_importance_channel"

    /** القناة القديمة (نظامي افتراضي) — للإشعارات القديمة بدون channelId. */
    const val LEGACY = "strasopa_notifications"

    private val specs = listOf(
        ChannelSpec(NEW_ORDER, "طلب جديد", "new_order", "#E7A23D"),
        ChannelSpec(ACCEPTED, "قبول الطلب", "accepted", "#1F7A5C"),
        ChannelSpec(DELIVERING, "جاري التوصيل", "delivering", "#3E9B7A"),
        ChannelSpec(REJECTED, "رفض الطلب", "rejected", "#DC4231"),
        ChannelSpec(REPLACED, "استبدال منتج", "replaced", "#17624A"),
        ChannelSpec(PRICE_CHANGED, "تغيير سعر", "price_changed", "#B45309"),
        ChannelSpec(DELIVERED, "توصيل الطلب", "delivered", "#1B9E4B"),
        ChannelSpec(ALERT, "تنبيه عام", "alert", "#2E8B6B")
    )

    private fun attributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    fun createAll(context: Context, manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val attrs = attributes()
        val res = context.resources
        val pkg = context.packageName

        for (spec in specs) {
            val soundId = res.getIdentifier(spec.raw, "raw", pkg)
            val uri = if (soundId != 0) {
                Uri.parse("android.resource://$pkg/raw/${spec.raw}")
            } else {
                Settings.System.DEFAULT_NOTIFICATION_URI
            }
            manager.createNotificationChannel(
                NotificationChannel(
                    spec.id,
                    spec.label,
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "صوت تنبيه: ${spec.label}"
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 250, 150, 250)
                    setSound(uri, attrs)
                    enableLights(true)
                    lightColor = android.graphics.Color.parseColor(spec.color)
                    setShowBadge(true)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
            )
        }

        manager.createNotificationChannel(
            NotificationChannel(
                HIGH_IMPORTANCE,
                "تنبيهات فورية",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "القناة الافتراضية: إشعارات فورية حتى والتطبيق مغلق"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 150, 250)
                setSound(Settings.System.DEFAULT_NOTIFICATION_URI, attrs)
                enableLights(true)
                setShowBadge(true)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            }
        )

        manager.createNotificationChannel(
            NotificationChannel(
                LEGACY,
                "إشعارات سنتر الشطرة (قديم)",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "إشعارات الطلبات والتوصيل"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 150, 250)
                setSound(Settings.System.DEFAULT_NOTIFICATION_URI, attrs)
                enableLights(true)
                setShowBadge(true)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            }
        )
    }
}

class MainActivity : FlutterActivity() {

    /**
     * إنشاء كل قنوات الإشعارات مرة واحدة عند فتح التطبيق.
     * كل قناة لها نغمتها الخاصة ⇒ الإشعار يصدر صوته حتى والتطبيق مغلق.
     * (تُنشأ أيضاً في StrasopaApplication عند إقلاع العملية، فحتى لو
     *  وصلت رسالة والتطبيق مغلق كانت القناة موجودة مسبقاً.)
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyScreenSecurity()
        // ★ بناء الأدمن لا يُنشئ قنوات الزبائن (طلب جديد/توصيل/…): كانت
        //   تزدحم بها إعدادات الإشعارات بلا أي فائدة، فالإشعارات لا تُرسل
        //   لهذا التطبيق أصلاً.
        if (!BuildConfig.IS_ADMIN_APP) {
            getSystemService(NotificationManager::class.java)?.let {
                NotifyChannels.createAll(applicationContext, it)
            }
        }
        captureNotificationIntent(intent)
    }

    /**
     * ★★ حماية الشاشة — وظيفتان أصليتان بلا أي حزمة خارجية.
     *
     * FLAG_SECURE: يمنع التقاط الشاشة كلياً ويجعل المحتوى أسود في
     *   لقطات الشاشة والعرض على شاشة ثانية. بدونه، حقل كلمة السر أو
     *   كود التحقق يظهر مصغّراً في قائمة التطبيقات، أو في لقطة يشاركها
     *   المستخدم. لا رادّ لهذا إلا بكود أصلي.
     *
     * FLAG_SECURE فحسب كان في إصدارات سابقة ظهرت فيه لقطة النافذة،
     * لذا نجمعه مع إخفاء المهمة من «المبدّل» و`setRecentsScreenshotEnabled(false)`.
     *
     * القيد الجانبي: يمنع المستخدم من لقطة الشاشة عمداً (مثلاً لإرسال فاتورة).
     * ★ 2026-10-11: بطلب صريح منه («اجعل التطبيق ياخذ سكرين») صار الافتراضي
     *   السماح باللقطة، والمنع يُستعاد ببناء `SHTR_ALLOW_SCREEN_CAPTURE=false`.
     *   ما يبقى مفعّلاً دائماً في هذه الدالة: `filterTouchesWhenObscured`
     *   (منع tapjacking) — لأنه لا علاقة له باللقطة ولا يمنعها.
     */
    private fun applyScreenSecurity() {
        val allowCapture = BuildConfig.ALLOW_SCREEN_CAPTURE
        if (allowCapture) {
            Log.i(TAG, "FLAG_SECURE skipped: screenshot allowed by request")
        }
        try {
            if (!allowCapture && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            // إخفاء التطبيق من قائمة المهام: لا لقطة مصغّرة تتسرّب.
            val attrs = window.attributes
            if (!allowCapture) {
                attrs.flags = attrs.flags or WindowManager.LayoutParams.FLAG_SECURE
            }
            window.attributes = attrs
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                // يمنع عرض نافذة التطبيق فوق غيره (tapjacking): تطبيق خبيث
                // يعرض طبقة شفافة فوق حقل كلمة السر فيلتقط الضغطات.
                // دالة على View لا على Activity، فنعطيها جذر النافذة.
                window.decorView.filterTouchesWhenObscured = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "screen security unavailable: ${e.message}")
        }
    }

    /**
     * التقاط extras الإشعار من نية الإقلاع (الضغط على إشعار والتطبيق
     * مغلق/مُقتل) وتخزينها في [FcmLaunchStore] ليسترجعها محرك Flutter.
     */
    private fun captureNotificationIntent(intent: Intent?) {
        if (intent == null) return
        val extras = intent.extras ?: return
        val orderId = extras.getString("orderId").orEmpty()
        val link = extras.getString("link").orEmpty()
        val title = extras.getString("gcm.n.title")
            ?: extras.getString("notification_title")
            ?: extras.getString("title").orEmpty()
        // نقرة على إشعار FCM تحمل دائماً google.message_id أو نوع الإشعار.
        val looksLikeNotification = extras.containsKey("google.message_id") ||
            extras.containsKey("gcm.n.e") ||
            orderId.isNotEmpty() ||
            link.isNotEmpty()
        if (!looksLikeNotification) return

        FcmLaunchStore.stash(
            orderId = orderId,
            status = (extras.getString("status") ?: extras.getString("kind")).orEmpty(),
            title = title,
            body = extras.getString("gcm.n.body")
                ?: extras.getString("notification_body")
                ?: extras.getString("body").orEmpty(),
            link = link,
            serial = extras.getString("serial").orEmpty()
        )
    }

    /**
     * جسر Dart: يقرأ محرّك Flutter حمولة الإشعار التي التقطها
     * [FcmLaunchStore] (الضغط على إشعار والتطبيق مغلق/مُقتل).
     *
     * место التسجيل الصحيح هو هنا — لا في `Application` — لأن محرك
     * Flutter غير متاح قبل إنشاء الـ Activity.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FCM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeLaunchPayload" -> result.success(FcmLaunchStore.consume())
                    else -> result.notImplemented()
                }
            }

        // قناة مراقبة الخلفية: Dart يطلب start/stop، والخدمة الأمامية
        // تستدعي `tick` كل دقيقة عبر نفس القناة (MonitorBridge).
        val bg = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BG_CHANNEL)
        bg.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    BackgroundMonitorService.start(applicationContext)
                    result.success(true)
                }
                "stop" -> {
                    BackgroundMonitorService.stop(applicationContext)
                    result.success(true)
                }
                // Dart يؤكد استلام `tick` ⇒ الجسر حيّ، فلا استطلاع أصلي.
                "tickAck" -> {
                    MonitorBridge.ack()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MonitorBridge.attach(flutterEngine, bg)

        // ══ قناة إعدادات الإشعارات ══
        // goal: قراءة النغمة التي اختارها المستخدم فعلياً في إعدادات
        // الهاتف لكل قناة، و فتح تلك الإعدادات مباشرة.
        // على أندرويد صوت القناة لا يُغيّره التطبيق بعد إنشائها
        // (إعداد يثبّته المستخدم)، فهذه هي الطريقة الصحيحة لاحترام
        // اختياره ثم عرضه/حفظه داخل التطبيق.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SETTINGS)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAppNotificationSettings" -> {
                        openAppNotificationSettings()
                        result.success(true)
                    }
                    "openChannelSettings" -> {
                        val id = call.argument<String>("channelId")
                        if (id == null) {
                            result.error("bad_args", "channelId مطلوب", null)
                        } else {
                            openChannelSettings(id)
                            result.success(true)
                        }
                    }
                    "channelSounds" -> result.success(readChannelSounds())
                    // ★ حالة الأذونات — أساس «لماذا لا يصل الشعار؟»
                    //   طلب POST_NOTIFICATIONS يُرفض مرة فيبقى الإذن
                    //   مسحوباً بصمت، وFCM يُسقط الرسالة رغم نجاح الإرسال.
                    "appNotificationsEnabled" ->
                        result.success(appNotificationsEnabled())
                    "batteryUnrestricted" ->
                        result.success(batteryUnrestricted())
                    "openBatterySettings" -> {
                        openBatterySettings()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * يقرأ النغمة الفعلية لكل قناة إشعار كما ضبطها المستخدم في
     * إعدادات الهاتف (وليس ما نضعه نحن افتراضياً).
     *
     * النتيجة: `Map<channelId, اسم النغمة>` والقيمة `null` تعني
     * "نغمة النظام الافتراضية".
     */
    private fun readChannelSounds(): Map<String, String?> {
        val out = HashMap<String, String?>()
        val m = getSystemService(NotificationManager::class.java) ?: return out
        val ids = listOf(
            NotifyChannels.NEW_ORDER, NotifyChannels.ACCEPTED,
            NotifyChannels.DELIVERING, NotifyChannels.REJECTED,
            NotifyChannels.REPLACED, NotifyChannels.DELIVERED,
            NotifyChannels.ALERT,
        )
        for (id in ids) {
            val ch = try { m.getNotificationChannel(id) } catch (e: Exception) { null }
            out[id] = ch?.sound?.toString()
        }
        return out
    }

    /** هل النظام يسمح لهذا التطبيق بعرض الإشعارات الآن؟ */
    private fun appNotificationsEnabled(): Boolean {
        val m = getSystemService(NotificationManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            m.areNotificationsEnabled()
        } else {
            true
        }
    }

    /** هل التطبيق خارج قائمة تحسين/تقييد البطارية (بدون هذا تُقتل الخلفية)؟ */
    private fun batteryUnrestricted(): Boolean = try {
        val pm = getSystemService(android.os.PowerManager::class.java)
        pm?.isIgnoringBatteryOptimizations(packageName) ?: true
    } catch (_: Exception) {
        true
    }

    /**
     * يفتح قائمة «تحسين البطارية» في النظام ليختار المستخدم «غير مقيّد».
     * نستعمل صفحة القائمة العامة لا نافذة «اسمح دائماً» المباشرة،
     * فلا نحتاج إذن REQUEST_IGNORE_BATTERY_OPTIMIZATIONS المحظور في Play.
     */
    private fun openBatterySettings() {
        try {
            startActivity(
                Intent(android.provider.Settings
                    .ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Exception) {
            try {
                startActivity(
                    Intent(android.provider.Settings.ACTION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (_: Exception) {
            }
        }
    }

    /** يفتح صفحة إشعارات التطبيق في إعدادات الهاتف. */
    private fun openAppNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", packageName, null))
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (e: Exception) {
            // fallback: صفحة التطبيق العامة
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(Uri.fromParts("package", packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {}
        }
    }

    /** يفتح إعدادات قناة إشعار بعينها (يختار فيها المستخدم النغمة). */
    private fun openChannelSettings(channelId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            openAppNotificationSettings()
            return
        }
        val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (e: Exception) {
            openAppNotificationSettings()
        }
    }

    /**
     * ★ لا تُهدر محرك Flutter عند تدمير الـ Activity.
     *
     * بدون هذا، ينتهي المحرك (ومعها Dart) لحظة خروج المستخدم من
     * التطبيق ⇒ تصير الخدمة الأمامية بلا كود Dart تنفّذه. ببقائه
     * الحيّ تستطيع الخدمة استدعاء `pollNotificationsOnce()` كل دقيقة
     * والتطبيق مغلق تماماً.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    /** Intent جديد والتطبيق يعمل أصلاً (singleTop) — نلتقط extras أيضاً. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureNotificationIntent(intent)
    }

    companion object {
        private const val TAG = "MainActivity"

        private const val FCM_CHANNEL = "strasopa/fcm_launch"

        /** مطابقة لـ MethodChannel في lib/services/background_poller.dart */
        private const val BG_CHANNEL = "strasopa/bg_monitor"

        /** مطابقة لـ lib/services/notification_channel_settings.dart */
        private const val CHANNEL_SETTINGS = "strasopa/notification_channels"
    }
}
