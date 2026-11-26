package com.saydaliti.app

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * استطلاع الإشعارات من داخل الخدمة الأمامية **بلا محرك Flutter**.
 *
 * لماذا؟ لأن جسر `MonitorBridge` يمرّ بـ Dart. إن قُتلت العملية
 * (توفير بطارية، مصنّع يخنق الخلفية) وأعاد النظام تشغيل الخدمة،
 * فلا محرك ولا Dart ⇒ `tick` يذهب هباءً وتبقى الإشعارات في
 * الطابور حتى يفتح المستخدم التطبيق. هذا المستطلع يقرأ نفس الطابور
 * مباشرةً (دالتا `get_my_notifications` و`delete_my_notification`
 * المحميّتان) ويعرض الإشعارات بنفس القنوات والأصوات.
 *
 * قواعد مطابقة لطبقة Dart كي لا يتكرر الإشعار:
 *  · صفّ عليه `pushed_at` ⇒ النظام عرضه عبر FCM ⇒ لا نعرضه.
 *  · صفّ أقدم من ست ساعات ⇒ نتركه للاستطلاع داخل التطبيق (لا نوقظ
 *    المستخدم بخبر قديم).
 *  · بعد العرض نحذف الصف من الطابور ونحفظ معرّفه احتياطاً.
 *  · الإشعارات معطّلة في النظام (الأذن مسحوب) ⇒ لا نعرض ولا نحذف
 *    شيئاً، فالبلاغ لا يضيع من جرص التطبيق.
 */
object NativePoller {
    private const val TAG = "StrasopaNativePoll"
    private const val BASE = "https://piepmqbqdxhnsbynjgmg.supabase.co/rest/v1/"
    private const val ANON =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBpZXBtcWJxZHhobnNieW5qZ21nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ4NDU3MTgsImV4cCI6MjExMDQyMTcxOH0.2agUSLhTVGpBng0tNZ6cx-UX9bbDa03FbFwPMe-vNLI"

    /** مفاتيح دارت للدخول والرقم (ملف shared_preferences نفسه). */
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val K_LOGGED_IN = "flutter.auth_logged_in"
    private const val K_PHONE = "flutter.auth_phone"

    /** مخزن خاص بالمستطلع: منع تكرار العرض لو فشل حذف الصف. */
    private const val OWN_PREFS = "strasopa_native_poll"
    private const val K_SEEN = "seen_ids"
    private const val MAX_SEEN = 250

    /** أقدم من هذا ⇒ ليس خبراً آنياً: يظهر في جرس التطبيق عند فتحه. */
    private const val MAX_AGE_MS = 6L * 60 * 60 * 1000

    private val busy = AtomicBoolean(false)
    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, "native-notify-poll").apply { isDaemon = true }
    }

    fun pollAsync(context: Context) {
        if (!busy.compareAndSet(false, true)) return
        val app = context.applicationContext
        io.execute {
            try {
                pollOnce(app)
            } catch (e: Exception) {
                Log.w(TAG, "poll failed: ${e.message}")
            } finally {
                busy.set(false)
            }
        }
    }

    private fun pollOnce(context: Context) {
        val flutter = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        if (!flutter.getBoolean(K_LOGGED_IN, false)) return
        val phone = flutter.getString(K_PHONE, "")?.trim().orEmpty()
        if (phone.isEmpty()) return

        // الأذن مسحوب؟ لا معنى للعرض ولا للحذف.
        val mgr = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !mgr.areNotificationsEnabled()) {
            return
        }

        val raw = rpc(
            "get_my_notifications",
            JSONObject().put("p_phone", phone).toString(),
        ) ?: return
        val rows = try {
            JSONArray(raw)
        } catch (_: Exception) {
            return
        }
        if (rows.length() == 0) return

        val seen = own(context).getStringSet(K_SEEN, emptySet()) ?: emptySet()
        val added = mutableSetOf<String>()
        val now = System.currentTimeMillis()

        // الدالة تُرجع الأحدث أولاً؛ نعرض من الأقدم للأحدث كي يبقى
        // الأحدث في أعلى شريط الإشعارات.
        for (i in (rows.length() - 1) downTo 0) {
            val row = try {
                rows.getJSONObject(i)
            } catch (_: Exception) {
                continue
            }
            val id = row.optString("id").trim()
            if (id.isEmpty() || seen.contains(id)) continue

            // FCM أُرسل لهذا الصف ⇒ نظنّ النظام عرضه، فلا نعرضه مرتين.
            // ★ لا نحذفه هنا: قد يكون «تم الإرسال» نجح والعرض فشل
            //   (خدمات جوجل مقيّدة في الخلفية) فيضيع الخبر إن حذفناه.
            //   يبقى في جرس التطبيق، ويحذفه استطلاع Dart عند أول فتح.
            val pushed = row.optString("pushed_at", "").trim()
            if (pushed.isNotEmpty() && pushed != "null") continue

            val created = parseTime(row.optString("created_at"))
            if (created != null && now - created > MAX_AGE_MS) continue

            show(context, row)
            added += id
            deleteRow(id, phone)
        }

        if (added.isNotEmpty()) remember(context, seen + added)
    }

    /** عرض الإشعار بقناة نوعه ونغمتها — مطابق لفصل القنوات في النظام. */
    private fun show(context: Context, row: JSONObject) {
        val mgr = context.getSystemService(NotificationManager::class.java) ?: return
        val id = row.optString("id")
        val type = row.optString("type").trim()
        val sound = row.optString("sound").trim().ifEmpty { type }
        val rawTitle = row.optString("title").trim().ifEmpty { "إشعار" }
        val body = row.optString("body")
        val serial = row.optString("serial").trim()

        val title = withSerial(rawTitle, serial, body)

        val open = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra("orderId", row.optString("order_id"))
            putExtra("serial", serial)
            putExtra("status", type)
            putExtra("link", row.optString("link_url"))
            putExtra("title", rawTitle)
            putExtra("body", body)
            // العلامة التي يجعل `captureNotificationIntent` يلتقط النقرة.
            putExtra("google.message_id", "native-$id")
        }
        val pi = PendingIntent.getActivity(
            context,
            id.hashCode(),
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // ★ نغمة المستخدم من أصوات هاتفه تتقدّم على قناة الحدث.
        val channel = NotificationSounds.channelId(context) ?: channelFor(sound)
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pi)
        // قبل أندرويد 8 لا قنوات ⇒ النغمة تُضبط على الإشعار نفسه.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            val customUri = NotificationSounds.uri(context)
            if (customUri == NotificationSounds.SILENT_URI) {
                builder.setSound(null)
            } else if (customUri != null && customUri.isNotEmpty()) {
                builder.setSound(android.net.Uri.parse(customUri))
            }
        }
        val n = builder.build()

        try {
            mgr.notify(id.hashCode() and 0x3fffffff, n)
            Log.i(TAG, "natively shown: $type $id")
        } catch (e: Exception) {
            Log.w(TAG, "notify failed: ${e.message}")
        }
    }

    /** نوع الحدث ⇒ قناة — نفس خريطة `fcm.js` و`SystemNotification.channelFor`. */
    private fun channelFor(kind: String): String = when (kind) {
        "pending", "new_order", "driver_request" -> NotifyChannels.NEW_ORDER
        "accepted" -> NotifyChannels.ACCEPTED
        "delivering" -> NotifyChannels.DELIVERING
        "rejected", "cancelled" -> NotifyChannels.REJECTED
        "item_changed", "item_replaced", "item_deleted", "replaced" ->
            NotifyChannels.REPLACED
        "price_changed" -> NotifyChannels.PRICE_CHANGED
        "delivered" -> NotifyChannels.DELIVERED
        else -> NotifyChannels.ALERT
    }

    /** رقم الطلب في العنوان إن لم يظهر في النص — قاعدة العرض نفسها. */
    private fun withSerial(title: String, serial: String, body: String): String {
        if (serial.isEmpty() || serial == "null") return title
        val tag = if (serial.startsWith("#")) serial else "#$serial"
        if (title.contains(tag) || body.contains(tag)) return title
        return "$title  $tag"
    }

    private fun deleteRow(id: String, phone: String) {
        try {
            rpc(
                "delete_my_notification",
                JSONObject().put("p_id", id).put("p_phone", phone).toString(),
            )
        } catch (_: Exception) {
            // محفوظ في set المشاهدة، فلا يتكرر العرض.
        }
    }

    /** نداء دالة محميّة في Supabase بالـanon (نفس ما يستعمله التطبيق). */
    private fun rpc(fn: String, body: String): String? {
        var conn: HttpURLConnection? = null
        return try {
            conn = URL(BASE + "rpc/" + fn).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.doOutput = true
            conn.setRequestProperty("apikey", ANON)
            conn.setRequestProperty("Authorization", "Bearer $ANON")
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use {
                it.write(body.toByteArray(StandardCharsets.UTF_8))
            }
            val code = conn.responseCode
            if (code !in 200..299) {
                Log.w(TAG, "rpc $fn -> $code")
                return null
            }
            BufferedReader(InputStreamReader(conn.inputStream, StandardCharsets.UTF_8))
                .use { it.readText() }
        } catch (e: Exception) {
            Log.w(TAG, "rpc $fn failed: ${e.message}")
            null
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
        }
    }

    private fun own(context: Context) =
        context.getSharedPreferences(OWN_PREFS, Context.MODE_PRIVATE)

    private fun remember(context: Context, ids: Set<String>) {
        val trimmed = if (ids.size > MAX_SEEN) {
            ids.toList().takeLast(MAX_SEEN).toSet()
        } else {
            ids
        }
        own(context).edit().putStringSet(K_SEEN, trimmed).apply()
    }

    private fun parseTime(iso: String): Long? {
        if (iso.length < 19) return null
        return try {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            fmt.parse(iso.substring(0, 19))?.time
        } catch (_: Exception) {
            null
        }
    }
}
