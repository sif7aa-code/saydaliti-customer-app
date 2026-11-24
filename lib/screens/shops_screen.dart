import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/shop_status.dart';
import '../models/shop.dart';
import '../services/real_data_service.dart';
import '../services/recent_view_store.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/shop_circle_strip.dart';
import '../widgets/tap_to_dismiss_keyboard.dart';
import 'shop_details_screen.dart';

/// لوحة ألوان هذه الصفحة فقط — لا يُمسّ `app_colors.dart` لأن بقية الشاشات
/// تعتمد عليه، والطلب: «عدّل صفحة الصيدليات فقط».
abstract final class _ShopsPage {
  /// خلفية الصفحة: أبيض مائل للرمادي الفاتح (كما في المرجع).
  static const Color page = AppColors.background;

  /// أخضر داكن العناوين والنصوص الرئيسية.
  static const Color titleNavy = AppColors.textPrimary;

  /// رمادي/أخضر هادئ للنصوص الثانوية.
  static const Color textMuted = AppColors.textSecondary;

  /// حدود الحقول الفاتحة.
  static const Color fieldBorder = AppColors.divider;

  /// اللوحة الخضراء داخل البطاقة: فاتح أعلى ← أغمق أسفل
  /// (المرجع: `#5fa954` أعلى، `#22864a` أسفل، ودائرة السهم `#0c643a`).
  static const LinearGradient panelGradient = LinearGradient(
    colors: [AppColors.brandLight, AppColors.brand, AppColors.primaryDeep],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.55, 1.0],
  );

  /// دائرة زر الدخول الداكنة أسفل اللوحة.
  static const Color arrowCircle = AppColors.brandDark;

  /// ظل ناعم للبطاقات (بلا هالة عريضة).
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x1415151D), blurRadius: 18, offset: Offset(0, 7)),
  ];

  static const double radius = 14;
  static const double side = 16;
}

class ShopsScreen extends StatefulWidget {
  const ShopsScreen({super.key});

  @override
  State<ShopsScreen> createState() => _ShopsScreenState();
}

class _ShopsScreenState extends State<ShopsScreen>
    with TabRefreshTarget<ShopsScreen> {
  @override
  String get tabId => 'shops';

  /// ★ نقرة زرّ «الصيدليات»: صعود لأول صيدلية + **تحديث حقيقي** — شبكة
  ///   كاملة متجاوزة الكاش، ثم إعادة رسم القائمة منه.
  @override
  Future<void> Function() onTabRefresh() => () async {
    await RealDataService.instance.refreshAll();
    await _load();
  };

  String _query = '';
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<Shop> _allShops = const [];
  List<Shop> _recentlyViewed = const [];

  /// نصوص البحث الصغيرة محسوبة مسبقاً لكل صيدلية، مرة واحدة عند الجلب.
  /// كان `toLowerCase()` يُنادى ثلاث مرات لكل صيدلية **لكل ضغطة مفتاح**.
  List<String> _haystack = const [];

  /// نتيجة التصفية محفوظة، لا تُحسب داخل `build`.
  List<Shop> _filtered = const [];
  String _filteredFor = '';

  Timer? _debounce;

  /// حالة الصيدلية تُحسب من الساعة، فلا تكفي أول رسمة: عند بلوغ ساعة الفتح أو
  /// الإغلاق يجب أن تنقلب البطاقة من نفسها، لا عند إعادة تحميل الصفحة.
  Timer? _clockTick;

  VoidCallback? _onCatalogChanged;

  @override
  void initState() {
    super.initState();
    // ★ مثل الرئيسية: أي تغيير في الكتالوج (اسم صيدلية، صورة، فتح/إغلاق)
    //   يعيد الجلب فوراً — بدونه بقيت الشبكة تعرض النسخة المحلية القديمة
    //   حتى سحب يدوي، وهو عين ما اشتُكي منه («تظهر على شكل محلية»).
    _onCatalogChanged = () {
      if (mounted) _load();
    };
    RealDataService.instance.catalogGeneration.addListener(_onCatalogChanged!);
    _load();
    // ★ تسخين الكتالوج: الدخول للصيدلية من هذه الصفحة يصفّي منتجاته من الذاكرة
    //   إن كان محمَّلاً، فكلما بكُر بدء التحميل طال الشاشة الفارغة.
    RealDataService.instance.warmProducts();
    _clockTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    final cb = _onCatalogChanged;
    if (cb != null) {
      RealDataService.instance.catalogGeneration.removeListener(cb);
    }
    _clockTick?.cancel();
    _debounce?.cancel();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      RealDataService.instance.fetchAllShops(),
      RecentViewsStore.instance.resolveShops(),
    ]);
    if (!mounted) return;
    final shops = results[0];
    setState(() {
      _allShops = shops;
      _recentlyViewed = results[1];
      _haystack = [
        for (final s in shops)
          '${s.name}\n${s.categoryName}\n${s.specialNote ?? ''}'.toLowerCase(),
      ];
      _applyFilter();
    });
  }

  void _applyFilter() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      _filtered = _allShops;
    } else {
      _filtered = [
        for (var i = 0; i < _allShops.length; i++)
          if (_haystack[i].contains(q)) _allShops[i],
      ];
    }
    _filteredFor = _query;
  }

  /// تأخير قصير: إعادة بناء كل بطاقة (مع تدرّجاتها وظلالها
  /// وصورها) عند كل حرف يكتب أسرع من أن يكون مقبولاً بصرياً.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {
        _query = value;
        _applyFilter();
      });
    });
  }

  /// ★ السحب للتحديث يجلب من الشبكة متجاوزاً الكاش: كانت `_load()` وحدها
  ///   تعيد نسخة الذاكرة إن عمرها أقل من ٦٠ ثانية، فصيدلية يضيفها/يعدّلها
  ///   الأدمن لا تظهر مع السحب — وهو عين «الكاش في صفحة الصيدليات»
  ///   (بلاغ 2026-11-20). `refreshShops` يجبر الجلب ثم نعيد الرسم منه.
  Future<void> _onRefresh() async {
    await RealDataService.instance.refreshShops();
    await _load();
  }

  void _openShopDetails(Shop shop) {
    // ★ التسخين عند الضغط لا بعد البناء: إن كان الكتالوج محمَّلاً في الذاكرة
    //   فهذا لا يكلف شيئاً، وإن لم يكن فقد بدأ جلبه قبل أن تُبنى الشاشة —
    //   لا تنتظر الشاشة الفراغية دورها في الطابور.
    unawaited(RealDataService.instance.fetchProducts(shopId: shop.id));
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ShopDetailsScreen(shop: shop)));
  }

  @override
  Widget build(BuildContext context) {
    // يحسب مرة واحدة فقط عند تغيّر البيانات أو البحث.
    if (_filteredFor != _query) _applyFilter();
    final results = _filtered;
    final hasRecent = _recentlyViewed.isNotEmpty;
    // 0..3 رأس + شريط recently-viewed اختياري + فاصل + ترويسة + فاصل
    // + جسم النتائج + فاصل.
    final headCount = 4 + (hasRecent ? 2 : 0);
    final itemCount = headCount + 1 + (results.isEmpty ? 1 : results.length);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: _ShopsPage.page,
        body: TapToDismissKeyboard(
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _ShopsPage.side,
                    12,
                    _ShopsPage.side,
                    8,
                  ),
                  child: SizedBox(
                    height: 52,
                    child: _SearchRow(
                      controller: _searchCtl,
                      focusNode: _searchFocus,
                      onChanged: _onQueryChanged,
                    ),
                  ),
                ),
                Expanded(
                  child: AppRefreshIndicator(
                    color: AppColors.primary,
                    onRefresh: _onRefresh,
                    child: ListView.builder(
                      controller: tabScroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: _ShopsPage.side,
                      ),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        // ★ الترويسة والقائمة مرفوعتان للأعلى: كانت الفراغات
                        //   العلوية (8 + 24 + 14 + 6 داخل الترويسة) تجمع
                        //   ٥٢ بكسل قبل أول بطاقة.
                        if (index == 0) return const SizedBox(height: 2);
                        if (hasRecent) {
                          if (index == 1) {
                            return ShopCircleStrip(
                              shops: _recentlyViewed,
                              onShopTap: _openShopDetails,
                            );
                          }
                          if (index == 2) return const SizedBox(height: 14);
                        }
                        final headBase = hasRecent ? 3 : 1;
                        if (index == headBase) return const _SectionTitle();
                        if (index == headBase + 1) {
                          return const SizedBox(height: 6);
                        }

                        if (results.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 60),
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.search_off_rounded,
                                  color: AppColors.textHint,
                                  size: 48,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'لا توجد نتائج مطابقة',
                                  style: GoogleFonts.cairo(
                                    color: _ShopsPage.textMuted,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        if (index == itemCount - 1) {
                          return const SizedBox(height: 24);
                        }
                        final i = index - headBase - 2;
                        if (i < 0 || i >= results.length) {
                          return const SizedBox.shrink();
                        }
                        final shop = results[i];
                        return Column(
                          children: [
                            RepaintBoundary(
                              child: _ShopListCard(
                                key: ValueKey<String>(shop.id),
                                shop: shop,
                                onTap: () => _openShopDetails(shop),
                              ),
                            ),
                            if (i != results.length - 1)
                              const SizedBox(height: 18),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ترويسة «جميع الصيدليات» + الخط الأخضر تحتها (كما في المرجع).
class _SectionTitle extends StatelessWidget {
  const _SectionTitle();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'جميع الصيدليات',
            style: TextStyle(
              color: _ShopsPage.titleNavy,
              fontSize: 21,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 5),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.all(Radius.circular(4)),
            ),
            child: SizedBox(width: 46, height: 4),
          ),
        ],
      ),
    );
  }
}

/// شريط البحث: حقل أبيض مستدير + زرّ المربع الأخضر في يمينه.
class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // المرجع: المربع الأخضر في أقصى اليمين ثم الحقل يملأ الباقي.
        _SearchIconButton(onTap: focusNode.requestFocus),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 52,
            child: Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(26),
              elevation: 0,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                textAlign: TextAlign.right,
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: _ShopsPage.titleNavy,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'ابحث عن صيدلية...',
                  hintStyle: GoogleFonts.cairo(
                    color: AppColors.textHint,
                    fontWeight: FontWeight.w600,
                  ),
                  // المرجع: عدسة البحث في أقصى اليسار بلا أيقونة صيدلية داخله.
                  suffixIcon: const Icon(
                    Icons.search_rounded,
                    color: AppColors.textHint,
                    size: 22,
                  ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: const BorderSide(
                      color: _ShopsPage.fieldBorder,
                      width: 1.2,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: const BorderSide(
                      color: _ShopsPage.fieldBorder,
                      width: 1.2,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(26),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.4,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// زرّ المربع الأخضر بأيقونة الصيدلية: ينقل التركيز إلى حقل البحث.
class _SearchIconButton extends StatelessWidget {
  const _SearchIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: const SizedBox(
          width: 52,
          height: 52,
          child: Icon(Icons.storefront_rounded, color: Colors.white, size: 25),
        ),
      ),
    );
  }
}

/// بطاقة صيدلية بأسلوب المرجع: لوحة خضراء يسار، شعار دائري في الوسط،
/// والاسم وأوقات العمل يميناً مع سهم أخضر في أقصى اليمين.
/// `ShopCard` المشتركة مع شاشة القسم تُركت كما هي حتى لا يتغيّر مظهرها.
class _ShopListCard extends StatelessWidget {
  const _ShopListCard({super.key, required this.shop, this.onTap});

  final Shop shop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // ★ الحالة من الوقت الحقيقي لا من `shops.is_open` الخام: المفتاح اليدوي
    //   وحده كان يقول «مغلق» لصيدليةٍ جدوله says مفتوح، والعكس.
    final status = shop.statusAt();
    final isOpen = status.isOpen;
    final width = MediaQuery.sizeOf(context).width - (_ShopsPage.side * 2);
    // نسب مقياسة من المرجع: ارتفاع البطاقة 26.2% من عرضها، واللوحة
    // الخضراء 27.6% منه.
    final height = (width * 0.262).clamp(86.0, 104.0);
    final panelWidth = width * 0.276;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_ShopsPage.radius),
        child: Container(
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(_ShopsPage.radius),
            boxShadow: _ShopsPage.cardShadow,
          ),
          child: Row(
            children: [
              const _GoChevron(),
              Expanded(
                child: _Info(shop: shop, status: status),
              ),
              _LogoBadge(shop: shop, size: height - 14),
              _StatusPanel(isOpen: isOpen, width: panelWidth),
            ],
          ),
        ),
      ),
    );
  }
}

/// اللوحة الخضراء: حبّة «مفتوح الآن» أعلى ودائرة السهم أسفلها.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.isOpen, required this.width});

  final bool isOpen;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(gradient: _ShopsPage.panelGradient),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          children: [
            const Spacer(),
            _StatusPill(isOpen: isOpen),
            const Spacer(flex: 3),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: const _ArrowCircle(),
            ),
          ],
        ),
      ),
    );
  }
}

/// حبّة الحالة: حدّ أبيض وشفافية خفيفة ونقطة بيضاء.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.isOpen});

  final bool isOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 1.3,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isOpen ? Colors.white : AppColors.dangerLight,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            // ★ تصغير بدل الحذف: اللوحة الخضراء عرضها ثابت، و«مفتوح الآن»
            //   كانت تُقصّ إلى «مفتوح الآن…» فتبدو الكلمة غير صحيحة.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isOpen ? 'مفتوح الآن' : 'مغلق',
                maxLines: 1,
                style: GoogleFonts.cairo(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// دائرة داكنة داخلها سهم أبيض — في أسفل اللوحة الخضراء.
class _ArrowCircle extends StatelessWidget {
  const _ArrowCircle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: const BoxDecoration(
        color: _ShopsPage.arrowCircle,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.chevron_right_rounded,
        color: Colors.white,
        size: 19,
      ),
    );
  }
}

/// الاسم وأوقات العمل، محاذيين لليمين كما في المرجع.
class _Info extends StatelessWidget {
  const _Info({required this.shop, required this.status});

  final Shop shop;
  final ShopStatus status;

  @override
  Widget build(BuildContext context) {
    final isOpen = status.isOpen;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ShopName(name: shop.name),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 15,
                color: isOpen ? AppColors.primary : AppColors.textHint,
              ),
              const SizedBox(width: 5),
              Expanded(
                // تصغير عند الضيق بدل «…» — الوقت مطلوب ظاهراً كاملاً.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    status.windowLine,
                    maxLines: 1,
                    style: GoogleFonts.cairo(
                      color: isOpen ? _ShopsPage.textMuted : AppColors.danger,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// اسم الصيدلية كاملاً بلا «…»: يبدأ بخط 15 وينزل درجةً درجةً حتى يسع
/// الاسم سطرين، لأن الخط الكبير بسطور متلاصقة كان يجعل الاسم مخربطاً.
class _ShopName extends StatelessWidget {
  const _ShopName({required this.name});

  final String name;

  static const _sizes = [15.0, 14.0, 13.0, 12.0, 11.0];

  TextStyle _style(double size) => GoogleFonts.cairo(
    color: _ShopsPage.titleNavy,
    fontSize: size,
    fontWeight: FontWeight.w800,
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        var style = _style(_sizes.last);
        for (final size in _sizes) {
          final painter = TextPainter(
            text: TextSpan(text: name, style: _style(size)),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 2,
          )..layout(maxWidth: constraints.maxWidth);
          final fits = !painter.didExceedMaxLines;
          painter.dispose();
          if (fits) {
            style = _style(size);
            break;
          }
        }
        return Text(name, maxLines: 2, softWrap: true, style: style);
      },
    );
  }
}

/// السهم الأخضر في أقصى يمين البطاقة.
class _GoChevron extends StatelessWidget {
  const _GoChevron();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsetsDirectional.only(start: 2, end: 12),
      child: Icon(
        Icons.chevron_right_rounded,
        color: AppColors.primary,
        size: 24,
      ),
    );
  }
}

/// شعار الصيدلية داخل دائرة بيضاء — الصورة كاملة بلا قص.
class _LogoBadge extends StatelessWidget {
  const _LogoBadge({required this.shop, required this.size});

  final Shop shop;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasImage = shop.logoImage != null && shop.logoImage!.isNotEmpty;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.08),
      decoration: BoxDecoration(
        color: AppColors.imageBackground,
        shape: BoxShape.circle,
        border: Border.all(color: _ShopsPage.fieldBorder, width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2215151D),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: hasImage
          ? AppImage(
              shop.logoImage!,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              cacheWidth: (size * 3).round(),
              cacheHeight: (size * 3).round(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : const AppImagePlaceholder(),
              errorBuilder: (_, _, _) =>
                  Icon(shop.logo, color: AppColors.primary, size: size * 0.45),
            )
          : Icon(shop.logo, color: AppColors.primary, size: size * 0.45),
    );
  }
}
