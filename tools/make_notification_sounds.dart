// يولّد نغمة الإشعارات الوحيدة: جرس واحد لكل الحالات، ويحفظه WAV
// في assets/sounds/ و android/app/src/main/res/raw/ بنفس الأسماء
// الثمانية، فتبقى قنوات Android القائمة (strasopa_v2_*) كما هي
// وتتغيّر نغماً فقط، بلا حاجة لإعادة إنشاء القنوات.
//
// التشغيل بعد أي تعديل على الجرس:
//   dart run tools/make_notification_sounds.dart

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// 16 كيلوهرتز: يكفي لجزئيات الجرس حتى ~7.5 كيلوهرتز، ويوفّر الحجم.
const int sampleRate = 16000;

const double _pi = 3.141592653589793;
const double _duration = 1.15;

/// أسماء الملفات الثمانية (قنوات v2 والاستخدام داخل التطبيق).
const List<String> _names = [
  'new_order',
  'accepted',
  'delivering',
  'rejected',
  'replaced',
  'price_changed',
  'delivered',
  'alert',
];

/// جرس واحد: نغمة أساسية + جزئيات غير توافقية تتلاشى بسرعات مختلفة
/// (هذا ما يميّز الجرس عن النغمة الموسيقية الجافة).
Uint8List buildBell() {
  final frames = (sampleRate * _duration).round();
  final samples = List<double>.filled(frames, 0);

  const double f0 = 1046.5; // C6
  // [نسبة التردد، الشدة، سرعة التلاشي]
  const partials = <List<double>>[
    [1.00, 1.00, 3.1],
    [2.00, 0.42, 4.2],
    [2.76, 0.26, 5.2],
    [4.07, 0.14, 6.2],
    [5.43, 0.07, 7.0],
  ];

  for (var i = 0; i < frames; i++) {
    final t = i / sampleRate;
    final attack = min(1.0, t / 0.004);
    final tail = min(1.0, (_duration - t) / 0.03);
    var v = 0.0;
    for (final p in partials) {
      v += p[1] * exp(-p[2] * t) * sin(_pi * 2 * f0 * p[0] * t);
    }
    samples[i] = v * attack * max(0.0, tail);
  }

  // قصّ الذروة على 0.9 حتى لا يحدث تشويه عند التشغيل.
  var peak = 0.0;
  for (final s in samples) {
    final a = s.abs();
    if (a > peak) peak = a;
  }
  final gain = peak > 0 ? 0.9 / peak : 1.0;

  final dataSize = frames * 2;
  final out = BytesBuilder();
  void u32(int v) => out.add(
        (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
      );
  void u16(int v) => out.add(
        (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
      );

  out.add('RIFF'.codeUnits);
  u32(36 + dataSize);
  out.add('WAVE'.codeUnits);
  out.add('fmt '.codeUnits);
  u32(16);
  u16(1); // PCM
  u16(1); // أحادي القناة
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  out.add('data'.codeUnits);
  u32(dataSize);

  for (final s in samples) {
    final v = max(-1.0, min(1.0, s * gain));
    out.add(
      (ByteData(2)..setInt16(0, (v * 32767).round(), Endian.little))
          .buffer
          .asUint8List(),
    );
  }
  return out.toBytes();
}

void main() {
  final assetDir = Directory('assets/sounds');
  // نفس الملفات داخل موارد Android: قناة الإشعار تقرأ res/raw/<name>.wav
  // ليعمل الصوت حتى والتطبيق مغلق.
  final rawDir = Directory('android/app/src/main/res/raw');
  assetDir.createSync(recursive: true);
  rawDir.createSync(recursive: true);

  final bytes = buildBell();
  final kb = (bytes.length / 1024).toStringAsFixed(1);
  for (final name in _names) {
    File('${assetDir.path}/$name.wav').writeAsBytesSync(bytes);
    File('${rawDir.path}/$name.wav').writeAsBytesSync(bytes);
    stdout.writeln('🔔 $name.wav  ($kb كيلوبايت) → assets/sounds + res/raw');
  }

  stdout.writeln('تم توليد جرس واحد لـ ${_names.length} ملفاً عند $sampleRate هرتز.');
}
