import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/local_image_store.dart';

/// اختبارات تحسين التخزين (طلب ٢٠٢٦-١١-٠١ ثم تشديده في ٢٠٢٦-١١-٠٢):
/// جودة WebP للصور **الجديدة** ضمن نطاق ٧٥–٨٠ قبل الرفع، بلا رفعٍ صامت
/// للسقف. الصور القديمة لا تُمسّ — هذه الدالة تعمل لحظة الرفع فقط.
void main() {
  group('LocalImageStore.webpQualityFor — نطاق ٧٥–٨٠ بلا رفعٍ للسقف', () {
    test('جودة المتاجر (٧٥) تبقى ٧٥ لا ٨٠', () {
      expect(LocalImageStore.webpQualityFor(ImageProfile.shop.quality), 75);
    });

    test('جودة الحساب (٧٨) تبقى ٧٨ لا ٨٦', () {
      expect(LocalImageStore.webpQualityFor(ImageProfile.avatar.quality), 78);
    });

    test('الجودة الافتراضية للرفع (٧٥) ضمن النطاق', () {
      final q = LocalImageStore.webpQualityFor(75);
      expect(q, greaterThanOrEqualTo(75));
      expect(q, lessThanOrEqualTo(80));
    });

    test('أرضية ٧٥: جودة منخفضة مُمرّرة لا تُنتج صورة متعبة', () {
      expect(LocalImageStore.webpQualityFor(10), 75);
      expect(LocalImageStore.webpQualityFor(0), 75);
    });

    test('سقف ٨٠: أي جودة عالية تبقى داخل النطاق', () {
      expect(LocalImageStore.webpQualityFor(100), 80);
      expect(LocalImageStore.webpQualityFor(95), 80);
    });

    test('★ ما داخل النطاق يمر كما هو — لا «+٦» يرفع كل صورة إلى السقف', () {
      // كان المسار القديم `(quality + 6).clamp(75, 80)` يجعل ٧٦ ⇒ ٨٠ و٧٠ ⇒ ٧٦
      // و٧٨ ⇒ ٨٠، أي أن الاختيار الحقيقي يضيع وتخرج كل صورة على السقف.
      expect(LocalImageStore.webpQualityFor(70), 75);
      expect(LocalImageStore.webpQualityFor(76), 76);
      expect(LocalImageStore.webpQualityFor(78), 78);
      expect(LocalImageStore.webpQualityFor(80), 80);
    });
  });

  group('صور جديدة أصغر — العرض يبقى كما هو', () {
    test('المتجر ٧٠٠ بكسل والشعار على أرضية النطاق', () {
      expect(ImageProfile.shop.maxWidth, 700);
      expect(ImageProfile.shop.quality, 75);
    });

    test('الحساب ٤٠٠ بكسل لا يُضغط تحت الأرضية', () {
      expect(ImageProfile.avatar.maxWidth, 400);
      expect(ImageProfile.avatar.quality, 78);
    });
  });
}
