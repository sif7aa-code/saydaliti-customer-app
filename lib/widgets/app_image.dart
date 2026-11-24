import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/theme/app_colors.dart';

/// يعرض الصورة تلقائياً حسب المصدر:
/// - `assets/...` → من الأصول المحلية (شعار التطبيق..).
/// - غير ذلك → رابط حقيقي من الإنترنت.
///
/// المساران معاً موثوقان على الويب والأندرويد:
/// - عند تمرير محمّل/خطأ مخصّص → Image.network مباشرة (نمط ثبت عمله في
///   الإصدارات) مع فكّ تشفير بحجم أصغر.
/// - بدون مخصّصات → CachedNetworkImage المخزّن على القرص.
class AppImage extends StatelessWidget {
  const AppImage(
    this.src, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.alignment,
    this.filterQuality,
    this.cacheWidth,
    this.cacheHeight,
    this.errorBuilder,
    this.loadingBuilder,
  });

  final String src;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Alignment? alignment;
  final FilterQuality? filterQuality;
  final int? cacheWidth;
  final int? cacheHeight;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Widget Function(BuildContext, Widget, ImageChunkEvent?)? loadingBuilder;

  bool get _hasCustomHandlers => loadingBuilder != null || errorBuilder != null;

  /// رابط التخزين العام على Supabase (لإكمال المسارات الناقصة).
  static const String _storagePublic =
      'https://piepmqbqdxhnsbynjgmg.supabase.co/storage/v1/object/public';

  /// ★ كاش القرص الموحّد لكل صور التطبيق (بطاقات + عارض الصور).
  ///
  /// المدير الافتراضي يحفظ **٢٠٠ ملف** فقط ثم يطرد الأقدم: كتالوجنا
  /// مئات الصور بدلاءٍ ثلاثة، فكانت الصور تُطرد وتُعاد تنزيلها مع كل
  /// جولة تصفّح — Egress مدفوع مرتين وثلاثاً لنفس الصورة. ٦٠٠ ملف
  /// تغطي الكتالوج الحالي كاملاً بهامش نمو.
  ///
  /// ★ المفتاح `libCachedImageData` نفسه مفتاح المدير الافتراضي:
  /// الملفات المخزّنة على أجهزة الزبائن تبقى صالحة وتُقرأ فوراً —
  /// لا إعادة تنزيل شاملة عند تحديث التطبيق، ولا كاشان متوازيان.
  /// ومدة الصلاحية ٣٠ يوماً كما كانت (الرابط نفسه = الصورة نفسها،
  /// والتحديث يصل برابط جديد لا بتعديل الملف القديم).
  static final CacheManager imageCache = CacheManager(
    Config(
      'libCachedImageData',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 600,
    ),
  );

  /// يحوّل أي مسار ناقص إلى رابط صورة صالح.
  ///
  /// **مفتاح واحد لكل التطبيق**: تُستدعى هذه الدالة من كل مكان يحتاج
  /// رابطاً كاملاً (`ImageViewerScreen`، الإشعارات، رفع الصور) حتى لا
  /// يعمل المسار بنفسه ويُظهر صورة مكسورة.
  ///
  /// `x.jpg` أو `images/products/x.jpg` ← رابط كامل على Supabase.
  static String resolve(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return s;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.startsWith('data:')) return s;

    // ذاكرة مشتركة: نفس الرابط يُطلب مئات المرات (كل بطاقة منتج تُبنى
    // في كل إطار)، وتحويله يعني تقطيع سلاسل متكرر بلا داعٍ.
    final hit = _urlCache[s];
    if (hit != null) return hit;

    var path = s.replaceAll('\\', '/');
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.startsWith('public/')) path = path.substring(7);
    if (path.startsWith('object/')) path = path.substring(7);
    if (path.startsWith('storage/v1/object/public/')) {
      path = path.substring('storage/v1/object/public/'.length);
    }
    final url = '$_storagePublic/$path';
    if (_urlCache.length >= _urlCacheLimit) _urlCache.clear();
    _urlCache[s] = url;
    return url;
  }

  static final Map<String, String> _urlCache = {};
  static const int _urlCacheLimit = 512;

  /// ★★ تحويل الصورة على الخادم: أكبر توفير حقيقي بعد الكاش.
  ///
  /// القياس الفعلي من السيرفر اليوم (٢٠٢٦-١٠-٢٨) على صورة منتج حيّة:
  ///   · الأصل `object/public`  = **56,238 بايت**
  ///   · `render/image` بعرض ٤٠٠ = 35,802 بايت  (−٣٦٪)
  ///   · `render/image` بعرض ٢٠٠ = 14,540 بايت  (−٧٤٪)
  ///   · `render/image` بعرض ٨٠٠ = 52,480 بايت (لا يكاد يوفّر، وأبطأ)
  /// فالتحويل يدفع أتعابه فقط في العروض الصغيرة — وهي بطاقات القوائم
  /// حيث الصورة تُطلب بالعشرات في التمريرة الواحدة. على شبكة جوال
  /// البطيئة Bytes هي الزمن، لا زمن المعالجة.
  ///
  /// ★★ فخّ الاقتطاع — سبّب شكوى «الصور لم تظهر كاملة» (٢٠٢٦-١٠-٢٨):
  /// إرسال `width` وحده يجعل الخدمة تختار وضع الملء الافتراضي، فتُبقي
  /// **ارتفاع الأصل كما هو** وتقتطع العرض. القياس على صورة حيّة
  /// ٧٠٠×٧٠٠: ردّت ٣٦٠×٧٠٠ — شريطاً من **وسط** الصورة، وضاع نصف عرضها
  /// (وقارنتُ البكسل: فرق ٣ فقط عن الاقتصاص الوسطي، و٦٤ عن النسخة
  /// كاملة الأبعاد). لذلك صار الطلب صريحاً بثلاثة قيود معاً.
  ///
  /// ★ حدود الاستعمال (لا تُخالف بلا قياس جديد):
  ///   · يُفعَّل للدلاء الصغيرة فقط (٣٦٠/٥٧٦). دلو ٨٠٠ — وهو صورة
  ///     المنتج الكبيرة — يبقى على الرابط الأصلي: لا ربح فيه، وبه
  ///     يبقى مسار واحد لا يعتمد على خدمة التحويل إطلاقاً.
  ///   · `resize=contain` إلزامي: يحافظ على **كامل** الصورة بلا قصّ.
  ///   · `height` صريح = ضِعف الدلو: يسمح للصور الطويلة بالارتفاع
  ///     الكافي، ومع `contain` لا يُنتج إلا ما يتّسع داخل الصندوق.
  ///   · `format=webp` إلزامي: بلا صيغة يعيد endpoint العرض **JPEG
  ///     أكبر من الأصل** (72,788 بايت مقابل 56,238 في نفس الصورة).
  ///   · أي رابط ليس تخزين Supabase العام (أصل، ملف محلي، data:)
  ///     يمرّ كما هو.
  static String sizedUrl(String url, int bucket) {
    if (bucket > _transformMaxBucket) return url;
    // ★ المفتاح = الرابط + الدلو معاً. بمفتاح الرابط وحده كانت نسخة ٣٦٠
    //   تسلَّم لمكان يحتاج ٥٧٦ ⇒ صورة مصغّرة مُكبَّرة (ضبابية)، وهو خطأ
    //   كشفه الاختبار.
    final key = '$url@$bucket';
    final cached = _sizedCache[key];
    if (cached != null) return cached;
    const marker = '/storage/v1/object/public/';
    final i = url.indexOf(marker);
    if (i < 0) return url;
    final out = '${url.substring(0, i)}/storage/v1/render/image/public/'
        '${url.substring(i + marker.length)}'
        '?width=$bucket&height=${bucket * 2}&resize=contain'
        '&quality=80&format=webp';
    if (_sizedCache.length >= _urlCacheLimit) _sizedCache.clear();
    _sizedCache[key] = out;
    return out;
  }

  /// ★ ٠ = التحويل معطّل تماماً. خدمة `render/image` على المشروع الجديد
  ///   (piepmqbqdxhnsbynjgmg، باقة مجانية) تردّ 403 FeatureNotEnabled — أي
  ///   أن **كل** صورة بطاقة كانت تسقط في مسار البطاقات ذي المعالجات
  ///   المخصّصة (ProductCard، طلب المندوب…) فتظهر مكسورة. الأصل
  ///   `object/public` يعمل دائماً، فنخدمه لكل الدلاء.
  static const int _transformMaxBucket = 0;
  static final Map<String, String> _sizedCache = {};

  /// هل هذا الرابط أصله تخزين Supabase عام؟ (للتشخيص والاختبارات)
  static bool isSupabasePublic(String url) =>
      url.contains('/storage/v1/object/public/');

  // ══════════════════════════════════════════════════════════════════════
  //  ★ صور المنتجات تُرسم في أول إطار (طلب ٢٠٢٦-١١-٠٢)
  //
  //  البطاقة كانت تنتظر قرصاً ثم شبكة ثم فكّ ترميز، فتمرّ إطارٌ فارغ
  //  قبل ظهور الصورة. المنتج نفسه محفوظ على الجهاز (نسخة `CatalogCache`)
  //  وملف صورته غالباً محفوظ منذ أول زيارة — فالمطلوب أن نقرأ **ما هو
  //  محفوظ أصلاً** ونضعه في كاش الذاكرة قبل أن تُبنى البطاقات.
  // ══════════════════════════════════════════════════════════════════════

  /// دلو بطاقة المنتج: `ProductCard` يمرّر `cacheWidth: 360`، فيخرج من
  /// سلّم الدلاء **٥٧٦** دائماً. رقم ثابت لا محسوب، لأن التسخين والتحرير
  /// يجب أن يستعملا المفتاح الذي ستستعمله البطاقة **حرفياً** — لو اختلف
  /// لَمَا وجدت البطاقةُ ما سخّيناه، ولَمَا حُرّر ملف الصورة بعد الحذف.
  static const int cardBucket = 576;

  /// سقف الارتفاع الأقصى لفكّ الترميز مرافقاً لدلو معيّن — نفس اشتقاق `build()`.
  static int maxHeightFor(int bucket) => (bucket * 1.25).round();

  /// المفتاح الذي يُحفظ به ملف الصورة على القرص لهذا الدلو.
  /// المكتبة تحفظ بـ`cacheKey` الذي نمرّره نحن، والرابط وحده لا يكفي:
  /// الصورة نفسها مخزَّنة بثلاث درجات (٣٦٠/٥٧٦/٨٠٠).
  static String diskKey(String url, int bucket) =>
      '${sizedUrl(url, bucket)}@$bucket';

  /// ★ المزوّد الوحيد لصور التخزين: تبنيه `build()` للعرض، وتبنيه دوال
  ///   التسخين والتحرير.
  ///
  /// `CachedNetworkImageProvider` يقارن نفسه بـ
  /// `(cacheKey ?? url, scale, maxHeight, maxWidth)` — لا بالمساواة
  /// النصية للرابط. لذا البناء من دالة واحدة **شرط** أن تجد البطاقةُ
  /// الصورةَ المحشوّة في الذاكرة وترسمها مكانها مباشرة.
  static ImageProvider<Object> providerFor(
    String url,
    int bucket, {
    int? maxHeight,
  }) {
    final served = sizedUrl(url, bucket);
    return CachedNetworkImageProvider(
      served,
      maxWidth: bucket,
      maxHeight: maxHeight,
      cacheKey: '$served@$bucket',
      cacheManager: imageCache,
    );
  }

  /// ★ تسخين **من القرص فقط** — بلا طلب إنترنت واحد.
  ///
  /// `getFileFromCache` يسأل جدول الكاش على الجهاز ولا يلمس الشبكة؛ إن
  /// كان الملف محفوظاً من زيارة سابقة نُدخله كاش الذاكرة العامة
  /// (`precacheImage`) فتجده البطاقة وهي تُبنى لأول مرة وترسمه في نفس
  /// الإطار. وإن لم يكن محفوظاً نتخطّاه: تحمّله يبقى للبطاقة نفسها لحظة
  /// ظهورها على الشاشة، فلا تُستهلك بيانات على صورة لن تُرى أصلاً.
  ///
  /// `limit` يمنع حشو الذاكرة بصور بعيدة عن الشاشة: يُسخَّن ما يظهر
  /// أولاً فقط (الذاكرة العامة تُطرد بالأقدمية، فتحميلُ كل الكتالوج
  /// يطرد أول الصور نفسها — أي لا فائدة ولا توفير).
  static Future<void> warmFromDisk(
    BuildContext context,
    Iterable<String> srcs, {
    int bucket = cardBucket,
    int limit = 24,
  }) async {
    final height = maxHeightFor(bucket);
    for (final raw in srcs.take(limit)) {
      // الشاشة قد تكون أُغلقت أثناء التسخين (خلفية، تنقّل سريع).
      if (!context.mounted) return;
      final url = resolve(raw);
      if (url.isEmpty || !isSupabasePublic(url)) continue;
      try {
        final onDisk = await imageCache.getFileFromCache(diskKey(url, bucket));
        if (onDisk == null) continue;
        // الشاشة قد تُغلق أثناء قراءة القرص، والمحوّل بعدها يحتاج
        // سياقاً حيّاً وإلا كان الاستثناء هو كل ما نجنيه.
        if (!context.mounted) return;
        await precacheImage(
          providerFor(url, bucket, maxHeight: height),
          context,
        );
      } catch (e) {
        // ملف تالف على القرص: تُرك لمسار البطاقة المعتاد (له بديل صورة
        // مكسورة)، فلا يوقف تسخينَ ما بعده صورةٌ واحدة.
        debugPrint('AppImage.warmFromDisk: $e');
      }
    }
  }

  /// ★ تحرير صورة من الجهاز: ملف القرص + النسخة المفكوكة في الذاكرة.
  ///
  /// يُستدعى عند **تأكيد** حذف المنتج لا عند مجرد وصول حدث البث (انظر
  /// `RealDataService.recheckDeletedProduct`): لو حُرّر مبكراً ثم ثبت أن
  /// الحدث إنذارٌ كاذب، لاضطر الجهاز لإعادة تنزيل صورة منتجٍ حيّ —
  /// استهلاكُ بيانات بلا طائل.
  static Future<void> forget(String src) async {
    final url = resolve(src);
    if (url.isEmpty || !isSupabasePublic(url)) return;
    final memory = PaintingBinding.instance.imageCache;
    for (final bucket in const [360, cardBucket, 800]) {
      try {
        await imageCache.removeFile(diskKey(url, bucket));
      } catch (e) {
        // لا ملف بهذا المفتاح: هذا هو الحال الطبيعي لدرجة لم تُطلب بعد.
        debugPrint('AppImage.forget: $e');
      }
      // كاش الذاكرة يفصل بالمزوّد لا بالرابط، فلا يُعرف أي شكلٍ استعملته
      // الشاشة: نُبطل المعيارَين (بمعيار ارتفاع وبلا معيار).
      memory.evict(providerFor(url, bucket));
      memory.evict(providerFor(url, bucket, maxHeight: maxHeightFor(bucket)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (src.startsWith('assets/')) {
      return Image.asset(
        src,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment ?? Alignment.center,
        filterQuality: filterQuality ?? FilterQuality.medium,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        errorBuilder: errorBuilder,
      );
    }

    final url = resolve(src);

    // دقة العرض: حسب مكان الصورة.
    final decodeSize =
        cacheWidth ?? (MediaQuery.sizeOf(context).width ~/ 3).clamp(200, 480);

    // دقة التخزين على القرص: أعلى من دقة العرض بوضوح (شبكية retina)
    // لكنها تبقى صغيرة الحجم (صورة واحدة ~60-90 كيلوبايت بدل الأصلية).
    final diskSize = ((cacheWidth ?? decodeSize) * 1.8)
        .round()
        .clamp(360, 800);
    final diskHeight =
        cacheHeight == null ? null : (cacheHeight! * 1.8).round();

    // ★★ توحيد كاش الصورة (أهم تسريع بعد الشبكة)
    // نفس ملف الصورة كان يُخزَّن في **سبعة** مفاتيح مختلفة (360/576/
    // 648/684/800…) لأن المكتبة تبني المفتاح من الرابط+الحجم. فتُنزَّل
    // الصورة نفسها ٣-٤ مرات فعلياً عند التنقّل بين الرئيسية والقسم
    // والصيدلية والبحث، ولا شيء في الذاكرة مشترك.
    //
    // الحل: «دلو» حجم — نحصر الأحجام في ثلاث درجات، فتنقّل بين الشاشات
    // يجد النسخة محفوظة. نستخدم دلاءً لا مفتاحاً واحداً، لأن مفتاحاً
    // واحداً يجعل النسخة الصغيرة (360) تُعاد في مكان يحتاج 800 ⇒
    // صورة ضبابية. ثلاث درجات توازن بين التوحيد والحدة.
    final bucket = diskSize < 460 ? 360 : (diskSize < 720 ? 576 : 800);
    // ★ الرابط المُستخدَم فعلياً: الدلاء الصغيرة تُطلب مُحوَّلة على
    //   الخادم (أصغر بأكثر من النصف)، والكبيرة تبقى كما هي.
    final served = sizedUrl(url, bucket);
    final cacheKey = '$served@$bucket';

    if (_hasCustomHandlers) {
      // معالجات مخصّصة + كاش على القرص => تعمل بدون إنترنت بعد أول تحميل.
      //
      // `CachedNetworkImageProvider` يشكّل `ResizeImage` داخلياً، فـ
      // `maxWidth/maxHeight` يحدّان حجم فكّ الترميز في الذاكرة.
      // المزوّد من `providerFor` وحده — هو المفتاح الذي يبحث فيه التسخين
      // (`warmFromDisk`)، فلو بُني هنا بشكل مختلف لم تجد البطاقةُ ما
      // سخّيناه وعادت تنتظر القرص والشبكة في أول إطار.
      return Image(
        image: providerFor(
          url,
          bucket,
          maxHeight: diskHeight == null ? null : maxHeightFor(bucket),
        ),
        width: width,
        height: height,
        fit: fit,
        alignment: alignment ?? Alignment.center,
        filterQuality: filterQuality ?? FilterQuality.medium,
        errorBuilder: errorBuilder,
        loadingBuilder: loadingBuilder,
      );
    }

    return CachedNetworkImage(
      imageUrl: served,
      // ★ نفس الدلو ⇒ نسخ واحدة مشتركة بين المقاسات المتقاربة.
      cacheKey: cacheKey,
      cacheManager: imageCache,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment ?? Alignment.center,
      filterQuality: filterQuality ?? FilterQuality.medium,
      memCacheWidth: cacheWidth ?? decodeSize,
      memCacheHeight: cacheHeight,
      maxWidthDiskCache: bucket,
      maxHeightDiskCache: diskHeight,
      // بدون مربع فاتح أثناء التحميل (تفادي الوميض الأبيض).
      placeholder: (_, _) => SizedBox(width: width, height: height),
      errorWidget: (context, failed, error) {
        // ★★ شبكة أمان للتحويل: إن تعذّر `render/image` (خدمة تُعطّل
        //   يوماً، أو صيغة لا يقبلها المحوّل) لا تبقى البطاقة مكسورة —
        //   نعيد الطلب بالرابط الأصلي نفسه، وهو يعمل بلا أي شرط.
        //   وإن فشل الأصل أيضاً نعرض المربّع المعتاد.
        if (failed == url) {
          return _PlaceholderBox(
            width: width,
            height: height,
            icon: Icons.broken_image_outlined,
          );
        }
        return Image(
          image: CachedNetworkImageProvider(
            url,
            maxWidth: bucket,
            cacheKey: '$url@$bucket',
            cacheManager: imageCache,
          ),
          width: width,
          height: height,
          fit: fit,
          alignment: alignment ?? Alignment.center,
          filterQuality: filterQuality ?? FilterQuality.medium,
          errorBuilder: (context, fallbackError, stack) => _PlaceholderBox(
            width: width,
            height: height,
            icon: Icons.broken_image_outlined,
          ),
        );
      },
      imageBuilder: (_, provider) => Image(
        image: provider,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment ?? Alignment.center,
        filterQuality: filterQuality ?? FilterQuality.medium,
      ),
    );
  }
}

class _PlaceholderBox extends StatelessWidget {
  const _PlaceholderBox({this.width, this.height, this.icon});

  final double? width;
  final double? height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon == null) return SizedBox(width: width, height: height);
    return Container(
      width: width,
      height: height,
      color: AppColors.imageBackground,
      child: Icon(icon, color: AppColors.textHint),
    );
  }
}

/// بديل ثابت أثناء تحميل الصورة.
///
/// **استبدل `CircularProgressIndicator` في كل `loadingBuilder`.**
///
/// كل مؤشر تقدّم هو `AnimationController` مستقل يعمل ٦٠ إطاراً/ثانية،
/// وقائمة غير كسولة بعشرات البطاقات كانت تُشغّل عشرات هذه المؤشرات
/// **معاً** بلا فائدة: صورة واحدة لا تستحق حلقة رسم دائمة، والملف
/// الشخصي بهذا الشكل يسخّن الجهاز ويُبطئ الاستجابة لكل لمسة.
class AppImagePlaceholder extends StatelessWidget {
  const AppImagePlaceholder({
    super.key,
    this.width,
    this.height,
    this.color,
    this.icon,
    this.iconColor,
    this.iconSize,
  });

  final double? width;
  final double? height;
  final Color? color;
  final IconData? icon;
  final Color? iconColor;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final i = icon;
    if (i == null) {
      return Container(
        width: width,
        height: height,
        color: color,
      );
    }
    return Container(
      width: width,
      height: height,
      color: color,
      alignment: Alignment.center,
      child: Icon(
        i,
        color: iconColor,
        size: iconSize,
      ),
    );
  }
}