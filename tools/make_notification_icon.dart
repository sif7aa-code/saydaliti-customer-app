// أداة توليد أيقونة الإشعارات (Notification small icon).
//
// لماذا؟ أندرويد لا يعرض أيقونة التطبيق الملونة في شريط الحالة، بل
// أيقونة بيضاء صغيرة (silhouette) على خلفية شفافة. لو تركنا أيقونة
// اللانش(Color) فإنها تظهر مربّعة بيضاء أو فارغة.
//
// التشغيل:  dart run tools/make_notification_icon.dart
import 'dart:io';

import 'package:image/image.dart' as img;

/// مقاسات Notification small icon القياسية لأندرويد.
const Map<String, int> _sizes = {
  'drawable-mdpi': 24,
  'drawable-hdpi': 36,
  'drawable-xhdpi': 48,
  'drawable-xxhdpi': 72,
  'drawable-xxxhdpi': 96,
};

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final source = File(
    args.isNotEmpty ? args[0] : '$root/assets/images/app_icon.png',
  );
  if (!source.existsSync()) {
    stderr.writeln('الصورة غير موجودة: ${source.path}');
    exit(1);
  }

  final original = img.decodePng(source.readAsBytesSync());
  if (original == null) {
    stderr.writeln('تعذر قراءة الصورة (ليست PNG صالحة).');
    exit(1);
  }

  // نأخذ أكبر نسخة من الأيقونة (المربعة الأدق) ثم نصغّرها لكل مقاس.
  final square = img.copyResize(
    original,
    width: 512,
    height: 512,
    interpolation: img.Interpolation.average,
  );

  for (final entry in _sizes.entries) {
    final dir = Directory('$root/android/app/src/main/res/${entry.key}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final target = File('${dir.path}/ic_stat_notification.png');

    final sized = img.copyResize(
      square,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.average,
    );

    // أبيض بالكامل حيث البكسل مرئي، شفاف تماماً في الخلفية.
    final out = img.Image(width: entry.value, height: entry.value, numChannels: 4);
    for (var y = 0; y < sized.height; y++) {
      for (var x = 0; x < sized.width; x++) {
        final p = sized.getPixel(x, y);
        final alpha = p.a / 255.0;
        // الخلفية الفاتحة/البيضاء تماماً تصبح شفافة.
        final isBackground = p.r > 242 && p.g > 242 && p.b > 242;
        final a = isBackground ? 0 : (alpha * 255).round().clamp(0, 255);
        out.setPixelRgba(
          x,
          y,
          255,
          255,
          255,
          a,
        );
      }
    }

    target.writeAsBytesSync(img.encodePng(out, level: 9));
    stdout.writeln('✔ ${target.path}  (${entry.value}x${entry.value})');
  }

  stdout.writeln('تم إنشاء أيقونة الإشعارات البيضاء لكل الكثافات.');
}
