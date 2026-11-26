package com.saydaliti.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * نغمة الإشعارات التي يختارها المستخدم من أصوات هاتفه.
 *
 * ★ لماذا قناة جديدة بطرف جديد (channelId مشتق من النغمة)؟
 *   أندرويد لا يسمح بتغيير صوت القناة بعد إنشائها، وحتى لو حُذفت
 *   وأُنشئت بنفس المعرّف فالنظام «يُحييها» بإعداداتها القديمة.
 *   الحل الوحيد الموثوق: معرّف جديد لكل نغمة، ثم حذف معرّف النغمة
 *   السابقة ⇒ لا يبقى صوتها القديم يرنّ من هذه القنوات.
 *
 * ★ الحفظ على الجهاز فقط: SharedPreferences نفسه ملف
 *   `FlutterSharedPreferences`، والمفاتيح تبدأ بـ`flutter.` حتى
 *   يقرأها Dart (shared_preferences) بنفس الأسماء، فيراها العزل
 *   الخلفي والخدمة الأصلية بلا مرور عبر محرك Flutter.
 */
object NotificationSounds {
    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY_URI = "flutter.custom_sound_uri"
    private const val KEY_TITLE = "flutter.custom_sound_title"
    private const val KEY_CHANNEL = "flutter.custom_channel_id"

    /** نغمة صامتة — يُنشأ لها قناة بلا صوت. */
    const val SILENT_URI = "silent"

    /** اسم القناة كما يظهر في إعدادات النظام. */
    const val LABEL = "نغمة الإشعارات"

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** معرّف القناة المخصّصة الحالية، أو null = نغمة التطبيق. */
    fun channelId(ctx: Context): String? {
        val v = prefs(ctx).getString(KEY_CHANNEL, null)
        return if (v.isNullOrEmpty()) null else v
    }

    fun title(ctx: Context): String {
        val v = prefs(ctx).getString(KEY_TITLE, null).orEmpty().trim()
        return if (v.isEmpty()) LABEL else v
    }

    fun uri(ctx: Context): String? = prefs(ctx).getString(KEY_URI, null)

    private fun attrs(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    /**
     * قائمة أصوات الإشعارات من الهاتف: نغمة النظام + صامت + كل
     * الأصوات الظاهرة في منتقي نغمات النظام (`TYPE_NOTIFICATION`).
     */
    fun list(ctx: Context): List<Map<String, String>> {
        val out = ArrayList<Map<String, String>>()
        out.add(
            mapOf(
                "title" to "نغمة النظام",
                "uri" to (RingtoneManager.getDefaultUri(
                    RingtoneManager.TYPE_NOTIFICATION,
                )?.toString() ?: ""),
            ),
        )
        out.add(mapOf("title" to "صامت", "uri" to SILENT_URI))
        val seen = HashSet<String>()
        seen.add(out[0]["uri"].orEmpty())
        try {
            val rm = RingtoneManager(ctx)
            rm.setType(RingtoneManager.TYPE_NOTIFICATION)
            val c = rm.cursor
            while (c.moveToNext()) {
                val uri = rm.getRingtoneUri(c.position)?.toString() ?: continue
                if (uri.isEmpty() || !seen.add(uri)) continue
                val title = try {
                    c.getString(RingtoneManager.TITLE_COLUMN_INDEX)
                } catch (_: Exception) {
                    null
                }
                out.add(
                    mapOf(
                        "title" to (title ?: "نغمة"),
                        "uri" to uri,
                    ),
                )
            }
            try {
                c.close()
            } catch (_: Exception) {
            }
        } catch (_: Exception) {
            // منتقي النظام غير متاح ⇒ تبقى نغمة النظام والصامت.
        }
        return out
    }

    /**
     * يطبّق النغمة: يُنشئ قناة جديدة بصوتها، ويحذف قناة النغمة
     * السابقة (كتم صوت القديم)، ويحفظ الاختيار على الجهاز.
     * يعيد معرّف القناة، أو null قبل أندرويد 8.
     */
    fun apply(ctx: Context, uriText: String, title: String): String? {
        val id = channelIdFor(uriText)
        val old = channelId(ctx)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = ctx.getSystemService(NotificationManager::class.java)
            if (mgr != null) {
                createChannel(mgr, id, uriText, title)
                // كتم صوت القناة السابقة: تُحذف فلا تُستعمل مرة أخرى.
                if (!old.isNullOrEmpty() && old != id) {
                    try {
                        mgr.deleteNotificationChannel(old)
                    } catch (_: Exception) {
                    }
                }
            }
        }

        prefs(ctx).edit()
            .putString(KEY_URI, uriText)
            .putString(KEY_TITLE, title)
            .putString(KEY_CHANNEL, id)
            .apply()
        return id
    }

    private fun channelIdFor(uriText: String): String =
        "strasopa_snd_" +
            Integer.toHexString((uriText.ifEmpty { "silent" }).hashCode() and 0x7fffffff)

    private fun createChannel(
        mgr: NotificationManager,
        id: String,
        uriText: String,
        title: String,
    ) {
        val silent = uriText == SILENT_URI
        val ch = NotificationChannel(id, LABEL, NotificationManager.IMPORTANCE_HIGH)
        ch.description = if (silent) "إشعارات صامتة" else "النغمة المختارة: $title"
        if (silent) {
            ch.setSound(null, null)
            ch.enableVibration(false)
        } else {
            ch.setSound(Uri.parse(uriText), attrs())
            ch.enableVibration(true)
            ch.vibrationPattern = longArrayOf(0, 250, 150, 250)
        }
        ch.setShowBadge(true)
        ch.lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        mgr.createNotificationChannel(ch)
    }

    /**
     * احتياط الإقلاع: لو استُعيدت الإعدادات على جهاز جديد (نسخ احتياطي)
     * بلا قنواتها، أو حُذفت القناة، نُعيد إنشاء قناة الاختيار بصوتها
     * حتى لا يُعرض إشعار على قناة غير موجودة (النظام يُسقطه).
     */
    fun ensure(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val id = channelId(ctx) ?: return
        val uriText = uri(ctx) ?: return
        val mgr = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(id) != null) return
        createChannel(mgr, id, uriText, title(ctx))
    }

    /** إرجاع التطبيق لنغمته الافتراضية (حذف القناة المخصّصة). */
    fun clear(ctx: Context) {
        val mgr = ctx.getSystemService(NotificationManager::class.java)
        val old = channelId(ctx)
        if (mgr != null && !old.isNullOrEmpty()) {
            try {
                mgr.deleteNotificationChannel(old)
            } catch (_: Exception) {
            }
        }
        prefs(ctx).edit()
            .remove(KEY_URI)
            .remove(KEY_TITLE)
            .remove(KEY_CHANNEL)
            .apply()
    }

    private var ringtone: Ringtone? = null
    private val handler = Handler(Looper.getMainLooper())
    private val stopTask = Runnable { stopPreview() }

    /** معاينة نغمة (صوت واحد في كل مرة، يتوقف وحده بعد ثوانٍ). */
    fun preview(ctx: Context, uriText: String) {
        stopPreview()
        if (uriText.isEmpty() || uriText == SILENT_URI) return
        try {
            val rt = RingtoneManager.getRingtone(ctx, Uri.parse(uriText)) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                rt.isLooping = false
                rt.audioAttributes = attrs()
            }
            ringtone = rt
            rt.play()
            handler.postDelayed(stopTask, 5000)
        } catch (_: Exception) {
        }
    }

    fun stopPreview() {
        handler.removeCallbacks(stopTask)
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
    }
}
