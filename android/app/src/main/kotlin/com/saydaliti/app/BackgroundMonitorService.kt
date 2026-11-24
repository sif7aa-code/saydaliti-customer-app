package com.saydaliti.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * جسر بين الخدمة الأمامية ومحرك Flutter.
 *
 * الخدمة الأمامية تعمل في نفس العملية لكن خارج الـ Activity، فلن يجد
 * محرك Flutter بنفسه. الحل: نُبقي مرجعاً ثابتاً للمحرك والقناة بعد
 * تسجيلهما في [MainActivity.configureFlutterEngine]، فتقدر الخدمة
 * استدعاء Dart بـ `tick` في أي لحظة.
 */
object MonitorBridge {

    private const val CHANNEL = "strasopa/bg_monitor"
    private const val TAG = "StrasopaBg"

    @Volatile
    private var channel: MethodChannel? = null

    /** آخر لحظة أثبت فيها Dart أنه حيّ (يستجيب لـ`tick`). */
    @Volatile
    private var lastAckAt: Long = 0L

    /**
     * مهلة اعتبار الجسر ميتاً: بعدها يتحول الاستطلاع إلى الأصل.
     * ضعف أكبر فاصل (٦٠ث) تقريباً، فجولة أو جلستان ضائعتان لا
     * تُعلنان موتاً كاذباً (فتظهر الإشعارات مرتين).
     */
    private const val ACK_TIMEOUT_MS = 150_000L

    /** تُستدعى من MainActivity مباشرة بعد تسجيل القناة. */
    fun attach(engine: FlutterEngine, ch: MethodChannel) {
        channel = ch
        lastAckAt = System.currentTimeMillis()
    }

    /** Dart يستجيب لنداء `tick` ⇒ الجسر حيّ. */
    fun ack() {
        lastAckAt = System.currentTimeMillis()
    }

    fun recentlyAcked(): Boolean =
        System.currentTimeMillis() - lastAckAt < ACK_TIMEOUT_MS

    /**
     * استدعاء `tick` على Dart. يعيد true إن وُجدت قناة.
     *
     * `try/catch` مقصود: إن لم يكن المحرك جاهزاً (الخدمة بدأت من
     * BOOT_COMPLETED قبل فتح التطبيق) نتخطى الجولة بهدوء.
     */
    fun tick(): Boolean {
        return try {
            val ch = channel ?: return false
            ch.invokeMethod("tick", null)
            true
        } catch (e: Exception) {
            Log.w(TAG, "tick failed: ${e.message}")
            false
        }
    }
}

/**
 * خدمة أمامية (Foreground Service) تُبقي التطبيق حيّة وتستدعي
 * استطلاع الإشعارات كل دقيقة عبر `MonitorBridge`.
 *
 * لماذاForeground Service؟
 *  - إشعار فوري حقيقي: التكرار كل دقيقة (٦٠ ثانية).
 *  - `workmanager` لا يُبنى مع Gradle/Flutter الحالي، وحدّه ١٥ دقيقة.
 *  - الخدمة الأمامية على أندرويد ٨+ تُمنح مناعة Doze جزئياً، فالنتيجة
 *    استطلاع منتظم حتى والجهاز في وضع موفّر الطاقة.
 *
 * ملاحظة: On Android 14+ يلزم تحديد foregroundServiceType + إذن
 * `FOREGROUND_SERVICE_DATA_SYNC`. استعملنا `dataSync`.
 */
class BackgroundMonitorService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var running = false

    /** نداء الاستطلاع — والفاصل يُقاس في كل جولة لأنه يتغيّر بعد الدخول. */
    private val tick: Runnable = object : Runnable {
        override fun run() {
            if (!running) return
            val reached = MonitorBridge.tick()
            // ★ الجسر ميت (لا محرك، أو Dart لا يستجيب) ⇒ نستطلع أصلياً:
            //   نفس الطابور ونفس القنوات، بلا حاجة لأي كود Flutter.
            //   بدون هذا السطر كانت الخدمة «حيّة» لكن محركها مهدوم فلا
            //   يصل إشعار ما دام التطبيق مقتولاً.
            if (!reached || !MonitorBridge.recentlyAcked()) {
                NativePoller.pollAsync(this@BackgroundMonitorService)
            }
            handler.postDelayed(this, intervalMs(this@BackgroundMonitorService))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        alive = true
        // ★ Android 14+ يفرض `foregroundServiceType` معلناً في المانيفست؛
        //   هذا هو نوع dataSync المعلن. إن رفض النظام التشغيل (إذن مفقود
        //   أو حظر خلفية) يسقط الاستثناء هنا فتبقى بقية المسارات.
        try {
            startForeground(NOTIF_ID, buildNotification())
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed: ${e.message}")
            alive = false
            return
        }
        // نداء فوري بعد ثوانٍ ⇒ الإشعار يصل بلا انتظار دقيقة كاملة،
        // ثم ندخل في حلقة كل دقيقة.
        handler.postDelayed(tick, FIRST_DELAY_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // إعادة التشغيل التلقائي إن أوقفها النظام (ذاكرة ضيقة).
        if (!running) {
            running = true
            alive = true
            try {
                startForeground(NOTIF_ID, buildNotification())
            } catch (e: Exception) {
                Log.w(TAG, "restart startForeground failed: ${e.message}")
                alive = false
                return START_NOT_STICKY
            }
            handler.post(tick)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        alive = false
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    /**
     * أندرويد ١٥+ يحدّ خدمة `dataSync` بخمس أو ست ساعات في الخلفية،
     * ثم ينادي هذه الدالة. عدم الإيقاف هنا يعني استثناء نظام يقتل
     * التطبيق؛ فنوقف الخدمة بهدوء، ويبقى FCM يعمل، وتُعاد الخدمة
     * عند أول فتح للتطبيق.
     */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int) {
        Log.i(TAG, "dataSync time limit reached — stopping service")
        stopSelf()
    }

    /**
     * إشعار الخدمة الدائمة: صامت ومنخفض الأهمية (لا يزعج ولا يظهر
     * heads-up)، هدفه فقط إبقاء العملية حيّة — الإشعارات الحقيقية
     * تصل عبر قنوات `NotifyChannels`.
     */
    private fun buildNotification(): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = open?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val b = Notification.Builder(this, BG_CHANNEL_ID)
            .setContentTitle("عمل التطبيق في الخلفية")
            .setContentText("يُبقي استقبال الإشعارات يعمل باستمرار")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setShowWhen(false)
            // صامت تماماً: بلا صوت وبلا اهتزاز (القناة IMPORTANCE_MIN تكفي،
            // وsetSilent متاح من API 26 فقط فنتحقق من الإصدار).
            .setDefaults(0)
            .setPriority(Notification.PRIORITY_MIN)
            .setVibrate(LongArray(0))
            .setSound(null)
        if (pi != null) b.setContentIntent(pi)
        return b.build()
    }

    companion object {
        private const val TAG = "StrasopaBgSvc"
        private const val NOTIF_ID = 7717
        private const val BG_CHANNEL_ID = "strasopa_bg_service"
        // ★ 2026-11-06 (طلبه: «اجعل التطبيق يعمل في الخلفية دائما
        //   كالسابق يستقبل اشعارات ويرسل خارجيات او داخليات»): الخدمة
        //   تعمل **دائماً** لكل حساب مسجَّل دخوله، بلا استثناء — عكس
        //   قرار 11-02 الذي كان يُطفئها كلياً عن كل هاتف يصله FCM.
        //   الذي يتغيّر هو **الفاصل** وحده:
        //   · هاتف لا يصله FCM (بلا خدمات جوجل، أو توكن لم يُسجَّل بعد)
        //     ⇒ ١٠ ثوانٍ، لأن الاستطلاع مساره الحقيقي الوحيد.
        //   · هاتف يصله FCM ⇒ ٦٠ ثانية، لأن الإشعار يأتيه من الخادم
        //     بأقل من ثانية والاستطلاع شبكة أمان. لو بقي ١٠ ثوانٍ على
        //     كل الهواتف لصار ٨٦٤٠ طلباً في اليوم للهاتف الواحد، وهي
        //     تُحسب من باقة Supabase المجانية (٥ جيجا) فتُستنزف.
        private const val INTERVAL_MS = 10_000L          // ١٠ ثوانٍ
        private const val INTERVAL_PUSH_OK_MS = 60_000L  // دقيقة
        private const val FIRST_DELAY_MS = 1_500L        // أول نداء بعد ١.٥ ثانية

        @Volatile
        private var started = false

        /// ★ هل الخدمة **حيّة فعلاً** الآن؟
        ///
        /// الفرق بينها وبين `started`: كانت `started` تُضبط مرة واحدة
        /// عند أول تشغيل ولا تُصفَّر أبداً — فحين يوقف النظام الخدمة
        /// (ميزانية `dataSync` على أندرويد ١٤+: ست ساعات في اليوم، أو
        /// ضغط ذاكرة، أو حماية البطارية عند بعض المصنّعين) يبقى الطلب
        /// التالي من Dart بلا أي أثر: `if (started) return`.
        /// النتيجة العملية كانت «الإشعارات تكفّ بعد ساعات من فتح
        /// التطبيق». الآن العلامة تُطفأ في `onDestroy`، فأي نداء
        /// `start` لاحق — وكل فتح للتطبيق — يعيد إحياء الخدمة.
        @Volatile
        private var alive = false

        /** قناة صامتة منخفضة الأهمية لإشعار الخدمة الدائمة. */
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val m = context.getSystemService(NotificationManager::class.java) ?: return
            if (m.getNotificationChannel(BG_CHANNEL_ID) != null) return
            val ch = android.app.NotificationChannel(
                BG_CHANNEL_ID,
                "تشغيل في الخلفية",
                NotificationManager.IMPORTANCE_MIN
            )
            ch.description = "إشعار صامت لإبقاء استقبال الإشعارات يعمل"
            ch.setShowBadge(false)
            m.createNotificationChannel(ch)
        }

        /**
         * هل يصل هذا الجهاز خبر من الخادم بلا أي تشغيل منّا؟
         *
         * ★ 2026-11-06: لم تعد تُستعمل لإطفاء الخدمة (قرار 11-02 معكوس) —
         *   الخدمة تعمل دائماً. بقيت العلامة لتحديد **الفاصل** فقط: من
         *   يصله FCM يُستطلَع كل دقيقة، ومن لا يصله كل ١٠ ثوانٍ.
         *
         *   `NotificationCenter._loadBrand` في دارت يكتب هذه العلامة بعد
         *   أن يتأكد أن للحساب توكن FCM مسجّلاً عند الخادم.
         *
         *   القراءة من ملف التفضيلات نفسه لأن الخدمة تُشغَّل من أصلين لا
         *   يمرّان بـ دارت: إقلاع العملية (`StrasopaApplication`) وإقلاع
         *   الهاتف (`BootReceiver`).
         */
        private fun pushReachesThisPhone(context: Context): Boolean = try {
            context.applicationContext
                .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.notify_push_deliverable", false)
        } catch (e: Exception) {
            // قراءة متعثّرة ⇒ نعتبر أن FCM لا يبلغه، فيبقى الفاصل السريع:
            // إشعار ضائع أسوأ من استطلاع زائد.
            false
        }

        /** الفاصل الحيّ لكل جولة: ١٠ ثوانٍ لمن لا يصله FCM، ودقيقة لمن يصله. */
        private fun intervalMs(context: Context): Long =
            if (pushReachesThisPhone(context)) INTERVAL_PUSH_OK_MS else INTERVAL_MS

        /** تشغيل الخدمة (idempotent، ويُحييها إن أوقفها النظام). */
        fun start(context: Context) {
            if (started && alive) return
            started = true
            try {
                ensureChannel(context)
                val intent = Intent(context, BackgroundMonitorService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(TAG, "monitor service started")
            } catch (e: Exception) {
                started = false
                alive = false
                Log.w(TAG, "start failed: ${e.message}")
            }
        }

        /** إيقاف الخدمة. */
        fun stop(context: Context) {
            started = false
            alive = false
            try {
                context.stopService(Intent(context, BackgroundMonitorService::class.java))
            } catch (_: Exception) {}
        }
    }
}

/**
 * يعيد تشغيل الخدمة بعد إعادة تشغيل الجهاز (أو تحديث التطبيق)،
 * وإلا بقي التطبيق ميّتة حتى يفتحه المستخدم يدوياً.
 */
class BootReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val a = intent.action ?: return
        if (a == Intent.ACTION_BOOT_COMPLETED ||
            a == Intent.ACTION_MY_PACKAGE_REPLACED ||
            a == "android.intent.action.QUICKBOOT_POWERON"
        ) {
            // ★ Android 15+ (targetSdk 35+): تشغيل خدمة أمامية من نوع
            //   dataSync داخل مستقبِل BOOT_COMPLETED **ممنوع** من النظام،
            //   ويُسقط التطبيق عند إقلاع الهاتف (ForegroundServiceStartNotAllowed
            //   Exception — أعطال Play Vitals في 1.7.51، ٦٠٪ منها هذه الحالة).
            //   على هذه الإصدارات نترك الإشعارات لـ FCM (يعمل بلا خدمة)،
            //   وتُشغَّل المراقبة طبيعياً عند أول فتح للتطبيق من MainActivity.
            //   أجهزة أندرويد ١٤ وأقدم تبقي السلوك القديم بلا تغيير.
            if (Build.VERSION.SDK_INT >= 35) {
                Log.i("StrasopaBgSvc", "boot start skipped on Android 15+ (system ban)")
                return
            }
            BackgroundMonitorService.start(context.applicationContext)
        }
    }
}
