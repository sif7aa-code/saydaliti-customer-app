// توليد رنّة «تم التحديث» (صوت الريفرش) وحفظها في assets/sounds/refresh.wav
//
// التشغيل:
//   dart run tools/make_refresh_sound.dart
//
// ★ لماذا ملف مستقل عن `make_notification_sounds.dart`؟
//   ذلك المولّد يكتب أيضاً في `android/.../res/raw/` لأن كل نغمة فيه
//   مرتبطة بقناة إشعار أندرويد (تعمل والتطبيق مغلق). رنّة الريفرش
//   **ردّ فعل داخل الواجهة** لا إشعار: لا قناة لها ولا حاجة لنسخة raw،
//   فإدخالها هناك يضيف ملفاً لا يقرأه أحد في كل APK.
//
// ★ الشكل المطلوب: مثل رنّة تحديث فيسبوك — ثلاث نبرات صاعدة سريعة
//   وانتهاءٌ واحد طويل نسبياً، أي «تم، ورجعتك للمكان الذي كنت فيه».
//   قصيرة جداً (~0.4ث) حتى لا تتكّر على بعض السحبات المتتابعة.
//
//   نفس هندسة المولّد الأصلي: موجات جيبية + توافقيات + غلاف ADSR على
//   16 كيلوهرتز / 16 بت / أحادي القناة، بلا أي ملف صوت خارجي.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const int sampleRate = 16000;

class Tone {
  const Tone(
    this.freq, {
    this.start = 0.0,
    this.dur = 0.18,
    this.gain = 1.0,
    this.attack = 0.005,
    this.release = 0.08,
  });

  final double freq;
  final double start;
  final double dur;
  final double gain;
  final double attack;
  final double release;
}

const double _pi = 3.141592653589793;

double _adsr(double t, double dur, double attack, double release) {
  if (t < 0 || t > dur) return 0;
  if (t < attack) return t / attack;
  final tail = dur - t;
  if (tail < release) return release <= 0 ? 0 : tail / release;
  return 1;
}

/// نغمة واحدة: أساسي + توافقيه الثاني والثالث (إحساس جرس، لا صفارة جافة).
double _voice(double t, double freq, double dur, double level) {
  if (t < 0 || t > dur) return 0;
  final env = _adsr(t, dur, 0.005, 0.08);
  final s = sin(_pi * 2 * freq * t) +
      0.30 * sin(_pi * 2 * freq * 2 * t) +
      0.10 * sin(_pi * 2 * freq * 3 * t);
  return s * env * level;
}

Uint8List buildWav(List<Tone> tones, double totalSeconds) {
  final frames = (sampleRate * totalSeconds).round();
  final samples = List<double>.filled(frames, 0);

  for (final tone in tones) {
    final from = (tone.start * sampleRate).round();
    final len = (tone.dur * sampleRate).round();
    for (var i = 0; i < len; i++) {
      final idx = from + i;
      if (idx < 0 || idx >= frames) continue;
      samples[idx] += _voice(i / sampleRate, tone.freq, tone.dur, tone.gain);
    }
  }

  var peak = 0.0;
  for (final s in samples) {
    final a = s.abs();
    if (a > peak) peak = a;
  }
  final gain = peak > 0 ? 0.90 / peak : 1.0;

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

/// A4 = 440Hz ⇒ التردد = 440 * 2^((ن-9)/12)
double n(double semitonesFromA4) =>
    440.0 * pow(2, (semitonesFromA4 - 9) / 12);

void main() {
  final dir = Directory('assets/sounds');
  dir.createSync(recursive: true);

  // ★ ثلاث نبرات صاعدة (G5 → E6 → A6) ثم ذيل واحد على A6:
  //   «تم» — وهو الأقرب لرنّة تحديث فيسبوك: قصير، مضيء، وصاعد.
  final tones = <Tone>[
    Tone(n(4), start: 0.00, dur: 0.09, gain: 0.60), // G5  ≈ 784
    Tone(n(16), start: 0.07, dur: 0.10, gain: 0.72), // E6 ≈ 1319
    Tone(n(21), start: 0.14, dur: 0.24, gain: 0.86), // A6 ≈ 1760
    Tone(n(28), start: 0.14, dur: 0.24, gain: 0.26), // لمعة فوقية
  ];

  final bytes = buildWav(tones, 0.42);
  final file = File('${dir.path}/refresh.wav')..writeAsBytesSync(bytes);
  stdout.writeln(
    '✓ ${file.path} — ${(bytes.length / 1024).toStringAsFixed(1)} KB '
    '(0.42ث @ ${sampleRate}Hz/16bit/mono)',
  );
}
