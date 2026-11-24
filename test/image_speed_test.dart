import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/widgets/app_image.dart';

/// اختبارات «تحميل الصور فائق السرعة» (طلب ٢٠٢٦-١٠-٢٨).
///
/// التوفير الحقيقي مقيس على السيرفر: صورة منتج حيّة
///   · الأصل                 = 56,238 بايت
///   · `render/image` بعرض ٢٠٠ = 14,540 بايت (−٧٤٪)
///   · `render/image` بعرض ٤٠٠ = 35,802 بايت (−٣٦٪)
///   · `render/image` بعرض ٨٠٠ = 52,480 بايت (لا ربح، وأبطأ)
///   · `render/image` **بلا** `format=` = 72,788 بايت (JPEG أضخم من الأصل!)
///
/// فتُطلَّ هذه الاختبارات العقد الذي يحمي تلك الأرقام: التحويل للدلاء
/// الصغيرة فقط، وبصيغة webp دائماً، وبالباقي على الرابط الأصلي.
void main() {
  const base = 'https://piepmqbqdxhnsbynjgmg.supabase.co';
  const original = '$base/storage/v1/object/public/products/x.jpg';

  // ★ مدير الصور يُبنى مرة واحدة لكل عملية (`static final`)، وقراءة القرص
  //   تحتاج `path_provider`. بلا هذا البدل يرمي الاختبار
  //   MissingPluginException فور لمس أول مزوّد صور.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('shtr_img_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
  });

  group('رابط الصورة المُستخدَم فعلياً', () {
    test('دلو ٣٦٠ و٥٧٦ ← مسار التحويل على الخادم بعرض الدلو نفسه', () {
      for (final bucket in [360, 576]) {
        final out = AppImage.sizedUrl(original, bucket);
        expect(out, contains('/storage/v1/render/image/public/products/'));
        expect(
          out,
          endsWith(
            '?width=$bucket&height=${bucket * 2}&resize=contain'
            '&quality=80&format=webp',
          ),
        );
        // الصيغة إلزامية: بلاها يرجع endpoint العرض JPEGاً أضخم من الأصل.
        expect(out, contains('format=webp'));
      }
    });

    test('الصورة تبقى كاملة: contain وارتفاع صريح دائماً', () {
      // ★ فخّ مقيس: `width` وحده يقتطع من العرض (٧٠٠×٧٠٠ ← ٣٦٠×٧٠٠)،
      //   وهو سبب «الصور لم تظهر كاملة». هذا الاختبار يمنع عودته.
      for (final bucket in [200, 360, 576]) {
        final out = AppImage.sizedUrl(original, bucket);
        expect(out, contains('resize=contain'), reason: '$bucket');
        expect(out, contains('height=${bucket * 2}'), reason: '$bucket');
        expect(out, isNot(contains('resize=cover')));
      }
    });

    test('دلو ٨٠٠ ← يبقى على الرابط الأصلي بلا تحويل', () {
      // صورة المنتج الكبيرة: التحويل لا يوفّر شيئاً عندها، فنبقيها على
      // مسار واحد لا يعتمد على خدمة التحويل إطلاقاً.
      expect(AppImage.sizedUrl(original, 800), original);
    });

    test('القرار بالدلو لا بالسجل: نفس الرابط يبقى أصلياً في ٨٠٠ بعد ٣٦٠', () {
      // الكاش لا يسبق فحص الدلو، وإلا تسلّم بطاقة ٨٠٠ نسخة ٣٦٠ الضبابية.
      AppImage.sizedUrl(original, 360);
      expect(AppImage.sizedUrl(original, 800), original);
    });

    test('الكاش لا يسرّب مقاساً إلى مقاس آخر', () {
      // بمفتاح الرابط وحده كانت نسخة ٣٦٠ تُسلَّم لمكان يحتاج ٥٧٦.
      AppImage.sizedUrl(original, 360);
      expect(
        AppImage.sizedUrl(original, 576),
        endsWith(
          '?width=576&height=1152&resize=contain&quality=80&format=webp',
        ),
      );
      expect(
        AppImage.sizedUrl(original, 360),
        endsWith('?width=360&height=720&resize=contain&quality=80&format=webp'),
      );
    });

    test('نفس الرابط يعطي نفس النصّ مرّتين (الكاش لا يبدّل النتيجة)', () {
      expect(AppImage.sizedUrl(original, 360), AppImage.sizedUrl(original, 360));
    });

    test('روابط ليست تخزين Supabase تمرّ كما هي', () {
      for (final url in [
        'https://example.com/a.jpg',
        'assets/logo.png',
        'data:image/png;base64,AAAA',
      ]) {
        expect(AppImage.sizedUrl(url, 360), url, reason: url);
      }
    });

    test('المسار الناقص يكتمل إلى رابط عام ثم يتحوّل', () {
      final full = AppImage.resolve('images/products/x.jpg');
      expect(full, '$base/storage/v1/object/public/images/products/x.jpg');
      expect(AppImage.sizedUrl(full, 360), contains('/render/image/public/'));
      expect(AppImage.isSupabasePublic(full), isTrue);
      expect(AppImage.isSupabasePublic('https://example.com/a.jpg'), isFalse);
    });

    test('رابط كامل أو data: لا يُعاد لفّهما', () {
      expect(AppImage.resolve(original), original);
      expect(AppImage.resolve('data:image/png;base64,AAAA'),
          'data:image/png;base64,AAAA');
      expect(AppImage.resolve(null), '');
      expect(AppImage.resolve('   '), '');
    });
  });

  // ★ عقد «صور المنتجات تُرسم في أول إطار» (طلب ٢٠٢٦-١١-٠٢).
  //
  //   الفورية كلها متوقّفة على تطابق المفتاح: التسخين يحشو كاش الذاكرة
  //   بمزوّد، والبطاقة تقرأ بمزوّد. `CachedNetworkImageProvider` يقارن
  //   نفسه بـ`(cacheKey ?? url, scale, maxHeight, maxWidth)`، فأي فرق في
  //   رقم واحد يجعل المحشوَّ غريباً وترجع البطاقة تنتظر القرص والشبكة.
  group('مفتاح الصورة: التسخين والبطاقة والمحرّر سواءٌ بسواء', () {
    test('دلو البطاقة ٥٧٦ وسقف ارتفاعه ٧٢٠ (cacheWidth ٣٦٠ × ١٫٨ × ١٫٢٥)', () {
      expect(AppImage.cardBucket, 576);
      expect(AppImage.maxHeightFor(576), 720);
      expect(AppImage.maxHeightFor(360), 450);
    });

    test('المزوّدان المبنيان منفصلين لمصدر واحد متطابقان ⇒ الكاش يصيب', () {
      final a = AppImage.providerFor(
        original,
        AppImage.cardBucket,
        maxHeight: AppImage.maxHeightFor(AppImage.cardBucket),
      );
      final b = AppImage.providerFor(
        original,
        AppImage.cardBucket,
        maxHeight: AppImage.maxHeightFor(AppImage.cardBucket),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('لا تُسرَّب درجة إلى درجة: ٣٦٠ ≠ ٥٧٦ ≠ ٨٠٠', () {
      final p360 = AppImage.providerFor(original, 360);
      final p576 = AppImage.providerFor(original, 576);
      final p800 = AppImage.providerFor(original, 800);
      expect(p360 == p576, isFalse);
      expect(p576 == p800, isFalse);
    });

    test('مفتاح القرص = الرابط المُستعمَل + الدلو، و٨٠ِ على الأصل بلا تحويل',
        () {
      expect(
        AppImage.diskKey(original, 360),
        '${AppImage.sizedUrl(original, 360)}@360',
      );
      // دلو ٨٠٠ يبقى على الرابط الأصلي (لا ربح في التحويل عنده) — ومفتاحه
      // معه، وإلا بحث المحرّر في مفتاح غير الذي حفظته البطاقة.
      expect(AppImage.diskKey(original, 800), '$original@800');
    });

    test('مسار ناقص يُستكمل ثم له مفتاح واحد مهما تكرّر', () {
      final path = 'products/x.jpg';
      final full = AppImage.resolve(path);
      expect(AppImage.diskKey(full, 576), AppImage.diskKey(full, 576));
      expect(AppImage.diskKey(full, 576), isNot(AppImage.diskKey(full, 360)));
    });

    test('المصدر غير التخزيني ليس له مفتاح تحويل (ولا يُسخَّن ولا يُحرَّر)', () {
      const foreign = 'https://example.com/a.jpg';
      expect(AppImage.isSupabasePublic(foreign), isFalse);
      // `sizedUrl` يمرّره كما هو، فمفتاحه يبقى مبنياً على رابطه لا على
      // مسار render — وبوابة `warmFromDisk`/`forget` تتجاوزه أصلاً.
      expect(AppImage.diskKey(foreign, 576), '$foreign@576');
    });
  });
}
