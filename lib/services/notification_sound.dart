import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_sound.dart';

/// مفاتيح أصوات الإشعارات.
///
/// ★ منذ 2026-11-24 كل الحالات (`new_order`، `accepted`، …) تشغّل
///   **جرساً واحداً** — ملفات `assets/sounds/*.wav` كلها الجرس نفسه.
///   المفاتيح باقية لأنها أسماء القنوات و`notifications.sound` في
///   القاعدة، فلا تتغيّر بيانات قديمة.
enum NotifySound {
  /// طلب جديد وصل المندوبين.
  newOrder('new_order'),

  /// قبول الطلب.
  accepted('accepted'),

  /// بدء التوصيل.
  delivering('delivering'),

  /// رفض الطلب أو إلغاؤه.
  rejected('rejected'),

  /// استبدال / تعديل / حذف منتج داخل الطلب.
  replaced('replaced'),

  /// تغيّر سعر صنف داخل الطلب (يحدّده المندوب أو الأدمن).
  priceChanged('price_changed'),

  /// توصيل الطلب.
  delivered('delivered'),

  /// تنبيه عام (شعار، رسالة إدارية، …).
  alert('alert');

  const NotifySound(this.key);

  /// الاسم المخزَّن في عمود notifications.sound.
  final String key;

  /// المسار داخل حزمة الأصول.
  String get asset => 'sounds/$key.wav';
}

/// تشغيل جرس الإشعار (صوت واحد لكل الحالات).
///
/// الملفات الثمانية في `assets/sounds/` تحمل الجرس نفسه، مولّدة
/// بسكربت `tools/make_notification_sounds.dart` (لا ملفات صوت خارجية).
/// نُبقي مشغّلاً لكل حالة لأن نافذة منع التكرار لكل حالة على حدة.
/// المشغّلات تُحمَّل مسبقاً ([preload]) ليعمل الصوت فوراً عند الإشعار.
class NotificationSound {
  NotificationSound._();
  static final NotificationSound instance = NotificationSound._();

  static const String _kEnabled = 'notify_sound_enabled_v1';
  static const double _volume = 0.9;

  /// أقل مدة بين تشغيل نفس النغمة مرتين (بالملّي ثانية) — يمنع التكرار
  /// حين يصل الإشعار من مرّتين: إشعار FCM + استطلاع جدول الإشعارات.
  static const int _dedupeWindowMs = 2500;

  /// ★ أقل فاصل بين **أي** نغمتين (بالملّي ثانية).
  ///
  ///   المشكلة: الإشعار الواحد يصل من أربعة مصادر (بث SSE + صف قاعدة
  ///   بيانات + FCM + استطلاع)، وكل مصدر يرسل نغمة، فكان المستخدم
  ///   يسمع الصوت ٢–٤ مرات. النافذة كانت **لكل نغمة على حدة**، فتنجو
  ///   النغمات المختلفة من الفلترة.
  ///
  ///   الحل: فاصل عام قصير — أي نغمة تقيء خلال هذه المدة تُهمل مهما
  ///   كانت مختلفة. النتيجة: إشعار واحد = صوت واحد.
  static const int _globalGapMs = 1500;

  bool _enabled = true;
  bool _loaded = false;

  final Map<NotifySound, AudioPlayer> _players = {};
  final Map<NotifySound, int> _lastPlayedAtMs = {};

  /// آخر تشغيل لأي نغمة (لا لنغمة بعينها).
  int _lastAnyPlayedAtMs = 0;

  bool get enabled => _enabled;

  /// يقرأ تفضيل كتم الصوت المحفوظ (افتراضياً: الصوت مفعّل).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? true;
    } catch (_) {}
  }

  /// كتم / إلغاء كتم أصوات الإشعارات (يُحفظ على الجهاز).
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, value);
    } catch (_) {}
  }

  /// آخر حالة كتم محفوظة — لعرضها في الإعدادات دون انتظار التهيئة.
  static Future<bool> readEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kEnabled) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// يحوّل نص عمود sound / type / status في الإشعار إلى نغمة.
  ///
  /// آمن تجاه القيم القديمة: أي نوع غير معروف يصبح [NotifySound.alert].
  static NotifySound resolve(String? raw) {
    final key = (raw ?? '').trim().toLowerCase();
    for (final s in NotifySound.values) {
      if (s.key == key) return s;
    }
    switch (key) {
      case 'pending':
      case 'new':
      case 'new_order':
      case 'driver_request':
      case 'request':
      case 'order_created':
        // ★ إشعار السكرتير بحجز جديد يقرع نغمة «طلب جديد» نفسها.
        return NotifySound.newOrder;
      case 'appointment_request':
        return NotifySound.newOrder;
      case 'appointment_approved':
        return NotifySound.accepted;
      // ★ الدور: اقتراب الدور والاستدعاء يقرعان نغمة القبول نفسها،
      //   وانتهاء الزيارة نغمة التسليم — بلا مفاتيح صوت جديدة على
      //   أجهزة الناس.
      case 'queue_near':
      case 'queue_called':
        return NotifySound.accepted;
      case 'appointment_done':
        return NotifySound.delivered;
      case 'appointment_rejected':
        return NotifySound.rejected;
      case 'accepted':
      case 'accept':
        return NotifySound.accepted;
      case 'delivering':
      case 'on_way':
      case 'in_transit':
        return NotifySound.delivering;
      case 'rejected':
      case 'reject':
      case 'cancelled':
      case 'canceled':
        return NotifySound.rejected;
      case 'item_changed':
      case 'replaced':
      case 'replace':
        return NotifySound.replaced;
      // ★ مفاتيح تغيير السعر. `price_changed` اسم النغمة نفسه،
      //   و`price`/`price_change` أسماء قد تأتي من عمود sound.
      case 'price_changed':
      case 'price':
      case 'price_change':
      case 'price_changed_item':
        return NotifySound.priceChanged;
      case 'delivered':
      case 'complete':
        return NotifySound.delivered;
      default:
        return NotifySound.alert;
    }
  }

  /// تجهيز المشغّلات مسبقاً حتى لا يتأخر أول إشعار.
  ///
  /// نضبط `ReleaseMode` والحجم **هنا** لا في `play()`: كان كل إشعار
  /// يدفع ٤ نداءات على قناة المنصّة بالتتابع قبل أن يصدر أي صوت،
  /// أي تأخير محسوس في كل نغمة.
  Future<void> preload() async {
    for (final s in NotifySound.values) {
      try {
        final player = _playerFor(s);
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setVolume(_volume);
      } catch (e) {
        if (kDebugMode) {
          print('Notification sound preload failed (${s.key}): $e');
        }
      }
    }
  }

  AudioPlayer _playerFor(NotifySound sound) {
    final existing = _players[sound];
    if (existing != null) return existing;
    final player = AudioPlayer(playerId: 'notify_${sound.key}');
    _players[sound] = player;
    return player;
  }

  /// يشغّل النغمة فوراً. يتجاهل الطلب إن كان الصوت مكتوماً، أو تكرّرت
  /// نفس النغمة خلال [_dedupeWindowMs]، أو سبق تشغيل أي نغمة خلال
  /// [_globalGapMs].
  ///
  /// ★ لا طابور انتظار: كان يُخزَّن نغمة واحدة behind النغمة الجارية
  ///   فتُشغَّل بعدها بـ`force` (أي بلا فلاتر) فتصطدم نغمتان وتُسمع
  ///   مرتين. الآن النغمة التالية خلال الفاصل العام تُهمل.
  ///
  /// ★★ كان هنا قيد «اتّبع نغمة الهاتف» يُرجع قبل التشغيل دائماً
  ///   (افتراضيه `true`)، والحالة الوحيدة التي تُنادي هذه الدالة هي
  ///   **الشريط الداخلي** — ولا إشعار نظام فيه يُصدر نغمة القناة،
  ///   فالنتيجة كانت صمتاً تاماً داخل التطبيق. أندرويد لا يعرض
  ///   إشعارات النظام أصلًا والتطبيق في المقدّمة، فلا خوف من
  ///   نغمتين: النغمة من هنا أو لا شيء — والمطلوب أن تُسمع.
  Future<void> play(NotifySound sound, {bool force = false}) async {
    if (!force) {
      await load();
      if (!_enabled) return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastPlayedAtMs[sound] ?? 0;
    if (!force && now - last < _dedupeWindowMs) return;
    // ★ الفاصل العام: يمنع تتابع النغمات المختلفة (إشعار واحد = نغمة واحدة).
    if (!force && now - _lastAnyPlayedAtMs < _globalGapMs) return;
    _lastPlayedAtMs[sound] = now;
    _lastAnyPlayedAtMs = now;

    // ★ اختار المستخدم نغمة من أصوات هاتفه ⇒ تُسمع هي داخل التطبيق
    //   أيضاً؛ جرس التطبيق القديم لا يُشغَّل بجانبها ولا بدلها.
    if (DeviceSound.hasCustom) {
      if (!DeviceSound.isSilent) {
        final uri = DeviceSound.selectedUri;
        if (uri != null && uri.isNotEmpty) {
          await DeviceSound.preview(uri);
        }
      }
      return;
    }

    try {
      final player = _playerFor(sound);
      // المسار المضمون: نداء واحد فقط — `ReleaseMode` والحجم مضبوطان
      // مسبقاً في [preload].
      await player.play(AssetSource(sound.asset), volume: _volume);
    } catch (e) {
      // إعادة بناء المشغّل مرة واحدة (قد يكون المصدر قد أُفرج عنه).
      try {
        final old = _players.remove(sound);
        if (old != null) {
          try {
            await old.dispose();
          } catch (_) {}
        }
        final player = _playerFor(sound);
        // الإعداد مطبَّق من جديد لأن هذا مشغّل جديد.
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setVolume(_volume);
        await player.play(AssetSource(sound.asset), volume: _volume);
      } catch (e2) {
        // الصوت ميزة تجميلية: أي فشل فيها لا يُسقط التطبيق.
        if (kDebugMode) print('Notification sound failed (${sound.key}): $e2');
      }
    }
  }

  /// يشغّل النغمة الموصوفة بنص موجود في الإشعار (عمود sound أو type).
  Future<void> playRaw(String? raw, {bool force = false}) =>
      play(resolve(raw), force: force);

  /// معاينة نغمة من صفحة الإعدادات (تعمل حتى لو كان الصوت مكتوماً).
  Future<void> preview(NotifySound sound) => play(sound, force: true);

  /// إيقاف النغمة الجارية وتصفير نوافذ منع التكرار.
  ///
  /// ★ النغمات الجائعة تُهمل وقت الطلب، فلا طابور ولا `_pending`.
  ///   (الفاصل العام في [play]) فلا يسمع الزبون نغمة حسابٍ خرج منه
  ///   بعد تبديل الحساب، ولا تتكدّس الأصوات خلف بعضها.
  Future<void> stopAll() async {
    _lastPlayedAtMs.clear();
    _lastAnyPlayedAtMs = 0;
    for (final p in _players.values) {
      try {
        await p.stop();
      } catch (_) {}
    }
  }

  /// تحرير المشغّلات (عند تسجيل الخروج أو إغلاق التطبيق).
  Future<void> dispose() async {
    await stopAll();
    for (final p in _players.values) {
      try {
        await p.dispose();
      } catch (_) {}
    }
    _players.clear();
    _lastPlayedAtMs.clear();
  }
}
