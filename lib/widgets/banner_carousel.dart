import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../models/banner_item.dart';
import 'app_image.dart';
import 'emerald_banner_background.dart';

/// بانر إعلاني متحرك (Carousel) مع نقاط تنقل (Dots Indicator)
/// ويمتلئ بعرض الشاشة، ويتقلّب تلقائياً واحداً تلو الآخر.
class BannerCarousel extends StatefulWidget {
  const BannerCarousel({
    super.key,
    required this.banners,
    this.height = 185,
    this.autoPlay = false,
    this.autoPlayInterval = const Duration(seconds: 4),
    this.indicatorColor = AppColors.brand,
    this.outerPadding = 8,
    this.onBannerTap,
  });

  final List<BannerItem> banners;
  final double height;
  final bool autoPlay;
  final Duration autoPlayInterval;

  /// لون نقطة التنشيط. الافتراضي يبقى كما هو (أخضر الهوية) حتى لا تتغيّر
  /// معاينة البانرات في لوحة الأدمن، والصفحة الرئيسية تمرّر الأخضر
  /// المطابق لصورة المرجع.
  final Color indicatorColor;

  /// الهامش الأفقي حول كل بانر. الافتراضي 8 (معاينة الأدمن)، والمرجع
  /// في الشاشة الرئيسية يوازيه ببقية بطاقات الصفحة.
  final double outerPadding;
  final ValueChanged<BannerItem>? onBannerTap;

  @override
  State<BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<BannerCarousel> {
  late final PageController _controller;
  Timer? _timer;
  int _currentPage = 0;

  /// ★ المستخدم أمسك البانر بيده: يتوقف التنقّل التلقائي حتى يرفع إصبعه.
  ///
  ///   بلا هذا كان المؤقّت يعمل أثناء السحب، فيُكمل `animateToPage` الحركة
  ///   فوق إصبع المستخدم ⇒ البانر «يرقص» بين صفحتين ويبدو التنقّل فوضوياً.
  bool _userHolding = false;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 1.0);
    _scheduleNext();
  }

  @override
  void didUpdateWidget(covariant BannerCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ★ إعادة الجدولة **عند تغيّر المحتوى فعلاً** لا عند كل رسم.
    //
    //   الشاشة الرئيسية تُرسم من جديد كل تحديث بيانات (٦٠ ثانية)، وكانت
    //   كل إعادة رسم تلغي المؤقّت وتبنيه من الصفر: إن جاءت إعادة الرسم
    //   قبل انتهاء المدة لم يتحرّك البانر أبداً، وإن جاءت بعدها تحرّك
    //   مرتين. هذا هو «التنقّل المخربط» نفسه — لا علاقة له بالسرعة.
    //
    //   المقارنة بطول القائمة وعناصرها لا بمعرّف القائمة: كل جلب يعيد
    //   قائمة جديدة حتى لو كان المحتوى هو هو، فلو اكتفينا بـ`identical`
    //   لدُفن المؤقّت مع كل تحديث بيانات.
    final changed =
        oldWidget.banners.length != widget.banners.length ||
        !listEquals(oldWidget.banners, widget.banners) ||
        oldWidget.autoPlay != widget.autoPlay;
    if (changed) {
      if (oldWidget.banners.length != widget.banners.length) {
        _currentPage = 0;
      }
      _clampPage();
      _scheduleNext();
    }
  }

  /// ★ يُبقي الصفحة المحفوظة داخل حدود القائمة الحالية.
  ///
  ///   لو نقص عدد البانرات بقي `_currentPage` على رقمٍ صار خارج القائمة،
  ///   فاحسبنا «التالي» منه أعطى صفحة بعيدة عن التي يعرضها `PageController`
  ///   فعلياً ⇒ قفزة رجعية عبر شاشات. الحقيقة تُقرأ من المتحكّم نفسه.
  void _clampPage() {
    if (widget.banners.isEmpty) {
      _currentPage = 0;
      return;
    }
    final live = _controller.hasClients ? _controller.page : null;
    if (live != null) {
      _currentPage = live.round().clamp(0, widget.banners.length - 1);
    } else if (_currentPage >= widget.banners.length) {
      _currentPage = widget.banners.length - 1;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// ★ مدى السرعة الذي يضبطه الأدمن: ٣–٣٠ ثانية.
  ///
  /// الحدّ هنا هو نفسه المفروض في نموذج الإضافة وشريط التحكم وفي مجر
  /// [RealDataService] ⇒ لا قيمة تُحفظ ثم تُرفض عند العرض بصمت.
  static const int minSeconds = 3;
  static const int maxSeconds = 30;

  /// مدة العرض تُؤخذ من سرعة البانر الحالي التي يحددها الأدمن (٣–٣٠).
  Duration _durationFor(int index) {
    if (widget.banners.isEmpty) return widget.autoPlayInterval;
    final b = widget.banners[index.clamp(0, widget.banners.length - 1)];
    final seconds = b.speedSeconds;
    if (seconds <= 0) {
      return widget.autoPlayInterval < const Duration(seconds: minSeconds)
          ? const Duration(seconds: minSeconds)
          : widget.autoPlayInterval;
    }
    return Duration(milliseconds: seconds.clamp(minSeconds, maxSeconds) * 1000);
  }

  /// يعيد جدولة الحركة حسب سرعة البانر التالي (يتحكم بها الأدمن).
  void _scheduleNext() {
    _timer?.cancel();
    _timer = null;
    if (!widget.autoPlay || widget.banners.length < 2 || _userHolding) return;
    _clampPage();
    final next = (_currentPage + 1) % widget.banners.length;
    _timer = Timer(_durationFor(next), _goToNextPage);
  }

  void _goToNextPage() {
    if (!mounted || !_controller.hasClients || widget.banners.isEmpty) {
      _scheduleNext();
      return;
    }
    // ★ الصفحة تُؤخذ من المتحكّم لا من الذاكرة: إن تغيّر عدد البانرات أو
    //   سحب المستخدم بين الحالتين يبقى «التالي» مجاوراً لما هو معروض فعلاً،
    //   فلا قفزات رجعية ولا تجاوز للصفوف.
    _clampPage();
    final next = (_currentPage + 1) % widget.banners.length;
    _controller.animateToPage(
      next,
      // ★ ٦٥٠ ملّي بمنحنى يبدأ هادئاً وينتهي هادئاً. كان ٨٥٠ ملّي مع
      //   `easeOutQuint`: ينطلق دفعةً عنيفة في أول ١٠٠ ملّي ثم يزحف،
      //   وهو ما يبدو للعين «خربطة» لا انسياباً.
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeInOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() => _currentPage = index.clamp(0, widget.banners.length - 1));
    // إعادة الجدولة بالسرعة المحددة لهذا البانر.
    _scheduleNext();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: widget.height,
          // ★ السحب البشري يوقف المؤقّت ويُستأنف عند رفع الإصبع — فلا
          //   مزاحمة بين إصبع المستخدم وحركة تلقائية نصف منتهية.
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification) {
                if (n.dragDetails != null) {
                  _userHolding = true;
                  _timer?.cancel();
                }
              } else if (n is ScrollEndNotification) {
                _userHolding = false;
                _scheduleNext();
              }
              return false; // لا نبتلع الحدث: الباقي يعمل كما كان.
            },
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.banners.length,
              onPageChanged: _onPageChanged,
              // ★ `physics` الافتراضي لـ PageView الأفقي هي PageScrollPhysics
              //   الأصلية: صفحة واحدة لكل مسحة، وسكون بلا ارتداد.
              //   حُذفت الطبقة «الناعمة» المخصّصة لأنها كانت تُبدّل النابض
              //   فقط (`stiffness` أعلى و`damping` أقل من الافتراضي) فتزداد
              //   الحركة حدّةً واهتزازاً — عكس هدفها المُعلَن.
              itemBuilder: (context, index) {
                final banner = widget.banners[index];
                // هامش متماثل من الجانبين — موسّع قليلاً ليأخذ البانر عرضاً
                // أوفر دون أن يلامس حواف الشاشة.
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    widget.outerPadding,
                    0,
                    widget.outerPadding,
                    0,
                  ),
                  child: _BannerCard(
                    item: banner,
                    onTap: () => widget.onBannerTap?.call(banner),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        _DotsIndicator(
          count: widget.banners.length,
          activeIndex: _currentPage,
          color: widget.indicatorColor,
        ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.item, this.onTap});

  final BannerItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = item.imageUrl != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      // ★ الخلفية من لوحة ألوان البانر نفسه ⇒ كل بانر بلون مختلف مع
      //   نفس البنية الفاخرة، والظلّ يبقى داخل حدود الإطار المستدير.
      child: EmeraldBannerFrame(
        borderRadius: 22,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // ★ مقاس مربّع الشعار ونص الحشو يُشتقّان من ارتفاع البانر
            //   نفسه (الذي تحدده الشاشة الرئيسية بنسبة عرض الشاشة)،
            //   فلا يفيض أي عنصر عن الحدود مهما قُلّص الارتفاع.
            final h = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 185.0;
            final vPad = (h * 0.07).clamp(6.0, 12.0).toDouble();
            final logoSide = (h - 2 * vPad).clamp(56.0, 96.0).toDouble();
            return Stack(
              fit: StackFit.expand,
              children: [
                EmeraldBannerBackground(palette: item.palette),
                // تظليل خفيف جداً لزيادة تباين الصورة دون التأثير على النص.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.10),
                        Colors.black.withValues(alpha: 0.02),
                        Colors.black.withValues(alpha: 0.16),
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
                if (!hasImage) ...[
                  // رسم توضيحي خلفي (دائرة شبه شفافة) عند غياب الصورة.
                  Positioned(
                    left: -30,
                    top: -40,
                    child: Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 60,
                    bottom: -50,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: vPad),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // نص أبيض واضح بإطار داكن — مثل الهاشتاك
                            _StickerText(item.title, fontSize: 20),
                            if (item.subtitle.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              _StickerText(
                                item.subtitle,
                                fontSize: 12.5,
                                strokeWidth: 3.2,
                              ),
                            ],
                          ],
                        ),
                      ),
                      // شعار/صورة الصيدلية: مربّع أبيض مستدير الزوايا يعرض
                      // الصورة **كاملة** (contain) بهامش داخلي — بلا قصّ ولا
                      // تشويه مهما اختلفت أبعاد الشعار، ومقاسه يتبع ارتفاع
                      // البانر فلا يفيض عنه.
                      const SizedBox(width: 12),
                      Container(
                        width: logoSide,
                        height: logoSide,
                        padding: EdgeInsets.all(logoSide * 0.07),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(logoSide * 0.18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.16),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: hasImage
                            ? AppImage(
                                item.imageUrl!,
                                fit: BoxFit.contain,
                                alignment: Alignment.center,
                                filterQuality: FilterQuality.medium,
                                cacheWidth: (logoSide * 3).round(),
                                cacheHeight: (logoSide * 3).round(),
                                errorBuilder: (_, _, _) => Icon(
                                  item.icon,
                                  color: AppColors.brandDark,
                                  size: logoSide * 0.42,
                                ),
                                loadingBuilder: (context, child, progress) =>
                                    progress == null
                                    ? child
                                    : Icon(
                                        item.icon,
                                        color: AppColors.brandDark,
                                        size: logoSide * 0.42,
                                      ),
                              )
                            : Icon(
                                item.icon,
                                color: AppColors.brandDark,
                                size: logoSide * 0.42,
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// مؤشر النقاط أسفل البانر.
class _DotsIndicator extends StatelessWidget {
  const _DotsIndicator({
    required this.count,
    required this.activeIndex,
    required this.color,
  });

  final int count;
  final int activeIndex;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final isActive = index == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsetsDirectional.only(end: 6),
          width: isActive ? 22 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: isActive ? color : AppColors.divider,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

/// نص أبيض نقيّ فوق البانر.
///
/// ★ 2026-10-26: الصورة المرجعية تعرض عناوين البانرات بخط أبيض **بلا إطار
///   أسود** (بانر «استمتع بتوصيل سريع» الأزرق) — كانت الطبقة الداكنة
///   السابقة تعطي مظهر «هاشتاك» ثقيلاً لا يوجد في المرجع. بقي ظل ناعم
///   جداً يحفظ قراءة النص فوق الصور.
class _StickerText extends StatelessWidget {
  const _StickerText(this.text, {this.fontSize = 20, this.strokeWidth = 4.0});

  final String text;
  final double fontSize;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        height: 1.25,
        letterSpacing: 0.2,
        color: Colors.white,
        shadows: const [
          Shadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }
}
