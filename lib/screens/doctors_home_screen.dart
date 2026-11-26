import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../models/banner_item.dart';
import '../models/category_item.dart';
import '../models/doctor_profile.dart';
import '../models/product.dart';
import '../models/shop.dart';
import '../services/auth_service.dart';
import '../services/city_store.dart';
import '../services/doctor_directory_service.dart';
import '../services/doctor_service.dart';
import '../services/real_data_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/city_picker_sheet.dart';
import '../widgets/doctor_list_card.dart';
import '../widgets/emerald_banner_background.dart';
import '../widgets/location_header.dart';
import '../widgets/product_card.dart';
import '../widgets/provider_application_notice.dart';
import '../widgets/tap_to_dismiss_keyboard.dart';
import 'doctor_profile_screen.dart';
import 'product_details_screen.dart';
import 'shop_details_screen.dart';

/// ★ الرئيسية — مطابقة للتصميم المرجعي (دليل الأطباء):
///   شريط أخضر (جرس · شارة المدينة الشطرة/الناصرية · اطباء ذي قار · الشعار) ثم بانر صيدلية
///   حقيقي متحرك، صفّ (بحث «ابحث بالاسم» + زرّ «تصفية»)، شرائح الفئات،
///   شريط الأطباء المميزين المتدحرج تلقائياً بصورهم الأصلية، ثم بطاقات
///   القائمة البيضاء.
///
///   كل النصوص والأسماء والترتيب كما في المرجع، والألوان تتبع هوية
///   التطبيق الخضراء (#008000). النقر على أي عنصر يفتح الحجز مع التعبئة.
class DoctorsHomeScreen extends StatefulWidget {
  const DoctorsHomeScreen({super.key, this.onOpenTab});

  /// فتح تبويب من الشريط السفلي (شريحة «الأدوية» في نهاية الشرائح).
  final ValueChanged<int>? onOpenTab;

  @override
  State<DoctorsHomeScreen> createState() => _DoctorsHomeScreenState();
}

class _DoctorsHomeScreenState extends State<DoctorsHomeScreen>
    with TabRefreshTarget<DoctorsHomeScreen> {
  @override
  String get tabId => 'home';

  /// نقرة زرّ «الرئيسية»: صعود للأعلى + تحديث قسري للدليل من الشبكة.
  @override
  Future<void> Function() onTabRefresh() => _onRefresh;

  /// يُزاد عند السحب/لمس تبويب الرئيسية فيُعيد جلب حالة طلب الانضمام.
  int _noticeTick = 0;

  Future<void> _onRefresh() async {
    if (mounted) setState(() => _noticeTick++);
    await _load(force: true);
  }

  final TextEditingController _searchCtrl = TextEditingController();

  List<DoctorProfile> _all = DoctorDirectoryService.instance.initial;
  String _query = '';
  String _category = 'doctors';
  // ★ منتجات القسم المختار: قسم الدليل يجمع أطباءه، وإن وُجد قسم منتجات
  //   بنفس الاسم (في `categories`) ظهرت منتجاته تحته أيضاً — طلب الأدمن
  //   2026-11-20 ليكون «العناية بالبشرة» صفحة واحدة للأطباء والمنتجات.
  List<Product> _catProducts = const [];
  Set<String> _closedShopIds = const {};

  /// صيدليات هذا القسم: بطاقتها تظهر في الدليل حين يضبطها الأدمن من
  /// «الصيدليات» (عمود `shops.directory_keys`)، ونقرها يفتح منتجاتها.
  List<Shop> _catShops = const [];
  bool _favOnly = false;

  /// المدينة المختارة لفلتر الدليل — تبدأ من مدينة المستخدم المحفوظة.
  String _city = CityStore.cities.first;
  bool _cityTouched = false;
  Set<String> _favs = {};

  /// ★ بانرات الأدمن — أعلى الرئيسية، بدل صورة الصيدلية الثابتة.
  ///   فارغة ⇒ تبقى الصورة الحقيقية كما كانت.
  List<BannerItem> _banners = const [];

  /// ★ دور الزبون النشط: رقم الحجز الكبير واسم الطبيب والمتبقي.
  ///   `null` ⇒ لا بطاقة (لا حجز موافَق عليه، أو انتهت المعاينة).
  ActiveDoctorTicket? _ticket;
  VoidCallback? _onCatalogChanged;
  VoidCallback? _onDoctorsChanged;

  static const Color _chipBorder = Color(0xFFE7EEF0);

  /// ★ شرائح الأقسام تأتي من القاعدة (`doctor_categories`): الثلاثة
  ///   الأساسية + ما يضيفه الأدمن، فيظهر القسم الجديد للناس فوراً.
  List<DoctorCategory> _cats =
      DoctorDirectoryService.instance.initialCategories;

  static IconData _categoryIcon(String key) => switch (key) {
    'doctors' => Icons.person_outline_rounded,
    'complexes' => Icons.apartment_rounded,
    'labs' => Icons.biotech_outlined,
    _ => Icons.medical_services_outlined,
  };

  @override
  void initState() {
    super.initState();
    _city = CityStore.instance.chosen ?? CityStore.cities.first;
    // ★ اختيار المدينة من ورقة أول فتح (أو من شارة المدينة لاحقاً) يصل
    //   هنا فوراً، فيتبدّل الدليل دون إعادة فتح تبويب.
    CityStore.instance.changed.addListener(_onCityChosen);
    unawaited(_syncChosenCity());
    // ★ البانر يظهر فور إضافته من اللوحة: أي تغيير في الكتالوج (ويشمل
    //   البانرات بعد `clearCache`) يعيد جلبها هنا بلا انتظار تبويب.
    _onCatalogChanged = () => _loadBanners();
    RealDataService.instance.catalogGeneration.addListener(_onCatalogChanged!);
    // ★ إضافة/تعديل/حذف طبيب من لوحة الأدمن تظهر في الدليل فوراً.
    _onDoctorsChanged = () => _load();
    DoctorDirectoryService.instance.generation.addListener(_onDoctorsChanged!);
    _load();
  }

  @override
  void dispose() {
    final cb = _onCatalogChanged;
    if (cb != null) {
      RealDataService.instance.catalogGeneration.removeListener(cb);
    }
    final dcb = _onDoctorsChanged;
    if (dcb != null) {
      DoctorDirectoryService.instance.generation.removeListener(dcb);
    }
    CityStore.instance.changed.removeListener(_onCityChosen);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onCityChosen() {
    final chosen = CityStore.instance.chosen;
    if (!mounted || chosen == null || chosen == _city) return;
    setState(() {
      _city = chosen;
      _cityTouched = false;
    });
  }

  /// شارة المدينة في الشريط العلوي: تبديل حر لاحقاً، مع زر إغلاق.
  Future<void> _openCityPicker() async {
    final picked = await showCityPicker(context, allowClose: true);
    if (picked == null || !mounted || picked == _city) return;
    setState(() {
      _city = picked;
      _cityTouched = false;
    });
    await CityStore.instance.save(picked);
  }

  /// مدينة المستخدم من أول فتح تُطبَّق كفلتر افتراضي — ما لم يغيّرها هو.
  Future<void> _syncChosenCity() async {
    await CityStore.instance.load();
    final chosen = CityStore.instance.chosen;
    if (!mounted || _cityTouched || chosen == null || chosen == _city) return;
    setState(() => _city = chosen);
  }

  Future<void> _loadBanners({bool force = false}) async {
    try {
      final list = force
          ? await RealDataService.instance.refreshBanners()
          : await RealDataService.instance.fetchBanners();
      if (!mounted) return;
      setState(() => _banners = list);
    } catch (_) {
      // بلا بانرات يبقى البانر الحقيقي الثابت معروضاً — لا شاشة فارغة.
    }
  }

  Future<void> _load({bool force = false}) async {
    // السحب للتحديث أو ضغطة تبويب «الرئيسية» تُجلب البانرات من الشبكة
    // مباشرة، فيظهر ما أضافه الأدمن فوراً.
    unawaited(_loadBanners(force: force));
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() => _favs = favs);
    // ★ بطاقة الدور النشط: تُقرأ من القاعدة، وتختفي وحدها بعد
    //   تأكيد انتهاء المعاينة (السجل يبقى في «حجوزاتي»).
    ActiveDoctorTicket? ticket;
    if (AuthService.instance.isLoggedIn) {
      ticket = await DoctorService.instance.activeTicket();
      if (!mounted) return;
      setState(() => _ticket = ticket);
    } else if (_ticket != null) {
      setState(() => _ticket = null);
    }
    final list = await DoctorDirectoryService.instance.fetch(force: force);
    final cats = await DoctorDirectoryService.instance.fetchCategories(
      force: force,
    );
    if (!mounted) return;
    setState(() {
      _all = list;
      _cats = cats;
      // القسم المختار حُذف من اللوحة؟ نعود للأول بدل قائمة فارغة أبدية.
      if (!_cats.any((c) => c.key == _category)) _category = _cats.first.key;
    });
    unawaited(_loadCatProducts(force: force));
  }

  /// منتجات قسم الدليل المختار: إن وُجد قسم منتجات (`categories`) بنفس
  /// اسم قسم الدليل تُعرض منتجاته تحت بطاقات الأطباء في الصفحة نفسها.
  ///
  /// المطابقة بالاسم لا بمعرّف: العالمان (أقسام الأطباء وأقسام المنتجات)
  /// مفصولان في القاعدة، وهذا ما يجعله يعمل فور إنشاء قسم المنتجات من
  /// اللوحة بلا ربط إضافي. القسم العام أولى عند تكرار الاسم.
  ///
  /// ومعها بطاقات الصيدليات التي أسندها الأدمن لهذا القسم
  /// (`shops.directory_keys`) — تظهر ونقرها يفتح منتجاتها.
  Future<void> _loadCatProducts({bool force = false}) async {
    final key = _category;
    var label = '';
    for (final c in _cats) {
      if (c.key == key) {
        label = c.label.trim();
        break;
      }
    }
    // السحب/لمس التبويب يجبر الشبكة: تغيير الأدمن لأقسام الدليل يظهر
    // هنا بلا انتظار عمر الكاش.
    if (force) await RealDataService.instance.refreshShops();
    final shops = await RealDataService.instance.fetchAllShops();
    if (!mounted || key != _category) return;
    final matchedShops = shops
        .where((s) => s.directoryKeys.contains(key))
        .toList(growable: false);
    final closedShopIds = <String>{
      for (final s in shops)
        if (!s.isOpen) s.id,
    };
    void apply({List<Product> products = const []}) {
      setState(() {
        _catProducts = products;
        _catShops = matchedShops;
        _closedShopIds = closedShopIds;
      });
    }

    if (label.isEmpty) {
      if (_catProducts.isNotEmpty || _catShops.isNotEmpty) apply();
      return;
    }
    // ★ قسم «صيدليات» في الدليل يعرض **بروفايلات الصيدليات** وحدها —
    //   لا نجرّ تحته منتجات قسم منتجات يحمل الاسم نفسه (طلب الأدمن
    //   2026-11-21: «قسم دليل الصيدليات تنتقل فيه بروفايلات الصيدلية»).
    if (label == 'صيدليات' || key == 'pharmacies') {
      apply();
      return;
    }
    final cats = await RealDataService.instance.fetchCategories();
    CategoryItem? match;
    for (final c in cats) {
      if (c.title.trim() != label) continue;
      final isGlobal = (c.shopId ?? '').trim().isEmpty;
      if (match == null ||
          (isGlobal && (match.shopId ?? '').trim().isNotEmpty)) {
        match = c;
      }
    }
    if (match == null) {
      if (!mounted || key != _category) return;
      apply();
      return;
    }
    final products = await RealDataService.instance.fetchProductsByCategory(
      match.id,
    );
    if (!mounted || key != _category) return;
    apply(products: products);
  }

  void _openShop(Shop shop) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ShopDetailsScreen(shop: shop)));
  }

  void _openProduct(Product product) {
    // ★ قسم الرئيسية = منتج وحده: لا صفحة صيدلية ولا سياق متجر،
    //   فتُفتح بطاقة هذا المنتج منفردة بلا سحب لبقية منتجات الصيدلية.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductDetailsScreen(
          products: [product],
          initialIndex: 0,
          isStoreOpen: !_closedShopIds.contains(product.shopId),
          showPharmacyInfo: false,
        ),
      ),
    );
  }

  /// نقرة البانر: الوجهة التي اختارها الأدمن من اللوحة أولاً — حساب طبيب
  /// يُفتح بروفايله، أو صيدلية/كوزمتك تُفتح صفحتها — ثم رابط خارجي إن
  /// وُجد، وإلا تبويب الصيدليات، فلا توجد نقرة بلا نتيجة.
  void _onBannerTap(BannerItem banner) {
    final doctorId = banner.doctorId;
    if (doctorId != null) {
      unawaited(_openDoctorById(doctorId));
      return;
    }
    final link = banner.targetUrl?.trim() ?? '';
    if (link.isNotEmpty) {
      final uri = Uri.tryParse(
        link.startsWith('http') ? link : 'https://$link',
      );
      if (uri != null) {
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      }
      return;
    }
    final shopId = banner.shopId;
    if (shopId != null && shopId.isNotEmpty) {
      RealDataService.instance.fetchShopById(shopId).then((shop) {
        if (shop != null && mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ShopDetailsScreen(shop: shop)),
          );
        }
      });
      return;
    }
    widget.onOpenTab?.call(4);
  }

  /// فتح بروفايل الطبيب المرتبط بالبانر من معرّفه.
  ///
  /// الأولوية للمحمَّل في الذاكرة (نفس بيانات الدليل)، وإن لم يوجد — طبيب
  /// أُضيف بعد آخر جلب — نُحدِّث الدليل مرة واحدة ثم نبحث.
  Future<void> _openDoctorById(String id) async {
    DoctorProfile? find(List<DoctorProfile> list) {
      for (final d in list) {
        if (d.id == id) return d;
      }
      return null;
    }

    var doctor = find(_all);
    doctor ??= find(await DoctorDirectoryService.instance.fetch(force: true));
    if (doctor == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DoctorProfileScreen(doctor: doctor!)),
    );
    if (!mounted) return;
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() => _favs = favs);
  }

  List<DoctorProfile> get _inCategory =>
      _all.where((d) => d.category == _category).toList(growable: false);

  bool get _filtering => _query.trim().isNotEmpty || _favOnly;

  bool _inCity(DoctorProfile d) => d.city.isEmpty || d.city == _city;

  List<DoctorProfile> get _visible {
    final q = _query.trim();
    return _inCategory
        .where((d) {
          if (_favOnly && !_favs.contains(d.id)) return false;
          if (!_inCity(d)) return false;
          if (q.isNotEmpty) {
            final hay =
                '${d.name} ${d.title} ${d.specialty} ${d.area} ${d.info}';
            if (!hay.contains(q)) return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  /// شريط المميّزين: لكل قسم شريطه المستقل — يعرض ويحرّك عناصر القسم
  /// المختار وحده، فلا تُخلط الأطباء بالمجمعات أو المختبرات.
  bool get _showFeatured => !_filtering;

  /// ★ كل عناصر القسم في المدينة تدخل الشريط المتحرك: الطبيب أو المختبر
  ///   أو الحساب المحوَّل يظهر فيه فور إضافته، بلا انتظار تعليم «مميز» من
  ///   اللوحة. ترتيب الخادم يضع المميّز أولاً (is_hero ثم is_featured ثم
  ///   sort_order ثم created_at) فيتقدم الجديد على القديم غير المميّز.
  List<DoctorProfile> get _featured => _all
      .where((d) => d.category == _category && _inCity(d))
      .toList(growable: false);

  Future<void> _toggleFav(String id) async {
    await DoctorDirectoryService.instance.toggleFavorite(id);
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() => _favs = favs);
  }

  /// فتح بروفايل الطبيب (التصميم المرجعي). الحجز صار من داخله حتى يكون
  /// بديل «الاتصال» حين لا يوجد فيسبوك، ونبوابة الدخول نفسها.
  Future<void> _openProfile(DoctorProfile d) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DoctorProfileScreen(doctor: d)));
    // المفضلة قد تتغيّر داخل البروفايل — نحدّث القلوب فور الرجوع.
    if (!mounted) return;
    final favs = await DoctorDirectoryService.instance.favorites();
    if (!mounted) return;
    setState(() => _favs = favs);
  }

  Future<void> _openFilterSheet() async {
    var favOnly = _favOnly;
    var city = _city;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'تصفية الدليل',
                style: GoogleFonts.cairo(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'المفضلة فقط',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  'عرض الأطباء الذين علّقتهم بالقلب فقط',
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                value: favOnly,
                activeThumbColor: AppColors.primary,
                onChanged: (v) => setSheet(() => favOnly = v),
              ),
              const Divider(height: 20),
              Text(
                'المدينة',
                style: GoogleFonts.cairo(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in CityStore.cities)
                    ChoiceChip(
                      avatar: const Icon(
                        Icons.location_city_rounded,
                        size: 16,
                        color: AppColors.primary,
                      ),
                      label: Text(c),
                      selected: city == c,
                      selectedColor: AppColors.primary,
                      labelStyle: GoogleFonts.cairo(
                        color: city == c ? Colors.white : AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                      onSelected: (_) => setSheet(() => city = c),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  'تطبيق',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (applied == true && mounted) {
      setState(() {
        _favOnly = favOnly;
        _city = city;
        _cityTouched = true;
      });
      // المدينة من ورقة التصفية ليست فلتراً مؤقتاً: تُحفظ كاختيار المستخدم
      // كي تبقى في الفتح التالي وفي شارة المدينة.
      if (city != CityStore.instance.chosen) {
        unawaited(CityStore.instance.save(city));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final featured = _featured;
    final items = _visible;
    const cardGap = 8.0;
    // هامش جانبي ٢٠ كما في المرجع (هاتف ٣٩٣: ٨٤٠/٩٦٠ ≈ ٢٠).
    const rowPadding = 20.0;
    // ٢٫٦ بطاقة في العرض: أوسع من ثلاث فئات ثابتة، فيكبر الاسم ويبقى
    // للشريط مسافة حقيقية يمشيها حتى يمرّ كل الأطباء ثم يعود للبداية.
    final featuredWidth = (width - rowPadding * 2 - cardGap * 2) / 2.6;
    final activeFilter = _favOnly;
    var catLabel = '';
    for (final c in _cats) {
      if (c.key == _category) {
        catLabel = c.label;
        break;
      }
    }
    // «الأطباء» تبقى أول شريحة على اليمين دائماً: مثبّتة خارج التمرير،
    // وباقي الأقسام يتمرّر إلى يسارها مهما كان ترتيب القاعدة.
    const doctorsKey = 'doctors';
    var doctorsLabel = 'الأطباء';
    for (final c in _cats) {
      if (c.key == doctorsKey) {
        doctorsLabel = c.label;
        break;
      }
    }
    final restCats = _cats
        .where((c) => c.key != doctorsKey)
        .toList(growable: false);

    return Scaffold(
      // خلفية الشريط العلوي الأخضر.
      backgroundColor: AppColors.primary,
      body: TapToDismissKeyboard(
        child: Column(
          children: [
            _TopBar(city: _city, onOpenCityPicker: _openCityPicker),
            Expanded(
              // ★ البانر أصبح سطح الورقة العلوي ممتداً بعرض الشاشة،
              //   فزواياه العلوية مربعة وملتصقة بالشريط الأخضر كما في
              //   الصورة المرجعية (كانت الورقة مستديرة قبل تعديل البانر).
              child: ColoredBox(
                color: Colors.white,
                child: AppRefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _onRefresh,
                  child: ListView(
                    controller: tabScroll,
                    padding: EdgeInsets.zero,
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      // ★ أعلى الرئيسية: بانرات الأدمن إن وُجدت
                      //   (تتقلّب بسرعتها التي ضبطها)، وإلا صورة
                      //   الصيدلية الحقيقية بالحركة الهادئة كما كانت.
                      if (_banners.isEmpty)
                        _KenBurnsBanner(onTap: () => widget.onOpenTab?.call(4))
                      else
                        _HeroBanners(banners: _banners, onTap: _onBannerTap),
                      const SizedBox(height: 10),

                      // رفض/انتظار طلب الانضمام كطبيب أو صيدلاني: أعلى
                      // الرئيسية حتى يراه صاحبه فور فتح التطبيق.
                      ProviderApplicationNotice(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                        reloadTick: _noticeTick,
                      ),

                      // ★ «دوري الآن» — رقم الحجز كبيراً ما دام الدور فعالاً.
                      if (_ticket != null)
                        _ActiveTicketCard(
                          ticket: _ticket!,
                          onOpen: () => widget.onOpenTab?.call(2),
                        ),

                      // بحث «ابحث بالاسم» + زرّ «تصفية»
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: rowPadding,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Container(
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFFE3EFE5),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const SizedBox(width: 12),
                                    const Icon(
                                      Icons.search_rounded,
                                      color: AppColors.primary,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: TextField(
                                        controller: _searchCtrl,
                                        onChanged: (v) =>
                                            setState(() => _query = v),
                                        textInputAction: TextInputAction.search,
                                        style: GoogleFonts.cairo(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.textPrimary,
                                        ),
                                        decoration: InputDecoration(
                                          isDense: true,
                                          isCollapsed: true,
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          disabledBorder: InputBorder.none,
                                          hintText: 'ابحث بالاسم',
                                          hintStyle: GoogleFonts.cairo(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textHint,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            InkWell(
                              onTap: _openFilterSheet,
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                height: 40,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.mintPill,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.tune_rounded,
                                      color: AppColors.primary,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      'تصفية',
                                      style: GoogleFonts.cairo(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        height: 1,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // شرائح الأقسام: «الأطباء» مثبّتة أولاً على اليمين،
                      // ثم باقي أقسام القاعدة و«الأدوية» (تفتح تبويبها).
                      SizedBox(
                        height: 36,
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: rowPadding,
                              ),
                              child: _CategoryChip(
                                label: doctorsLabel,
                                icon: _categoryIcon(doctorsKey),
                                selected: _category == doctorsKey,
                                onTap: () {
                                  setState(() => _category = doctorsKey);
                                  unawaited(_loadCatProducts());
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsetsDirectional.only(
                                  end: rowPadding,
                                ),
                                itemCount: restCats.length + 1,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (_, i) {
                                  if (i == restCats.length) {
                                    return _CategoryChip(
                                      label: 'الأدوية',
                                      icon: Icons.vaccines_outlined,
                                      selected: false,
                                      onTap: () => widget.onOpenTab?.call(3),
                                    );
                                  }
                                  final cat = restCats[i];
                                  return _CategoryChip(
                                    label: cat.label,
                                    icon: _categoryIcon(cat.key),
                                    selected: _category == cat.key,
                                    onTap: () {
                                      setState(() => _category = cat.key);
                                      unawaited(_loadCatProducts());
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      if (_showFeatured && featured.isNotEmpty) ...[
                        _FeaturedMarquee(
                          // مفتاح لكل قسم: تغيير القسم يبدأ حركة القسم الجديد
                          // من بطاقته الأولى بدل منتصف شريط القسم السابق.
                          key: ValueKey('featured_$_category'),
                          doctors: featured,
                          cardWidth: featuredWidth,
                          cardGap: cardGap,
                          padding: rowPadding,
                          onTap: _openProfile,
                        ),
                        const SizedBox(height: 6),
                      ],

                      // شريط المميّزين أعلى القائمة ليس «فئة فارغة»: لا
                      // نعرض رسالة الفراغ حين يكون القسم كله مميّزاً.
                      // ★ رسالة «لا يوجد عناصر» لا تظهر إذا كان تحت القسم
                      //   منتجات صيدليات (قسم «العناية بالبشرة» مثلاً):
                      //   الصفحة ليست فارغة، بل تعرض منتجاتها — أو بطاقات
                      //   صيدليات مُسندة إلى هذا القسم.
                      if (items.isEmpty &&
                          !(_showFeatured && featured.isNotEmpty) &&
                          (_filtering ||
                              (_catProducts.isEmpty && _catShops.isEmpty)))
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: rowPadding,
                            vertical: 36,
                          ),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.search_off_rounded,
                                size: 42,
                                color: AppColors.textHint,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                activeFilter
                                    ? 'لا نتائج مطابقة للتصفية — جرّب توسيعها'
                                    : _filtering
                                    ? 'لا نتائج مطابقة للبحث'
                                    : 'لا يوجد عناصر في $_city بعد',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.cairo(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: rowPadding,
                          ),
                          child: Column(
                            children: [
                              for (final d in items) ...[
                                DoctorListCard(
                                  doctor: d,
                                  isFav: _favs.contains(d.id),
                                  onFav: () => _toggleFav(d.id),
                                  onTap: () => _openProfile(d),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ],
                          ),
                        ),

                      // ★ صيدليات هذا القسم (أسندها الأدمن من «الصيدليات»):
                      //   بطاقة لكل صيدلية، ونقرها يفتح صفحتها بمنتجاتها.
                      if (!_filtering && _catShops.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: rowPadding,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.local_pharmacy_outlined,
                                color: AppColors.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'الصيدليات في $catLabel '
                                  '(${_catShops.length})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.cairo(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: rowPadding,
                          ),
                          child: Column(
                            children: [
                              for (final s in _catShops) ...[
                                _DirectoryShopCard(
                                  shop: s,
                                  onTap: () => _openShop(s),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ],
                          ),
                        ),
                      ],

                      // ★ منتجات قسم المنتجات المطابق لاسم القسم المختار.
                      if (!_filtering && _catProducts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: rowPadding,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.medication_outlined,
                                color: AppColors.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'منتجات قسم $catLabel '
                                  '(${_catProducts.length})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.cairo(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: rowPadding,
                          ),
                          child: Column(
                            children: [
                              for (final p in _catProducts) ...[
                                RepaintBoundary(
                                  child: ProductCard(
                                    product: p,
                                    // ★ قسم الرئيسية يعرض المنتج نفسه فقط،
                                    //   بلا اسم صيدلية تحته.
                                    showShopName: false,
                                    isStoreOpen: !_closedShopIds.contains(
                                      p.shopId,
                                    ),
                                    onTap: () => _openProduct(p),
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// الشريط العلوي الأخضر: [الشعار · اطباء ذي قار] في اليمين، ثم شارة
/// المدينة المختارة (الشطرة/الناصرية) والجرس في اليسار.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.city, required this.onOpenCityPicker});

  final String city;
  final VoidCallback onOpenCityPicker;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 46,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  width: 37,
                  height: 37,
                  padding: const EdgeInsets.all(1.5),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // ★ مرن: مع أيقونة الدردشة صارت أزرار الرأس أكثر، فالاسم
                //   يقصر بـ«…» على الشاشات الضيقة (360dp) بدل تجاوز الصف.
                Expanded(
                  child: Text(
                    'اطباء ذي قار',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: onOpenCityPicker,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.location_on_rounded,
                          color: Colors.white,
                          size: 15,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          city,
                          style: GoogleFonts.cairo(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 1),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white,
                          size: 17,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const NotificationsBell(
                  size: 38,
                  background: Colors.transparent,
                  iconColor: Colors.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// شريحة فئة واحدة — بيضاء بحدّ فاتح، والمحدّدة خضراء كما في المرجع.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : _DoctorsHomeScreenState._chipBorder,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? Colors.white : AppColors.primary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                height: 1,
                color: selected ? Colors.white : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة طبيب مميزة: سطح أبيض حادّ الحواف بتدرّج أخضر خفيف، وصورة بإطار
/// ذهبي رقيق، والاسم هو بطل البطاقة (خط ثقيل داكن) والتخصص تحته هادئاً.
class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({
    required this.doctor,
    required this.width,
    required this.onTap,
  });

  final DoctorProfile doctor;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: 156,
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0xFFF1FAF3)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE2F0E5)),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            _FeaturedAvatar(doctor: doctor),
            const SizedBox(height: 8),
            Text(
              doctor.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                height: 1.25,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              doctor.specialtyLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 10,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            if (doctor.area.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                doctor.area,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 9.5,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textHint,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// دائرة الصورة + الإطار الذهبي + شارة النجمة.
class _FeaturedAvatar extends StatelessWidget {
  const _FeaturedAvatar({required this.doctor});

  final DoctorProfile doctor;

  @override
  Widget build(BuildContext context) {
    const size = 60.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(2.6),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFEBD48A), Color(0xFFC6A94F)],
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: ClipOval(child: doctorAvatarImage(doctor, size, size)),
            ),
          ),
          Positioned(
            left: -2,
            top: -2,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Color(0xFFFDFBF2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.star_rounded,
                color: Color(0xFFC6A94F),
                size: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// بانر صيدلية حقيقي بحركة «كين بيرنز»: تكبير وانزلاق بطيء ومتصل.
class _KenBurnsBanner extends StatefulWidget {
  const _KenBurnsBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_KenBurnsBanner> createState() => _KenBurnsBannerState();
}

class _KenBurnsBannerState extends State<_KenBurnsBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 2.0,
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            child: Image.asset(
              'assets/images/pharmacy_banner.jpg',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_controller.value);
              // الحدّ الأدنى للتكبير يبقي حواف الصورة مخفيّة رغمَ الانزياح.
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translateByDouble(-6.0 + 12.0 * t, -4.0 + 8.0 * t, 0, 1)
                  ..scaleByDouble(1.05 + 0.11 * t, 1.05 + 0.11 * t, 1, 1),
                child: child,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// بانرات الأدمن أعلى الرئيسية: صورة كاملة العرض تتقلّب تلقائياً بسرعة كل
/// بانر كما ضبطها الأدمن (٣–٣٠ ثانية)، وتتوقّف أثناء سحب المستخدم بيده.
class _HeroBanners extends StatefulWidget {
  const _HeroBanners({required this.banners, required this.onTap});

  final List<BannerItem> banners;
  final ValueChanged<BannerItem> onTap;

  @override
  State<_HeroBanners> createState() => _HeroBannersState();
}

class _HeroBannersState extends State<_HeroBanners> {
  final PageController _controller = PageController();
  Timer? _timer;
  int _index = 0;
  bool _holding = false;

  /// ★ نسبة البانر كما في الصورة المرجعية: مقيسة 617×310 ≈ 1.99:1
  ///   (بانر ممتد بعرض الشاشة تماماً، بلا هوامش جانبية وبلا استدارة).
  static const double _aspect = 2.0;

  static const int _minSeconds = 3;
  static const int _maxSeconds = 30;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _HeroBanners oldWidget) {
    super.didUpdateWidget(oldWidget);
    // إعادة الجدولة عند تغيّر المحتوى فعلاً، لا عند كل إعادة رسم: كل
    // إعادة رسم تلغي المؤقّت وتبني غيره فتمنع التقلّب أو تضاعفه.
    final changed =
        oldWidget.banners.length != widget.banners.length ||
        !listEquals(oldWidget.banners, widget.banners);
    if (!changed) return;
    if (_index >= widget.banners.length) _index = 0;
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Duration _durationFor(int index) {
    final seconds = widget.banners[index].speedSeconds;
    final safe = seconds <= 0 ? 6 : seconds.clamp(_minSeconds, _maxSeconds);
    return Duration(milliseconds: safe * 1000);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (widget.banners.length < 2 || _holding) return;
    final next = (_index + 1) % widget.banners.length;
    _timer = Timer(_durationFor(next), _goNext);
  }

  void _goNext() {
    if (!mounted || !_controller.hasClients || widget.banners.isEmpty) {
      _schedule();
      return;
    }
    final next = (_index + 1) % widget.banners.length;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // ★ 2026-11-19 (طلب الأدمن): البانر ممتد بعرض الشاشة كاملاً من الحافة
    //   إلى الحافة، ملتصق بأعلى الورقة أسفل الشريط العلوي مباشرة، بنسبة
    //   2:1 المقيسة من الصورة المرجعية — بلا هوامش جانبية ولا استدارة
    //   ولا إطار ولا ظل، كما في المرجع.
    return AspectRatio(
      aspectRatio: _aspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                _holding = true;
                _timer?.cancel();
              } else if (n is ScrollEndNotification) {
                _holding = false;
                _schedule();
              }
              return false;
            },
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.banners.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _schedule();
              },
              itemBuilder: (context, i) {
                final banner = widget.banners[i];
                return _HeroBannerImage(
                  banner: banner,
                  onTap: () => widget.onTap(banner),
                );
              },
            ),
          ),
          if (widget.banners.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 9,
              child: IgnorePointer(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < widget.banners.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == _index ? 18 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == _index
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(3),
                          boxShadow: const [
                            BoxShadow(color: Color(0x44000000), blurRadius: 3),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// صفحة بانر واحدة: الصورة كاملة بلا قصّ (أو خلفية البانر اللونية بلا صورة)
/// مع عنوانه ونصّه الفرعي فوق تظليل سفلي خفيف يحفظ قراءتهما.
class _HeroBannerImage extends StatelessWidget {
  const _HeroBannerImage({required this.banner, required this.onTap});

  final BannerItem banner;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = banner.imageUrl != null;
    final title = banner.title.trim();
    final subtitle = banner.subtitle.trim();
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ★ 2026-11-19: الصورة تُعرض **كاملة** بلا اقتطاع (contain) —
          //   طلب الأدمن: «لا تقصها، اجعلها كاملة الصورة في البانر».
          //   الخلفية اللونية تملأ الفراغ حول الصورة إن اختلفت أبعادها
          //   عن مستطيل البانر، فلا يظهر شريط فارغ.
          // ★ زوايا قائمة تماماً (بلا أقواس البطاقة): الشرائط الفاتحة أعلى
          //   الصورة وأسفلها تصل إلى الحواف بلا انحناء.
          EmeraldBannerBackground(palette: banner.palette, borderRadius: 0),
          if (hasImage)
            AppImage(
              banner.imageUrl!,
              fit: BoxFit.contain,
              alignment: Alignment.center,
              filterQuality: FilterQuality.medium,
              cacheWidth: 1280,
            ),
          // ★ 2026-11-19: تمديد الشريطين الجانبيين حتى طرفي الشاشة —
          //   الصورة نفسها تبقى كاملة في الوسط، وعمودا حافتها (وفيه
          //   الشرائط الفاتحة العلوية والسفلية) يمتدّان على الفراغ
          //   الجانبي، فلا تنقطع الشرائط قبل الحواف.
          if (hasImage && banner.imageUrl!.startsWith('http'))
            Positioned.fill(
              child: IgnorePointer(
                child: _BannerSideExtension(url: banner.imageUrl!),
              ),
            ),
          // تظليل علوي خفيف جداً + تدرّج سفلي أعمق: النص يُقرأ فوق أي
          // صورة، والصورة تبقى واضحة في وسط البانر.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.14),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.58),
                ],
                stops: const [0.0, 0.22, 0.5, 1.0],
              ),
            ),
          ),
          if (title.isNotEmpty)
            Positioned(
              left: 18,
              right: 18,
              bottom: 22,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      height: 1.25,
                      letterSpacing: 0.1,
                      color: Colors.white,
                      shadows: const [
                        Shadow(
                          color: Color(0x73000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: 0.92),
                        shadows: const [
                          Shadow(
                            color: Color(0x66000000),
                            blurRadius: 5,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// يمدّ عمودَي حافة صورة البانر على الفراغ الجانبي (يمين ويسار) بنفس
/// ارتفاع الصورة المعروضة، فيصل الشريط الفاتح العلوي والسفلي إلى طرفي
/// الشاشة بدل أن ينقطع عند بداية الفراغ الأخضر. الصورة الوسطى نفسها
/// لا تُمسّ (contain كما هي).
class _BannerSideExtension extends StatefulWidget {
  const _BannerSideExtension({required this.url});

  final String url;

  @override
  State<_BannerSideExtension> createState() => _BannerSideExtensionState();
}

class _BannerSideExtensionState extends State<_BannerSideExtension> {
  ui.Image? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _BannerSideExtension oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _detach();
      _image = null;
      _resolve();
    }
  }

  /// نفس مزوّد `AppImage` ونفس الكاش، فالصورة هنا هي التي حمّلتها
  /// الصورة الوسطى أصلاً ولا تُنزَّل مرتين.
  void _resolve() {
    final provider = AppImage.providerFor(AppImage.resolve(widget.url), 800);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() => _image = info.image);
    }, onError: (_, _) {});
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    return CustomPaint(
      painter: _BannerSideExtensionPainter(image),
      size: Size.infinite,
    );
  }
}

class _BannerSideExtensionPainter extends CustomPainter {
  const _BannerSideExtensionPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    if (imageSize.isEmpty || size.isEmpty) return;
    final fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final src = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & imageSize,
    );
    final dst = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (dst.left > 0.5) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(src.left, src.top, 1, src.height),
        Rect.fromLTWH(0, dst.top, dst.left, dst.height),
        paint,
      );
    }
    final rightGap = size.width - dst.right;
    if (rightGap > 0.5) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(src.right - 1, src.top, 1, src.height),
        Rect.fromLTWH(dst.right, dst.top, rightGap, dst.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BannerSideExtensionPainter oldDelegate) =>
      oldDelegate.image != image;
}

/// شريط المميّزين المتحرك: نسخة واحدة من الأطباء فقط — يمشي من أول طبيب
/// حتى آخرهم، ثم يعود بهدوء إلى البداية ويكرر. لا تكرار للبطاقات أثناء
/// المسيرة، وأي طبيب جديد يضيفه الأدمن يدخل الشريط ويُحسب في الرحلة التالية
/// تلقائياً. ويتوقّف مؤقتاً أثناء سحب المستخدم.
class _FeaturedMarquee extends StatefulWidget {
  const _FeaturedMarquee({
    super.key,
    required this.doctors,
    required this.cardWidth,
    required this.cardGap,
    required this.padding,
    required this.onTap,
  });

  final List<DoctorProfile> doctors;
  final double cardWidth;
  final double cardGap;
  final double padding;
  final ValueChanged<DoctorProfile> onTap;

  @override
  State<_FeaturedMarquee> createState() => _FeaturedMarqueeState();
}

class _FeaturedMarqueeState extends State<_FeaturedMarquee>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  late final Ticker _ticker = createTicker(_advance);
  Duration _last = Duration.zero;
  Timer? _resume;
  bool _paused = false;
  bool _autoScroll = false;

  /// أثناء العودة من آخر طبيب إلى أوله: نترك `animateTo` يعمل وحده.
  bool _rewinding = false;

  /// سرعة الانسياب (dp/ثانية) — هادئة كي تبقى البطاقات مقروءة.
  static const double _speed = 16;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant _FeaturedMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    // طبيب جديد (أو حذف) من لوحة الأدمن: القائمة تتغيّر هنا، والحساب في
    // `_advance` يقرأ أقصى مدى جديد كل إطار — فلا حاجة لإعادة تشغيل
    // الحركة من الصفر، والطبيب الجديد يمرّ ضمن الرحلة الحالية.
    if (widget.doctors.length != oldWidget.doctors.length &&
        _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.offset > max) _scroll.jumpTo(max);
    }
  }

  @override
  void dispose() {
    _resume?.cancel();
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _advance(Duration elapsed) {
    final dt =
        (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    if (_rewinding || _paused || dt <= 0 || dt > 0.25 || !_scroll.hasClients) {
      return;
    }
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    final next = _scroll.offset + _speed * dt;
    if (next >= max) {
      // ★ انتهى آخر طبيب: عودة هادئة إلى البداية بدل القفز المفاجئ.
      _rewinding = true;
      _scroll
          .animateTo(
            0,
            duration: const Duration(milliseconds: 750),
            curve: Curves.easeInOutCubic,
          )
          .whenComplete(() => _rewinding = false);
      return;
    }
    _autoScroll = true;
    _scroll.jumpTo(next);
    _autoScroll = false;
  }

  bool _onNotification(ScrollNotification n) {
    if (_autoScroll) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _resume?.cancel();
      _paused = true;
    } else if (n is ScrollEndNotification) {
      _resume?.cancel();
      _resume = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) _paused = false;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final doctors = widget.doctors;
    return SizedBox(
      height: 176,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: widget.padding,
            vertical: 2,
          ),
          itemCount: doctors.length,
          separatorBuilder: (_, _) => SizedBox(width: widget.cardGap),
          itemBuilder: (_, i) {
            final doctor = doctors[i];
            return _FeaturedCard(
              doctor: doctor,
              width: widget.cardWidth,
              onTap: () => widget.onTap(doctor),
            );
          },
        ),
      ),
    );
  }
}

/// بطاقة صيدلية داخل قسم من دليل الرئيسية: أهدأ من بطاقة تبويب
/// «الصيدليات» لأنها داخل قائمة قسم، والمهم فيها الاسم والحالة ونقرة
/// تفتح صفحة الصيدلية بمنتجاتها.
class _DirectoryShopCard extends StatelessWidget {
  const _DirectoryShopCard({required this.shop, required this.onTap});

  final Shop shop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = shop.statusAt();
    final image = shop.logoImage ?? '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: status.isOpen
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : AppColors.divider,
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: image.isEmpty
                    ? Container(
                        width: 54,
                        height: 54,
                        color: AppColors.primaryLight,
                        child: const Icon(
                          Icons.local_pharmacy_outlined,
                          color: AppColors.primary,
                          size: 26,
                        ),
                      )
                    : AppImage(image, width: 54, height: 54, fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      shop.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status.windowLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 11.5,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: status.isOpen
                            ? AppColors.textSecondary
                            : AppColors.danger,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_left_rounded, color: AppColors.textHint),
            ],
          ),
        ),
      ),
    );
  }
}

/// ★ «دوري الآن» — بطاقة الزبون في الرئيسية.
///
///   الرقم كبير وواضح، ومع اسم الطبيب وعدد من يسبقه وحالة الحجز.
///   تبقى ما دام الدور فعالاً، وتختفي تلقائياً بعد تأكيد انتهاء المعاينة
///   (القاعدة تعيد `ticket: null`)، ويبقى الحجز في سجل «حجوزاتي».
class _ActiveTicketCard extends StatelessWidget {
  const _ActiveTicketCard({required this.ticket, this.onOpen});

  final ActiveDoctorTicket ticket;
  final VoidCallback? onOpen;

  String get _remainingText {
    if (ticket.isCalled) return 'حان دورك — توجّه إلى العيادة';
    if (ticket.position <= 0) return 'أنت التالي في الدور';
    if (ticket.position == 1) return 'يسبقك مريض واحد';
    return 'يسبقك ${ticket.position} مرضى';
  }

  String get _whenText {
    final at = ticket.appointmentAt?.toLocal();
    if (at == null) return '';
    final h = at.hour;
    final period = h < 12 ? 'ص' : 'م';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    final mm = at.minute.toString().padLeft(2, '0');
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')} · $h12:$mm $period';
  }

  @override
  Widget build(BuildContext context) {
    final called = ticket.isCalled;
    final accent = called ? AppColors.accentDeep : AppColors.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 74,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(
                      ticket.serialNumber,
                      style: GoogleFonts.cairo(
                        fontSize: 30,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        color: accent,
                      ),
                    ),
                    Text(
                      'رقم دورك',
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ticket.doctorName.isEmpty
                                ? 'دورك في العيادة'
                                : ticket.doctorName,
                            style: GoogleFonts.cairo(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            called
                                ? 'حان دورك'
                                : DoctorStatus.label(ticket.status),
                            style: GoogleFonts.cairo(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (ticket.specialty.isNotEmpty)
                      Text(
                        ticket.specialty,
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      _remainingText,
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (_whenText.isNotEmpty) ...[
                          Icon(
                            Icons.event_available_outlined,
                            size: 13,
                            color: AppColors.textHint,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _whenText,
                              style: GoogleFonts.cairo(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textHint,
                              ),
                            ),
                          ),
                        ] else
                          const Spacer(),
                        if (ticket.examFee > 0) ...[
                          Text(
                            CurrencyFormatter.format(ticket.examFee),
                            style: GoogleFonts.cairo(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Icon(
                          Icons.chevron_left_rounded,
                          size: 18,
                          color: accent,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
