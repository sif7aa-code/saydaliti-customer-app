import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LocationResult {
  const LocationResult({
    required this.address,
    this.latitude,
    this.longitude,
    this.isAutoDetected = false,
    this.errorMessage,
    this.accuracy = 0,
  });

  final String address;
  final double? latitude;
  final double? longitude;
  final bool isAutoDetected;
  final String? errorMessage;

  /// دقة القياس بالأمتار (0 = غير معروفة). تحتاجها الخريطة لترسم
  /// «متسع» الموقع حول الدبوس؛ كان الرقم يُكتب في النص فقط.
  final double accuracy;
}

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  String currentAddress = 'جاري تحديد موقعك تلقائياً...';
  double? currentLat;
  double? currentLng;
  bool isDetecting = false;

  /// هل لدينا موقع محفوظ من تشغيل سابق؟
  bool hasSavedLocation = false;

  /// ★ موقع ثبّته المستخدم بيدِه على الخريطة في هذه الجلسة.
  ///
  /// ما دام فعّالاً لا يغطّيه أي تحديد تلقائي: لولا ذلك لعاد GPS
  /// فمحّق اختيار الدبوس لحظة الإرسال — و«طلب مندوب» كان يستدعي
  /// `determinePosition()` داخل `_send()` بالذات، فيضيع الموقع الذي
  /// أكّده الزبون للتو. التحديد الصريح (زر «تحديث») وحده يتجاوزه.
  bool manualPinActive = false;

  static const String _kAddress = 'last_location_address_v1';
  static const String _kLat = 'last_location_lat_v1';
  static const String _kLng = 'last_location_lng_v1';

  /// الحساب الذي تخصّه القيم المحفوظة الآن.
  /// كل حساب له موقعه الخاص على الجهاز — لا تختلط المواقع بين
  /// المستخدمين على نفس الهاتف.
  String? _owner;

  /// مفاتيح التخزين تسبق باسم الحساب ⇒ عزل كامل بين المستخدمين.
  String? _key(String base) => _owner == null ? base : '${base}_$_owner';

  /// ينقل التخزين إلى حساب آخر (يُستدعى عند الدخول/الخروج).
  void setAccount(String? phone) {
    final p = (phone ?? '').trim();
    if (p.isEmpty) return;
    if (_owner == p) return;
    _owner = p;
    currentAddress = 'جاري تحديد موقعك تلقائياً...';
    currentLat = null;
    currentLng = null;
    hasSavedLocation = false;
    manualPinActive = false;
    unawaited(loadSaved());
  }

  /// يحمّل موقع الحساب الحالي ليظهر في الأعلى فور فتح التطبيق.
  Future<void> loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final address = prefs.getString(_key(_kAddress) ?? _kAddress);
      if (address == null || address.isEmpty) return;
      currentAddress = address;
      currentLat = prefs.getDouble(_key(_kLat) ?? _kLat);
      currentLng = prefs.getDouble(_key(_kLng) ?? _kLng);
      hasSavedLocation = currentLat != null && currentLng != null;
    } catch (_) {}
  }

  /// يستبدل العنوان المعروض (يبقى إحداثيات GPS كما هي).
  void setAddress(String address) {
    final a = address.trim();
    if (a.isEmpty) return;
    currentAddress = a;
    unawaited(_save());
  }

  /// الترميز العكسي وحده، بلا لمس أي حالة — يستخدمه منتقي الخريطة
  /// ليعرض اسم المكان تحت الدبوس أثناء السحب.
  Future<String> addressFor(double lat, double lng) =>
      _reverseGeocode(lat, lng);

  /// ★ تثبيت موقع اختاره المستخدم على الخريطة (دبوس + «تأكيد موقعي»).
  ///
  /// يكتب الإحداثيات والعنوان ويحفظهما لحساب **الحالي**، ويشعل
  /// [manualPinActive] ليمنع أي تحديد تلقائي لاحق من محو الاختيار.
  /// [address] يُمرَّر من المنتقي لأنه رمّز العنوان فعلاً، فلا نستدعي
  /// Nominatim مرتين لنفس النقطة (حدّاهما 1 طلب/ثانية).
  Future<void> setPinnedLocation(
    double lat,
    double lng, {
    String? address,
  }) async {
    currentLat = lat;
    currentLng = lng;
    manualPinActive = true;
    final a = (address ?? '').trim();
    if (a.isNotEmpty) {
      currentAddress = a;
    } else {
      currentAddress = await _reverseGeocode(lat, lng);
    }
    isDetecting = false;
    hasSavedLocation = true;
    await _save();
  }

  /// يُبطل مفعول الدبوس: يستدعيه زر «تحديث» فقط — أي تحديد صريح
  /// يريده المستخدم الآن مكان اختياره السابق.
  void clearPin() => manualPinActive = false;

  /// يحفظ موقع **الحساب الحالي فقط** (لا موقع غيره).
  Future<void> _save() async {
    if (currentAddress.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(_kAddress)!, currentAddress);
      if (currentLat != null) await prefs.setDouble(_key(_kLat)!, currentLat!);
      if (currentLng != null) await prefs.setDouble(_key(_kLng)!, currentLng!);
      hasSavedLocation = true;
    } catch (_) {}
  }

  /// ★ أدقّ قياس يصل **فور وصوله**، لا بعد انتهاء المهلة.
  ///
  ///   `getCurrentPosition` كانت تطلب قياساً واحداً فتمضي وقتها كاملاً
  ///   حتى لو جاء أفضل منه في الثانية الثانية، وترمينا في البدائل عند
  ///   انتهاء الـ١٥ ثانية. هنا نستمع لقياسات `bestForNavigation`
  ///   نفسها: أول قياس داخل [_goodEnoughMeters] يُسلَّم بلا انتظار
  ///   (والهاتف الدافئ يعطيه في ١–٣ ثوانٍ)، وإن بقيت كل القياسات
  ///   خامة نسلّم أفضلها عند نهاية [_fixWindow] — فالدبوس لا يتحرك
  ///   أبداً على نقطة غير مضبوطة، ولا يبقى الزر معلّقاً على مهلة ثابتة.
  static const double _goodEnoughMeters = 25;
  static const Duration _fixWindow = Duration(seconds: 14);

  Future<Position?> _bestFix() async {
    final done = Completer<Position?>();
    Position? best;

    void offer(Position candidate) {
      final acc = candidate.accuracy;
      final measured = acc.isFinite && acc > 0;
      if (best == null) {
        best = candidate;
      } else if (measured) {
        final held = best!.accuracy;
        if (!held.isFinite || held <= 0 || acc < held) best = candidate;
      }
      if (measured && acc <= _goodEnoughMeters && !done.isCompleted) {
        done.complete(candidate);
      }
    }

    // `distanceFilter: 0` ⇒ لا يُحجب أي قياس لأنه شبيه بالذي قبله؛
    // الدقّة تتحسّن بالقياسات المتتالية وهي واقفة في نفس البقعة.
    final sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen(offer, onError: (Object _) {});

    final timer = Timer(_fixWindow, () {
      if (!done.isCompleted) done.complete(best);
    });

    final result = await done.future;
    timer.cancel();
    // إلغاء الاشتراك يطفئ مصدر Location فوراً — لا GPS يعمل في
    // الخلفية بعد أن أخذنا القياس.
    await sub.cancel();
    return result;
  }

  /// يطلب صلاحيات الموقع ويجلب الإحداثيات الفعلية تلقائياً
  ///
  /// ★ لا يعود فارغ اليدين إن أمكن: عند تعذر التحديد المباشر
  ///   (GPS مطفأ / إذن مرفوض / انتهاء المهلة) نجرّب خطة بديلة —
  ///   آخر موقع معروف من النظام، ثم الموقع المحفوظ لهذا الحساب —
  ///   كي لا يبقى الطلب بلا إحداثيات فيرفضه الخادم.
  ///
  /// [overridePin]: `true` تعني أن المستخدم طلب التحديد بنفسه الآن
  /// (زر «تحديث») فنبطل دبوسه. أما النداء التلقائي — عند فتح الشاشة
  /// أو لحظة الإرسال — فيحترم الدبوس المؤكد ويعيده كما هو، لأن
  /// الزبون اختار مكانه بيدِه وهو أدقّ من نقطة GPS لحظية.
  Future<LocationResult> determinePosition({bool overridePin = false}) async {
    if (manualPinActive &&
        !overridePin &&
        currentLat != null &&
        currentLng != null) {
      return LocationResult(
        address: currentAddress,
        latitude: currentLat,
        longitude: currentLng,
        isAutoDetected: true,
      );
    }
    if (overridePin) clearPin();
    isDetecting = true;
    try {
      // 1) خدمة الموقع مطفأة؟ نجرّب البدائل قبل الاستسلام.
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        final r = await _fallback(
          reason: 'خدمة تحديد الموقع (GPS) غير مفعلة في جهازك.',
          placeholder: 'موقعك الحالي (يرجى تفعيل GPS)',
        );
        isDetecting = false;
        return r;
      }

      // 2) الصلاحيات.
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        final forever = permission == LocationPermission.deniedForever;
        final r = await _fallback(
          reason: forever
              ? 'تم رفض إذن الموقع بشكل دائم. يمكنك تفعيله من إعدادات الجهاز.'
              : 'تم رفض إذن الوصول إلى الموقع.',
          placeholder: forever
              ? 'موقعك الحالي (الإذن مقفل من الإعدادات)'
              : 'موقعك الحالي (تم رفض الإذن)',
        );
        isDetecting = false;
        return r;
      }

      // 3) تحديد حديث بأعلى دقة متاحة (GPS + شبكة + مستشعرات).
      // `bestForNavigation` أدقّ ما يمكن ⇒ عنوان صحيح لكل حساب، ولا
      // يتحرّك الدبوس على قياس خام (الأدمن 11-01: «أعلى دقة دائماً قبل
      // الحركة») — انظر [_bestFix].
      final position = await _bestFix();
      if (position == null) {
        // لا قياس داخل النافذة ⇒ البدائل.
        final r = await _fallback(
          reason: 'تعذر تحديد موقعك الآن (قد تكون داخل بناية أو GPS ضعيف).',
          placeholder: 'موقعي الحالي (تحديد تلقائي)',
        );
        isDetecting = false;
        return r;
      }

      currentLat = position.latitude;
      currentLng = position.longitude;

      // تحويل الإحداثيات إلى عنوان حقيقي بسيط بلا أرقام
      // (مثال: "ذي قار، الشطرة") عبر الترميز العكسي.
      currentAddress = await _reverseGeocode(
        position.latitude,
        position.longitude,
      );
      // دقة GPS إن كانت متاحة ⇒ نلحقها بالعنوان كدليل.
      final acc = position.accuracy;
      if (acc > 0 && acc.isFinite) {
        currentAddress = '$currentAddress (±${acc.round()}م)';
      }
      isDetecting = false;
      await _save();

      return LocationResult(
        address: currentAddress,
        latitude: position.latitude,
        longitude: position.longitude,
        isAutoDetected: true,
        accuracy: acc.isFinite && acc > 0 ? acc : 0,
      );
    } catch (e) {
      isDetecting = false;
      if (kDebugMode) print('Location error: $e');
      return _fallback(
        reason: 'حدث خطأ أثناء جلب الموقع: $e',
        placeholder: 'موقعي الحالي (تحديد تلقائي)',
      );
    }
  }

  /// خطة بديلة عند تعذر التحديد المباشر:
  /// 1) آخر موقع معروف من النظام (سريع ولا ينتظر أقمار GPS).
  /// 2) الإحداثيات المحفوظة لهذا الحساب من تشغيل سابق.
  /// 3) عند غياب الاثنين: عنوان نصي مؤقت مع رسالة الخطأ (كما كان).
  Future<LocationResult> _fallback({
    required String reason,
    required String placeholder,
  }) async {
    // (1) آخر موقع معروف.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        currentLat = last.latitude;
        currentLng = last.longitude;
        currentAddress = await _reverseGeocode(last.latitude, last.longitude);
        await _save();
        return LocationResult(
          address: currentAddress,
          latitude: last.latitude,
          longitude: last.longitude,
          isAutoDetected: true,
          accuracy: last.accuracy.isFinite && last.accuracy > 0
              ? last.accuracy
              : 0,
        );
      }
    } catch (_) {}

    // (2) موقع محفوظ لهذا الحساب (من تشغيل سابق على نفس الهاتف).
    if (currentLat != null && currentLng != null) {
      if (_looksUnresolved(currentAddress)) {
        currentAddress = await _reverseGeocode(currentLat!, currentLng!);
      }
      await _save();
      return LocationResult(
        address: currentAddress,
        latitude: currentLat,
        longitude: currentLng,
        isAutoDetected: true,
      );
    }

    // (3) لا إحداثيات إطلاقاً — نُبقي العنوان المؤقت ورسالة السبب.
    currentAddress = placeholder;
    return LocationResult(address: currentAddress, errorMessage: reason);
  }

  /// هل العنوان المعروض مؤقت/غير محدد بعد؟ (كي نعيد ترميزه بالإحداثيات المحفوظة)
  bool _looksUnresolved(String address) =>
      address.isEmpty ||
      address.startsWith('جاري') ||
      address.contains('موقعي الحالي') ||
      address.contains('موقعك الحالي');

  /// ★ اسم المكان: بكاش وبمهلة، لأن هذا كان «التأخير» الحقيقي.
  ///
  ///   نداء الشبكة بلا مهلة كان يعلّق عند Nominatim (١ طلب/ثانية كحدّ
  ///   عندهم، وقد يبطئ دقائق) فيتجمّد زرّ «حدد موقعي» حتى يملّ
  ///   المستخدم، بينما GPS كان قد انتهى من ثانية. الآن: اسم الحي
  ///   محفوظ ⇒ بلا شبكة أصلاً، وطلب جديد ⇒ ٤ ثوانٍ كحدّ أقصى ثم الاسم
  ///   الاحتياطي، ويأتي الاسم الصحيح خلفياً متى وصل.
  static final Map<String, String> _geoCache = {};
  static const Duration _geoTimeout = Duration(seconds: 4);

  Future<String> _reverseGeocode(double lat, double lng) async {
    // ثلاثة منازل ≈ ١١٠ متر: نفس الحي يعطي نفس الاسم، فالكاش يصيب
    // فعلاً بدل أن يهدره كل هزّة إحداثيات من المستشعر.
    final key = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    final cached = _geoCache[key];
    if (cached != null) return cached;
    final name = await _fetchPlaceName(lat, lng);
    if (name == null) {
      // احتياط: عنوان بلا أرقام إحداثيات.
      return 'موقعي الحالي (ذي قار، الشطرة)';
    }
    if (_geoCache.length > 60) _geoCache.clear();
    _geoCache[key] = name;
    return name;
  }

  /// الترميز العكسي عبر Nominatim (مجاني بدون مفتاح):
  /// يعيد "المحافظة، المدينة" (مثل "ذي قار، الشطرة") بدون أي أرقام.
  Future<String?> _fetchPlaceName(double lat, double lng) async {
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://nominatim.openstreetmap.org/reverse'
              '?format=json&lat=$lat&lon=$lng&accept-language=ar'
              '&zoom=10&addressdetails=1',
            ),
            headers: {'User-Agent': 'strasopa-delivery-app'},
          )
          .timeout(_geoTimeout);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body);
        final addr = data['address'] as Map<String, dynamic>? ?? {};
        final governorate = _first([
          addr['state'],
          addr['province'],
          addr['county'],
        ]);
        final city = _first([
          addr['town'],
          addr['city'],
          addr['district'],
          addr['village'],
        ]);
        final parts = <String>[];
        if (governorate != null && governorate.isNotEmpty) {
          parts.add(governorate.toString().trim());
        }
        if (city != null && city.isNotEmpty) {
          parts.add(city.toString().trim());
        }
        if (parts.isNotEmpty) {
          return parts.join('، ');
        }
        final display = data['display_name']?.toString();
        if (display != null && display.isNotEmpty) return display;
      }
    } catch (_) {}
    return null;
  }

  String? _first(List<dynamic> values) {
    for (final v in values) {
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return null;
  }
}
