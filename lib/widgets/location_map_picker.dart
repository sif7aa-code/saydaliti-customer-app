import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';

import '../core/theme/app_colors.dart';
import '../services/location_service.dart';

/// ★ منتقي الموقع بالخريطة — يُفتح من شاشة الطلب ومن «طلب مندوب».
///
/// لماذا مكوّن واحد مشترك: السلوك المطلوب متطابق في المكانين (دبوس
/// ثابت + تحديد تلقائي مضبوط + «تأكيد موقعي»)؛ نسخة واحدة تعني إصلاحاً
/// واحداً وسلوكاً واحداً لا يتفارقان مع أول تعديل.
///
/// لماذا `flutter_map` مع بلاطات خرائط جوجل: الخريطة التي يثق بها
/// الأدمن هي ما يراه في تطبيق الخرائط — فالبلاطات من خوادم خرائط جوجل
/// العامة (`lyrs=y` أقمار بأسماء الشوارع، `lyrs=m` شوارع). لا مفتاح API،
/// ولا فاتورة، ولا `lib` أصلي ⇒ حجم الـ APK الخفيف الذي التزمناه كما
/// هو، والدبوس واللوحة وأزرارها لم يُمسّ أحد منها (الأدمن 11-01:
/// «غيّر الخريطة لخرائط ماب» + «بدون تغيير أي مكان»).
///
/// لماذا الدبوس في وسط **منطقة الخريطة** لا وسط الشاشة: اللوحة السفلية
/// تأكل جزءاً من الشاشة، فلو وسطينا الدبوس على كامل الشاشة لكانت
/// الإحداثيات التي يثبّتها المستخدم أسفلَ ما يراه فعلياً. الخريطة
/// نفسها محصورة فوق اللوحة، فالوسطان يتطابقان بلا أي حساب إزاحة.
class LocationMapPicker extends StatefulWidget {
  const LocationMapPicker({super.key, this.title = 'تأكيد موقعي'});

  final String title;

  @override
  State<LocationMapPicker> createState() => _LocationMapPickerState();

  /// يفتح المنتقي ويعيد `true` إن أكّد المستخدم الموقع.
  static Future<bool> open(
    BuildContext context, {
    String title = 'تأكيد موقعي',
  }) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => LocationMapPicker(title: title)),
    );
    return ok == true;
  }
}

class _LocationMapPickerState extends State<LocationMapPicker>
    with SingleTickerProviderStateMixin {
  /// ارتفاع اللوحة السفلية الثابت — تعرفه الخريطة مسبقاً لتحصر نفسها
  /// فوقه (انظر شرح الدبوس أعلاه).
  static const double _panelHeight = 214;

  static const double _startZoom = 16.5;

  final MapController _map = MapController();

  /// موضع الدبوس = مركز خريطة الكاميرا الحالية.
  LatLng _pin = const LatLng(31.72, 46.14);

  /// موقع GPS الحالي (نقطة + دقة) لنعرضه دائرةً تحت الدبوس.
  LatLng? _gpsPoint;
  double _gpsAccuracy = 0;

  String _address = 'جاري تحديد الموقع...';
  bool _geocoding = false;
  bool _locating = false;
  bool _satellite = true;
  String? _notice;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final loc = LocationService.instance;
    // نبدأ حيث نحن فعلاً: إن كانت إحداثيات محفوظة نضع الدبوس عليها
    // فوراً، وإلا بقي على مركز المحافظة ونحدّده لحظة فتح الخريطة.
    if (loc.currentLat != null && loc.currentLng != null) {
      _pin = LatLng(loc.currentLat!, loc.currentLng!);
      _gpsPoint = _pin;
      _address = loc.currentAddress;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _map.move(_pin, _startZoom);
      // التحديد التلقائي عند الفتح — «التحديد التلقائي للموقع الحالي
      // مضبوط»: لا نكتفي بالمحفوظ بل نطلب GPS حديثاً.
      if (loc.currentLat == null || loc.currentLng == null) _locateMe();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// ★ «حدد موقعي الحالي»: GPS بأعلى دقة، ثم نطير بالخريطة إليه.
  Future<void> _locateMe() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _notice = null;
    });
    // overridePin: داخل المنتقي المستخدم يطلب موقعه الآن بوضوح،
    // فدبوس الجلسة السابقة لا يمنعه (المنع يخصّ النداءات التلقائية).
    final res = await LocationService.instance.determinePosition(
      overridePin: true,
    );
    if (!mounted) return;
    final lat = res.latitude;
    final lng = res.longitude;
    if (lat == null || lng == null) {
      setState(() {
        _locating = false;
        _notice =
            res.errorMessage ??
            'تعذر تحديد موقعك — اسحب الخريطة وثبّت الدبوس يدوياً.';
      });
      return;
    }
    final point = LatLng(lat, lng);
    setState(() {
      _locating = false;
      _pin = point;
      _gpsPoint = point;
      _gpsAccuracy = res.accuracy;
      _address = res.address;
    });
    _map.move(point, _startZoom);
    // العنوان تحت الدبوس يُعاد رمزه من النقطة نفسها، لا من محفوظات
    // سابقة — حتى يتطابق ما يراه مع مكان الدبوس.
    unawaited(_regeocode(point));
  }

  void _onCameraMoved(MapCamera camera, bool hasGesture) {
    // حركة الكاميرا من أزرارنا (_map.move) لا تعني أن المستخدم حرّك
    // الدبوس، فنتجاهلها وإلا أعيد رمز عنوان لم نطلبه.
    if (!hasGesture) return;
    // نحفظ نقطة مجرّدة، لا [MapCamera]: هذه تحمل قياس الشاشة ونظام
    // الإحداثيات، وتمريرها للتخزين يجعل النقطة أثقل مما يلزم.
    final center = LatLng(camera.center.latitude, camera.center.longitude);
    _pin = center;
    _scheduleRegeocode(center);
  }

  /// النقر (أو الضغط المطوّل) على الخريطة ⇒ الدبوس يقفز إلى النقطة.
  void _onTap(TapPosition tap, LatLng point) {
    setState(() => _pin = point);
    _scheduleRegeocode(point);
  }

  /// السحب المستمر يُطلق النداء لكل بكسل — نؤجّل الترميز حتى يسكن،
  /// وإلا أمطرنا Nominatim بطلبات نتجاوز حدّها (1/ثانية) فنُحجب.
  void _scheduleRegeocode(LatLng point) {
    _debounce?.cancel();
    setState(() => _address = 'جاري قراءة اسم المكان...');
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) unawaited(_regeocode(point));
    });
  }

  Future<void> _regeocode(LatLng point) async {
    if (!mounted) return;
    setState(() => _geocoding = true);
    final addr = await LocationService.instance.addressFor(
      point.latitude,
      point.longitude,
    );
    if (!mounted) return;
    setState(() {
      _geocoding = false;
      // لا نستبدل العنوان إلا إن كان المستخدم لم يحرّك الدبوس في
      // أثناء الانتظار (وإلا عرضنا اسم مكان قديم).
      if (_pin.latitude == point.latitude &&
          _pin.longitude == point.longitude) {
        _address = addr;
      }
    });
  }

  Future<void> _confirm() async {
    // ★ من أكّد أثناء قراءة الاسم (أو قبل أن يبدأ) فالنص المؤقت ليس
    //   عنواناً: نمرّر `null` فيُرمَّز على هدوء داخل الخدمة، ولا يُحفظ
    //   «جاري قراءة اسم المكان...» عنواناً توصيلٍ للمندوب.
    final label = _address.trim();
    final usable = label.isNotEmpty && !label.startsWith('جاري');
    await LocationService.instance.setPinnedLocation(
      _pin.latitude,
      _pin.longitude,
      address: usable ? label : null,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          widget.title,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: _pin,
                      initialZoom: _startZoom,
                      minZoom: 5,
                      maxZoom: 19,
                      backgroundColor: AppColors.surfaceTint,
                      interactionOptions: const InteractionOptions(
                        // بلا دوران ولا إمالة: الخريطة تبقى للأعلى
                        // فتبقى «سحب الدبوس = تحرّك المكان» بديهية،
                        // وتختفي حركات تجعل التثبيت غير مضبوط.
                        flags:
                            InteractiveFlag.pinchZoom |
                            InteractiveFlag.drag |
                            InteractiveFlag.doubleTapZoom,
                      ),
                      onPositionChanged: _onCameraMoved,
                      onTap: _onTap,
                      onLongPress: _onTap,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: _satellite
                            ? 'https://mt{s}.google.com/vt/lyrs=y'
                              '&x={x}&y={y}&z={z}'
                            : 'https://mt{s}.google.com/vt/lyrs=m'
                              '&x={x}&y={y}&z={z}',
                        subdomains: const ['0', '1', '2', '3'],
                        userAgentPackageName: 'com.saydaliti.app',
                        maxZoom: 19,
                        maxNativeZoom: 19,
                        tileDisplay: const TileDisplay.fadeIn(
                          duration: Duration(milliseconds: 120),
                        ),
                      ),
                      // دائرة دقة GPS خلف الدبوس: ترى «متسع» موقعك.
                      if (_gpsPoint != null && _gpsAccuracy > 4)
                        CircleLayer(
                          circles: [
                            CircleMarker(
                              point: _gpsPoint!,
                              useRadiusInMeter: true,
                              radius: (_gpsAccuracy.clamp(8, 120)).toDouble(),
                              color: AppColors.primary.withValues(alpha: 0.16),
                              borderStrokeWidth: 1.5,
                              borderColor: AppColors.primary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                // الدبوس: في وسط منطقة الخريطة تماماً (الـ Stack نفسه
                // فوق اللوحة السفلية، فلا إزاحة تُحسب يدوياً).
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            Icon(
                              Icons.location_pin,
                              size: 46,
                              color: AppColors.primary,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.28),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            Container(
                              width: 8,
                              height: 3,
                              margin: const EdgeInsets.only(top: 1),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.22),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // أزرار عائمة: تحديد الموقع + تبديل الأقمار/الشوارع
                Positioned(
                  left: 12,
                  top: 12,
                  child: _floatButton(
                    icon: _satellite ? Icons.map_outlined : Icons.satellite_alt,
                    onTap: () => setState(() => _satellite = !_satellite),
                    tooltip: _satellite ? 'خريطة شوارع' : 'صور أقمار',
                  ),
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _floatButton(
                    icon: _locating
                        ? Icons.my_location_rounded
                        : Icons.gps_fixed_rounded,
                    busy: _locating,
                    onTap: _locateMe,
                    tooltip: 'حدد موقعي الحالي',
                  ),
                ),
                if (_notice != null)
                  Positioned(
                    right: 12,
                    left: 12,
                    top: 12,
                    child: _banner(_notice!, danger: true),
                  ),
              ],
            ),
          ),
          // اللوحة السفلية: الثابتة الارتفاع التي تحصرها الخريطة فوقها.
          Container(
            height: _panelHeight + bottom,
            padding: EdgeInsets.fromLTRB(16, 14, 16, 12 + bottom),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _geocoding || _locating
                          ? Icons.location_searching_rounded
                          : Icons.place_rounded,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'موقعك المثبّت',
                        style: GoogleFonts.cairo(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textHint,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 38,
                  child: Text(
                    _address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                      height: 1.35,
                    ),
                  ),
                ),
                Text(
                  'اسحب الخريطة أو اضغط مطوّلاً لتحريك الدبوس حتى باب المكان',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _locating ? null : _locateMe,
                        icon: Icon(
                          _locating
                              ? Icons.hourglass_empty_rounded
                              : Icons.my_location_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _locating ? 'جاري التحديد...' : 'حدد موقعي الحالي',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: BorderSide(
                            color: AppColors.primary.withValues(alpha: 0.45),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _confirm,
                        icon: const Icon(Icons.check_rounded, size: 20),
                        label: Text(
                          'تأكيد موقعي',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w900,
                            fontSize: 13.5,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'الخرائط: خرائط جوجل',
                  style: GoogleFonts.cairo(
                    fontSize: 9.5,
                    color: AppColors.textHint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _floatButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    bool busy = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : Icon(icon, color: AppColors.primary, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _banner(String text, {bool danger = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (danger ? AppColors.danger : AppColors.primary).withValues(
            alpha: 0.4,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            danger ? Icons.info_outline_rounded : Icons.check_circle_rounded,
            size: 18,
            color: danger ? AppColors.danger : AppColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
