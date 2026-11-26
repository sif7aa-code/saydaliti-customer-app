package com.saydaliti.app

import android.app.Application
import android.app.NotificationManager
import android.util.Log

/**
 * إنشاء قنوات الإشعارات عند إقلاع العملية — لا عند فتح Activity فقط.
 *
 * لماذا هذا مهم لحالة «التطبيق مغلق»؟
 *  - `MainActivity.onCreate` يعمل فقط عند فتح واجهة. لو كان التطبيق
 *    مغلقاً/مُقتلاً ووصلت رسالة، فإن Android يبحث عن القناة بمعرّف
 *    `default_notification_channel_id` من المانيفست؛ فإن لم تكن موجودة
 *    أنشأ النظام قناة افتراضية **بأهمية LOW** ⇒ الإشعار يصل بلا صوت،
 *    أو لا يظهر كإشعار heads-up إطلاقاً.
 *  - إنشاء القنوات هنا يضمن وجودها بمعرّفها وأهمية `HIGH` قبل أن تصل
 *    أول رسالة، لأن `Application.onCreate` يسبق أي استقبال لـ FCM في
 *    نفس العملية.
 *
 * ملاحظة: إنشاء القناة عملية آمنة للتكرار (idempotent) — تستدعيها
 * `MainActivity` أيضاً، والجسر مع Dart مسجَّل في `MainActivity`
 * (لأنه يحتاج محرك Flutter، وهو غير متاح هنا).
 */
class StrasopaApplication : Application() {

    override fun onCreate() {
        super.onCreate()

        // ★ بناء «الشطرة أدمن» (SHTR_ADMIN_APP=true): لا إشعارات ولا خدمة
        //   خلفية إطلاقاً. اللوحة أداة عمل تُفتح عند الحاجة وتُغلق، فإشعار
        //   «عمل التطبيق في الخلفية» الدائم فيها بلا فائدة وبلا معنى.
        //   قناة الأدمن صامتة حتى لا يرنّ النظام لها بلا سبب.
        if (BuildConfig.IS_ADMIN_APP) {
            try {
                val mgr = getSystemService(NotificationManager::class.java)
                if (mgr != null &&
                    android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                    mgr.getNotificationChannel("strasopa_admin_silent") == null
                ) {
                    mgr.createNotificationChannel(
                        android.app.NotificationChannel(
                            "strasopa_admin_silent",
                            "لوحة التحكم",
                            NotificationManager.IMPORTANCE_LOW
                        ).apply {
                            description = "قناة صامتة — لوحة الأدمن لا تحتاج تنبيهات"
                            setShowBadge(false)
                        }
                    )
                }
            } catch (_: Exception) {}
            Log.i("StrasopaApp", "admin panel build: notifications and bg monitor skipped")
            return
        }

        try {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager != null) {
                NotifyChannels.createAll(this, manager)
                // قناة نغمة المستخدم (إن اختار واحدة) — تُعاد إن غابت.
                NotificationSounds.ensure(this)
                // قناة صامتة لإشعار الخدمة الأمامية الدائم.
                BackgroundMonitorService.ensureChannel(this)
            }
        } catch (e: Exception) {
            Log.e("StrasopaApp", "channel creation failed: ${e.message}")
        }

        // ★ تشغيل خدمة المراقبة الخلفية.
        // نبدأها مع كل إقلاع عملية (حتى لو فتحها النظام بعد إعادة
        // التشغيل) ⇒ الإشعارات تُستطلَب كل دقيقة والتطبيق مغلق.
        // تعمل فقط إن كان المستخدم مسجّل دخوله: الاستطلاع نفسه يتحقق
        // من `auth_logged_in` ويخرج بهدوء إن لم يكن هناك حساب.
        try {
            BackgroundMonitorService.start(this)
        } catch (e: Exception) {
            Log.w("StrasopaApp", "bg monitor start failed: ${e.message}")
        }
    }
}
