// توليد صوت دخول التطبيق (شاشة البداية) وحفظه WAV في assets/sounds/.
//
// نغمة واحدة هادئة مدتها ثانيتان: موجة دافئة بطيئة الصعود
// (قاعدة عميقة + دو + صول + دو عالي تتراكم بتراكب ناعم) ولمسة
// ختامية رقيقة جداً، بهجوم طويل (صعود تدريجي) فيبدو «دخول» ناعماً
// مريحاً للأذن لا جرساً. (النسخة السابقة كانت صعوداً سريعاً حاداً.)
//
// التشغيل (مرة واحدة بعد أي تعديل):
//   dart run tools/make_entry_sound.dart

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// 16 كيلوهرتز كافٍ تماماً لهذه النغمة (أعلى تردداتها ~4 كيلوهرتز)
// ويوفّر نصف الحجم مقابل 44.1 كيلوهرتز.
const int sampleRate = 16000;

/// المدة الكاملة لصوت الدخول بالثواني — تساوي مدة شاشة البداية.
const double totalSeconds = 2.0;

class Tone {
  const Tone(
    this.freq, {
    required this.start,
    required this.dur,
    this.gain = 1.0,
    this.attack = 0.025,
    this.release = 0.55,
  });

  /// تردد النغمة بالهرتز.
  final double freq;

  /// بداية النغمة بالثواني داخل المقطع.
  final double start;

  /// مدة النغمة بالثواني (كلما طالت، طال ذيلها الناعم).
  final double dur;

  final double gain;

  /// زمن صعود الصوت (يمنع الطقطقة ويجعل الدخول ناعماً).
  final double attack;

  /// زمن التلاشي الختامي (طويل هنا: دفء وفخامة).
  final double release;
}

const double _pi = 3.141592653589793;

/// غلاف ناعم: هجوم خطي قصير ثم تلاشٍ منحني (x²) أهدأ من الخط المستقيم.
double _env(double t, double dur, double attack, double release) {
  if (t < 0 || t > dur) return 0;
  if (t < attack) return t / attack;
  final tail = dur - t;
  if (tail < release) {
    if (release <= 0) return 0;
    final x = tail / release;
    return x * x;
  }
  return 1;
}

/// عيّنة واحدة: نغمة أساسية + توافقيات لطيفة + تموّج بطيء خفيف للدفء.
double _voice(
  double t,
  double freq,
  double dur,
  double gain,
  double attack,
  double release,
) {
  if (t < 0 || t > dur) return 0;
  final env = _env(t, dur, attack, release);
  // تموّج رقيق جداً (±0.25%) يعطي إحساس الآلة الوترية بدل النغمة الجافة.
  final f = freq * (1 + 0.0025 * sin(_pi * 2 * 5.2 * t));
  final s = sin(_pi * 2 * f * t) +
      0.30 * sin(_pi * 2 * f * 2 * t) +
      0.10 * sin(_pi * 2 * f * 3 * t);
  return s * env * gain;
}

Uint8List buildWav(List<Tone> tones, double total) {
  final frames = (sampleRate * total).round();
  final samples = List<double>.filled(frames, 0);

  for (final tone in tones) {
    final from = (tone.start * sampleRate).round();
    final len = (tone.dur * sampleRate).round();
    for (var i = 0; i < len; i++) {
      final idx = from + i;
      if (idx < 0 || idx >= frames) continue;
      samples[idx] += _voice(
        i / sampleRate,
        tone.freq,
        tone.dur,
        tone.gain,
        tone.attack,
        tone.release,
      );
    }
  }

  // قصّ الذروة على 0.92 حتى لا يحدث تشويه عند التشغيل.
  var peak = 0.0;
  for (final s in samples) {
    final a = s.abs();
    if (a > peak) peak = a;
  }
  final gain = peak > 0 ? 0.92 / peak : 1.0;

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
double n(double semitoneFromA4) => 440.0 * pow(2, (semitoneFromA4 - 9) / 12);

void main() {
  final assetDir = Directory('assets/sounds');
  assetDir.createSync(recursive: true);

  // الموجة الهادئة: قاعدة عميقة ثم نغمات تتراكم بصعود بطيء (هجوم طويل)
  // كأنها موجة ضوء تعلو، وتنتهي بلمسة رقيقة عالية جداً قبل الصمت.
  final tones = <Tone>[
    Tone(n(-12), start: 0.00, dur: 2.00, gain: 0.34, attack: 0.18, release: 1.00),
    Tone(n(0), start: 0.00, dur: 1.95, gain: 0.46, attack: 0.32, release: 1.15),
    Tone(n(7), start: 0.22, dur: 1.70, gain: 0.34, attack: 0.38, release: 1.00),
    Tone(n(12), start: 0.48, dur: 1.42, gain: 0.24, attack: 0.42, release: 0.90),
    Tone(n(24), start: 1.42, dur: 0.52, gain: 0.13, attack: 0.02, release: 0.46),
    Tone(n(31), start: 1.60, dur: 0.38, gain: 0.09, attack: 0.02, release: 0.34),
  ];

  final bytes = buildWav(tones, totalSeconds);
  final kb = (bytes.length / 1024).toStringAsFixed(1);
  File('${assetDir.path}/entry.wav').writeAsBytesSync(bytes);
  stdout.writeln('🎬 entry.wav ($kb كيلوبايت، $totalSeconds ثانية) → assets/sounds');
}
