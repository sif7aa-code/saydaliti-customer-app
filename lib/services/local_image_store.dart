import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'supabase_service.dart';

/// حدود الوضوح حسب نوع المحتوى.
///
/// ★★ **توليد واحد للضغط** لا اثنين:
///   كان `image_picker` يعيد ترميز الصورة بـq70، ثم `_compressSync`
///   يفكّ تلك الـq70 ويُعيد ترميزها q70 ثانية — ضياعُ جيلٍ كامل من
///   التفاصيل (generation loss). الآن الالتقاط بلا فقدٍّ تقريباً
///   (q100، دورها حصراً تحديد أبعاد الفكّ)، والضغط الحقيقي هنا وحده.
class ImageProfile {
  const ImageProfile({required this.maxWidth, required this.quality});
  final int maxWidth;
  final int quality;

  /// شعارات الصيدليات: ٧٠٠ بكسل تكفي لعرض بعرض ٢٨٠ على بطاقة و٢٨٠
  /// على الشريط الدائري، وتكفي لعارض الصور بالحجم الكامل تقريباً.
  /// ★ ٢٠٢٦-١١-٠٢: ٧٦ ← ٧٥ مع بقاء العرض ٧٠٠ (طلب «لا تستهلك بيانات
  ///   ومساحة»): القياس على ٥١ صورة من صور الأدمن نفسها — المتوسط
  ///   ٣٧٫٣ كيلوبايت ← ٣٢٫٢ أي **أقل ١٣٫٨٪**، بلا تغيير في الأبعاد.
  static const shop = ImageProfile(maxWidth: 700, quality: 75);

  /// صورة الحساب: دائرية بحجم صغير، ٤٠٠ بكسل أكثر من كافية.
  /// ★ الوجه أحسن ما يُضغط لأرضية النطاق، فبقي على ٧٨ لا ٨٦.
  static const avatar = ImageProfile(maxWidth: 400, quality: 78);
}

/// يلتقط صوراً من المعرض، يضغطها، ويرفعها مباشرة إلى سحابة التطبيق
/// (Supabase Storage). لا يحفظ أي شيء محلياً على الجهاز — فيُخزَّن
/// في قاعدة البيانات رابطٌ عام (public URL) يظهر لجميع الأجهزة.
class LocalImageStore {
  LocalImageStore._();
  static final LocalImageStore instance = LocalImageStore._();

  /// وصف فشل آخر رفع (بلا رسائل فنية طويلة) لعرضه في شاشات الأدمن.
  String get lastUploadFailure =>
      SupabaseService.instance.lastUploadError ??
      'فشل رفع الصورة للسيرفر — تأكد من اتصال الإنترنت وأعد المحاولة.';

  /// وصف فشل آخر محاولة فتح المعرض/الكاميرا.
  String lastPickerFailure = '';

  // ★ معلومات آخر صورة رُفعت — لعرضها للأدمن (طلب 2026-10-10:
  //   «عند رفع صورة أظهر له حجمها»). الأبعاد 0 تعني لم نستطع قراءتها.
  int lastUploadBytes = 0;
  int lastUploadWidth = 0;
  int lastUploadHeight = 0;

  /// نص الحجم مختصرًا: «٢٤ كيلوبايت» أو «١٫٣ ميغابايت».
  ///
  /// ★ الأرقام باللاتينية عمدًا: كل أرقام شاشات الأدمن عندنا لاتينية
  ///   (الأسعار والطلبات)، فمزج رقم عربي داخل سطر لاتيني يشوّش العين.
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes بايت';
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb < 100 ? kb.toStringAsFixed(1) : kb.toStringAsFixed(0)} كيلوبايت';
    }
    return '${(kb / 1024).toStringAsFixed(2)} ميغابايت';
  }

  /// ★ جودة WebP للصور الجديدة — نطاق **٧٥–٨٠** (طلب الأدمن ٢٠٢٦-١١-٠٢:
  ///   «اضغط الصور الجديدة بحيث لا تستهلك بيانات ومساحة»).
  ///
  /// كان `quality + 6` بشريط ٧٥–٨٠، أي أن **كل** صورة تخرج على السقف ٨٠
  /// مهما كانت الجودة المطلوبة (٧٦ ⇒ ٨٢ ⇒ ٨٠، و٨٠ ⇒ ٨٦ ⇒ ٨٠): رفعٌ صامت
  /// للبتّات بلا فرق مرئي. الآن الجودة الممرّرة هي الجودة الناتجة، محصورة
  /// داخل النطاق: الأرضية ٧٥ تمنع جودة متدنية لو مُرّرت من مسار قديم،
  /// والسقف ٨٠ يمنع ما زاد على المطلوب.
  static int webpQualityFor(int quality) => quality.clamp(75, 80);

  /// اختيار صورة من المعرض (بدون رفع). يعيد الملف المختار أو null عند الإلغاء.
  ///
  /// ★ `maxWidth` هنا **حدّ أعلى لفكّ الترميز فقط** لا ضغط: نمرّر
  ///   عرضاً سخياً (١٦٠٠) لأن [uploadPicked] هو من يصغّر فعلياً.
  ///   و`quality: 100` يعني «بلا فقد» — أي ضغط حقيقي يحدث مرّة واحدة
  ///   في [compressOnly]. كان يمرّ مرّتين فيضيع الوضوح.
  Future<XFile?> pickImage({
    int maxWidth = 1600,
    int quality = 100,
    ImageProfile? profile,
  }) async {
    lastPickerFailure = '';
    if (profile != null) {
      maxWidth = profile.maxWidth * 2;
      quality = 100;
    }
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: maxWidth.toDouble(),
        imageQuality: quality,
        requestFullMetadata: false,
      );
      return file;
    } catch (e) {
      lastPickerFailure = 'تعذر فتح المعرض: $e';
      return null;
    }
  }

  /// التقاط صورة بالكاميرا (بديل عند تعذّر المعرض).
  Future<XFile?> captureImage({
    int maxWidth = 1600,
    int quality = 100,
    ImageProfile? profile,
  }) async {
    lastPickerFailure = '';
    if (profile != null) {
      maxWidth = profile.maxWidth * 2;
      quality = 100;
    }
    try {
      return await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: maxWidth.toDouble(),
        imageQuality: quality,
      );
    } catch (e) {
      lastPickerFailure = 'تعذر فتح الكاميرا: $e';
      return null;
    }
  }

  /// رفع صورة مختارة سابقاً للسيرفر بعد ضغطها. يعيد الرابط العام
  /// عند النجاح أو null عند الفشل (مع شرح السبب في [lastUploadError]).
  Future<String?> uploadPicked(
    XFile file, {
    String folder = 'shops',
    int maxWidth = 700,
    int quality = 75,
    ImageProfile? profile,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final out = await compressOnly(
        bytes,
        maxWidth: profile?.maxWidth ?? maxWidth,
        quality: profile?.quality ?? quality,
      );
      // ★ معلومات تُعرض للأدمن بعد الرفع: الحجم الفعلي للملف الذي صار
      //   في السحابة (لا حجم الملف الأصلي على الهاتف)، وأبعاده.
      lastUploadBytes = out.bytes.length;
      lastUploadWidth = out.width;
      lastUploadHeight = out.height;
      final isWebp = _looksLikeWebp(out.bytes);
      return SupabaseService.instance.uploadImage(
        out.bytes,
        folder: folder,
        mimeType: isWebp ? 'image/webp' : 'image/jpeg',
        extension: isWebp ? 'webp' : 'jpg',
      );
    } catch (e) {
      SupabaseService.instance.lastUploadError =
          'تعذر قراءة الصورة أو ضغطها: $e';
      return null;
    }
  }

  /// هل البايتات الناتجة WebP فعلاً؟ نبني الشارة من أول ١٢ بايت (RIFF….WEBP)
  /// بدل الافتراض، فأي فشل في ترميز WebP يُرفع JPEG كما هو.
  static bool _looksLikeWebp(Uint8List bytes) {
    if (bytes.length < 12) return false;
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final webp = String.fromCharCodes(bytes.sublist(8, 12));
    return riff == 'RIFF' && webp == 'WEBP';
  }

  /// ضغط صورة (Resize + JPG) وإرجاع البايتات المضغوطة لرفع سريع وخفيف.
  /// عند أي فشل في الضغط تُرجَع البايتات الأصلية كما هي.
  ///
  /// حزمة `image` مكتوبة بـ Dart خالص بلا خيوط نظام، فكان فكّ الترميز
  /// والتصغير وإعادة الترميز تجري على الـ isolate الرئيسي: الواجهة
  /// تتجمّد تماماً (بضع مئات من الأجزاء من الثانية إلى ثوانٍ) لحظة رفع
  /// أي صورة. `Isolate.run` ينقلها إلى isolate منفصل فيبقى التطبيق
  /// مستجيباً للمسة طوال العملية.
  Future<({Uint8List bytes, int width, int height})> compressOnly(
    Uint8List bytes, {
    int maxWidth = 700,
    int quality = 76,
  }) async {
    try {
      return await Isolate.run(
        () => _compressSync(bytes, maxWidth, quality),
        debugName: 'image-compress',
      );
    } catch (_) {
      // لم نضغط (فكّ ترميز فشل أو isolate معطّل): الحجم معروف،
      // والأبعاد مجهولة ⇒ ٠، فلا نعرض للعين أرقاماً مخترعة.
      return (bytes: bytes, width: 0, height: 0);
    }
  }
}

/// العمل الثقيل — يعمل على isolate منفصل، فلا يلمس الواجهة.
///
/// ★★ **WebP بدل JPEG**: الملف يصغر نحو ٣٥–٥٠٪ **دون أي فرق مرئي**،
/// لأن WebP يوفّر تفاصيل أنظف من JPEG عند نفس حجم الملف. الجودة ضمن
/// نطاق **٧٥–٨٠** عبر [LocalImageStore.webpQualityFor] (قرار الأدمن
/// ٢٠٢٦-١١-٠١). إن فشل الترميز (نسخة قديمة من الحزمة) نعود
/// إلى JPEG بالجودة المطلوبة فلا يضيع شيء على المستخدم.
({Uint8List bytes, int width, int height}) _compressSync(
  Uint8List bytes,
  int maxWidth,
  int quality,
) {
  try {
    img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return (bytes: bytes, width: 0, height: 0);
    if (decoded.width > maxWidth) {
      // ★★ `interpolation` الافتراضي في `copyResize` هو **nearest**
      //   (أقرب جار): التصغير به *يُسقط* البكسلات ولا يجمعها، فتتشوّه
      //   الحوافّ وتضيع التفاصيل الدقيقة. كان هذا أكبر مسرّب للوضوح
      //   في المسار كلّه. `average` يجمع ألوان البكسلات ⇒ أنعم وأوضح،
      //   وبنفس الحجم تقريباً.
      decoded = img.copyResize(
        decoded,
        width: maxWidth,
        interpolation: img.Interpolation.average,
      );
    }
    // ★ JPEG لا يقبل شفافية: المناطق الشفافة تُكتب سوداء. فشعارٌ
    //   PNG شفّاف كان يظهر لأدمنه صحيحاً (معاينة محلية من `Image.file`)
    //   ويظهر لغيره مربعاً أسود — سببٌ شائع لـ«الصور ما تظهر للكل».
    //   نضعه على خلفية بيضاء قبل الترميز.
    if (decoded.numChannels == 4) {
      final bg = img.Image(
        width: decoded.width,
        height: decoded.height,
        numChannels: 3,
      );
      img.fill(bg, color: img.ColorRgb8(255, 255, 255));
      decoded = img.compositeImage(bg, decoded);
    }

    // ★ الأبعاد النهائية للملف المرفوع — تُعرض للأدمن مع الحجم.
    final w = decoded.width;
    final h = decoded.height;
    try {
      return (
        bytes: img.WebPEncoder(
          // `lossless` افتراضياً true في هذه الحزمة: بدون `false` صريح
          // لنضغط الصورة إطلاقاً (تخرج كما دخلت بالحجم نفسه تقريباً).
          lossless: false,
          quality: LocalImageStore.webpQualityFor(quality),
          // `method` = جهد ضاغط WebP (٠ أسرع … ٦ أبطأ). مقيس على ٥١ صورة
          // من صور الأدمن: ٤ ← ٦ توفّر ٥٪ إضافية من الحجم لكنها ترفع زمن
          // الترميز ٣٧٥ ← ٥٠٥ ملّي ثانية **لكل صورة على هاتف الأدمن**،
          // فبقي ٤: الفرق المرئي معدوم والانتظار ملموس.
          method: 4,
        ).encode(decoded),
        width: w,
        height: h,
      );
    } catch (_) {
      return (
        bytes: img.encodeJpg(decoded, quality: quality),
        width: w,
        height: h,
      );
    }
  } catch (_) {
    return (bytes: bytes, width: 0, height: 0);
  }
}