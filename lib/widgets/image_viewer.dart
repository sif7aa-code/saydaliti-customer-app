import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'app_image.dart';

/// عارض الصور الكامل: فتح صورة المنتج بالحجم الكامل مع تحريك وتكبير.
///
/// `asset` لصور الحزمة (صور الدليل المرجعية المدمجة) و`url` لصور السيرفر:
/// أحدهما يكفي، ويُعرض المكبَّر بنفس التكبير والتحريك.
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({super.key, this.url, this.asset, this.title});

  final String? url;
  final String? asset;
  final String? title;

  static Future<void> open(
    BuildContext context, {
    String? url,
    String? asset,
    String? title,
  }) {
    // نفس تحويل المسار الذي تستخدمه البطاقات، وإلا فإن أي مسار نسبي في
    // قاعدة البيانات (مثل `images/products/x.jpg`) يعمل مصغّراً في البطاقة
    // ويُعرض كمستطيل أسود عند فتحه بالحجم الكامل.
    final target = asset != null && asset.isNotEmpty
        ? asset
        : AppImage.resolve(url);
    if (target.isEmpty) return Future<void>.value();
    return Navigator.of(context).push(
      _ImageViewerRoute(
        child: ImageViewerScreen(url: target, asset: asset, title: title),
      ),
    );
  }

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

/// مسار عارض الصور: فتح متأنٍّ (يعطي إحساس «تكبير») لكن إغلاق فوري.
///
/// `PageRouteBuilder` يستخدم **مدة واحدة لل.directionين**، فكان
/// الإغلاق يلتزم ٢٢٠ مللي مثل الفتح ⇒ الإحساس بأن الإغلاق «ثقيل».
/// هنا نُفصل المبدآن: ٢٢٠ للفتح، ١١٠ للإغلاق.
class _ImageViewerRoute extends PageRoute<void> {
  _ImageViewerRoute({required this.child});

  final Widget child;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => 'عارض صور المنتج';

  /// شفاف: نرى الشاشة تحته أثناء التلاشي.
  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  /// نحتفظ بحالة الشاشة أثناء الانتقال (لا تُهدَم ثم تُبنى).
  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  /// ★ الإغلاق: ١١٠ مللي فقط.
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 110);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // secondaryAnimation هوReverse نفسه — نُسرّع التلاشي عند الإغلاق
    // بدل تركه بنفس منحنى الفتح.
    final isClosing = secondaryAnimation.status == AnimationStatus.reverse;
    return FadeTransition(
      opacity: isClosing
          ? CurvedAnimation(parent: animation, curve: Curves.easeOut)
          : animation,
      child: child,
    );
  }
}

class _ImageViewerScreenState extends State<ImageViewerScreen>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  TapDownDetails? _lastTap;
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomAnim;

  /// ★ عرض فكّ الترميز بالبكسل المادي، محسوب مرّة واحدة.
  ///
  /// `devicePixelRatio` مهم: على جهاز بكثافة ٣ لا بد من فكّ صورة
  /// بعرض ٣ أضعاف عرض الشاشة الرقمي وإلا ظهرت موحّدة (blurry).
  /// والسقف ١٦٠٠ بكسل — لا فائدة من فكّ أكثر على أي هاتف.
  int _decodeWidth(BuildContext context) {
    final logical = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final physical = (logical * dpr).round();
    return physical.clamp(600, 1600);
  }

  @override
  void dispose() {
    _transform.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    final Matrix4 end;
    if (_transform.value.isIdentity()) {
      // تكبير ×2.5 حول مركز الشاشة.
      final position = _lastTap?.localPosition ?? Offset.zero;
      const scale = 2.5;
      end = Matrix4.identity()
        ..translateByDouble(
          -position.dx * (scale - 1),
          -position.dy * (scale - 1),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, scale, 1);
    } else {
      end = Matrix4.identity();
    }
    _zoomAnim = Matrix4Tween(begin: _transform.value, end: end).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    )..addListener(() => _transform.value = _zoomAnim!.value);
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          GestureDetector(
            onDoubleTap: _handleDoubleTap,
            onTapDown: (d) => _lastTap = d,
            onTap: () => Navigator.of(context).maybePop(),
            // ★ عزل الطبقة: الصورة بالحجم الكامل طبقة رستنائية منفصلة.
            //   بدون هذا، أي إعادة بناء (مثل rebuild الشريط السفلي عند
            //   التبديل) تُبطل طبقة الصورة الكبيرة ⇒ إعادة رسم كاملة أثناء
            //   الإغلاق.
            child: RepaintBoundary(
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 5,
                child: Center(
                  child: widget.asset != null
                      ? Image.asset(
                          widget.asset!,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white70,
                              size: 64,
                            ),
                          ),
                        )
                      : CachedNetworkImage(
                    imageUrl: widget.url!,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    // ★ الملف الأصلي بهويته الخاصة: لا دلو البطاقة
                    //   (وهو مصغّر) ولا المفتاح المبدئي — نسخة واحدة
                    //   كاملة تُستعمل في كل عمليات الفتح.
                    cacheKey: widget.url,
                    // ★ نفس كاش البطاقات (مفتاح واحد على القرص): صورة
                    //   فُتحت بالعارض لا تُطرد من كاش أصغر منفصل.
                    cacheManager: AppImage.imageCache,
                    // ★★ حصرُ فكّ الترميز: بلا هذا كانت صورة 4000×3000
                    //   تُفكّ إلى نحو ٤٨ ميغابايت داخل ImageCache وتبقى
                    //   هناك. على جهاز بذاكرة ٢ غيغابايت هذا مسار OOM
                    //   مباشر، ومع كل ذلك لا تظهر أوضح من عرض الشاشة.
                    //   ١٦٠٠ بكسل أعرض من أي شاشة، فالفرق غير مرئي.
                    maxWidthDiskCache: 1600,
                    memCacheWidth: _decodeWidth(context),
                    // بدون مربع أبيض أثناء التحميل: الخلفية سوداء أصلاً.
                    placeholder: (_, _) => const SizedBox.shrink(),
                    errorWidget: (_, _, _) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 64,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // أزرار التحكم.
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 10,
            right: 10,
            child: Row(
              children: [
                _CircleBtn(
                  icon: Icons.close_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const Spacer(),
                _CircleBtn(
                  icon: Icons.fit_screen_rounded,
                  onTap: () {
                    _anim.reset();
                    _transform.value = Matrix4.identity();
                  },
                ),
              ],
            ),
          ),
          if (title != null && title.isNotEmpty)
            Positioned(
              bottom: MediaQuery.paddingOf(context).bottom + 22,
              left: 20,
              right: 20,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          const Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'اسحب للتحريك · اضغط مرتين للتكبير',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

/// غلاف permitting فتح الصورة بالحجم الكامل عند الضغط.
class TappableImage extends StatelessWidget {
  const TappableImage({
    super.key,
    required this.child,
    this.url,
    this.title,
  });

  final Widget child;
  final String? url;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => ImageViewerScreen.open(context, url: url, title: title),
      child: child,
    );
  }
}
