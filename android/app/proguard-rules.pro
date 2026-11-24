# قواعد R8 لتصغير الـ APK مع الحفاظ على كل المميزات.
#
# ملاحظة مهمة: لا نُبقي حزم Firebase كاملة (ChosenClassMembers) لأنها
# منفّذة أصلاً وتضخّم الـ APK كثيراً — نترك R8 يتصرّف معها.
# حِزَم firebase/okhttp تشمل قواعد Proguard جاهزة (consumer rules).

# ── Flutter / Dart ─────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ── GSON (يستخدمه flutterfire) ─────────────────────────────────────────
-keepattributes Signature, InnerClasses, EnclosingMethod, *Annotation*
-keep class com.google.gson.** { *; }
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# ── Intent extras في معالجة الرسالة الخلفية ─────────────────────────────
-keep class com.shatra.center.MainActivity { *; }
-keep class * extends android.app.Service
-keep class * extends android.content.BroadcastReceiver

# ── إشعارات النظام: الحقول التي يقرأها Android بالانعكاس ────────────────
-keepclassmembers class * extends android.app.Notification {
    public *;
}
