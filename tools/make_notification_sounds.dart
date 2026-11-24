// توليد نغمات إشعارات التطبيق وحفظها WAV في assets/sounds/ و
// android/app/src/main/res/raw/ (نفس الملف لقنوات Android).
//
// كل نغمة مركّبة من نغمات جيبية (sine) مع غلاف ADSR، فلا تحتاج أي
// مكتبة صوت خارجية ولا ملفات-source جاهزة.
//
// التشغيل (مرة واحدة بعد كل تعديل على النغمات):
//   dart run tools/make_notification_sounds.dart

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// 16 كيلوهرتز: أعلى من الكفاية لنغمة تنبيه، ويوفّر ~27% من حجم الملف
// مقابل 22.05 كيلوهرتز (بلا فرق مسموع على جرس تنبيه قصير).
const int sampleRate = 16000;

class Tone {
  const Tone(
    this.freq, {
    this.start = 0.0,
    this.dur = 0.18,
    this.gain = 1.0,
    this.attack = 0.006,
    this.release = 0.09,
  });

  /// تردد النغمة بالهرتز.
  final double freq;

  /// بداية النغمة بالثواني داخل المقطع.
  final double start;

  /// مدة النغمة بالثواني.
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

/// يبني عيّنة واحدة من مولّد الموجات (نغمة أساسية + توافقيات + ضجيج خفيف).
double _voice(double t, double freq, double dur, double level) {
  if (t < 0 || t > dur) return 0;
  final env = _adsr(t, dur, 0.006, 0.09);
  // توافقيات تعطي إحساس الجرس بدل النغمة الجافة.
  final s = sin(_pi * 2 * freq * t) +
      0.32 * sin(_pi * 2 * freq * 2 * t) +
      0.12 * sin(_pi * 2 * freq * 3 * t);
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

/// A4 = 440Hz ⇒ التردد = 440 * 2^((ن-69)/12)
double n(double semitoneFromA4) =>
    440.0 * pow(2, (semitoneFromA4 - 9) / 12);

void main() {
  final assetDir = Directory('assets/sounds');
  // نفس الملفات داخل موارد Android: قناة كل نغمة تحتاج res/raw/<name>.wav
  // ليعمل الصوت حتى والتطبيق مغلق.
  final rawDir = Directory('android/app/src/main/res/raw');
  assetDir.createSync(recursive: true);
  rawDir.createSync(recursive: true);

  final files = <String, List<Tone>>{
    // طلب جديد (للمندوبين): رنّة صاعدة عاجزة، نغمتان متتاليتان.
    'new_order': [
      Tone(n(4), start: 0.00, dur: 0.16, gain: 0.85),
      Tone(n(11), start: 0.13, dur: 0.30, gain: 0.95),
      Tone(n(16), start: 0.13, dur: 0.30, gain: 0.35),
    ],
    // قبول الطلب (للزبون): ثلاثية صاعدة مبتهجة.
    'accepted': [
      Tone(n(0), start: 0.00, dur: 0.16, gain: 0.75),
      Tone(n(4), start: 0.11, dur: 0.16, gain: 0.80),
      Tone(n(7), start: 0.22, dur: 0.34, gain: 0.95),
    ],
    // بدء التوصيل (للزبون): ثلاثية متوسطة صاعدة (مختلفة عن القبول).
    'delivering': [
      Tone(n(5), start: 0.00, dur: 0.14, gain: 0.72),
      Tone(n(9), start: 0.11, dur: 0.14, gain: 0.78),
      Tone(n(12), start: 0.22, dur: 0.32, gain: 0.88),
    ],
    // رفض الطلب (للزبون): هبوط ثقيل بنغمتين منخفضتين.
    'rejected': [
      Tone(n(-4), start: 0.00, dur: 0.26, gain: 0.90),
      Tone(n(-9), start: 0.22, dur: 0.42, gain: 0.95),
      Tone(n(-9), start: 0.22, dur: 0.42, gain: 0.25),
    ],
    // استبدال/تعديل منتج: نقرتان سريعتان نغميتان.
    'replaced': [
      Tone(n(12), start: 0.00, dur: 0.11, gain: 0.85),
      Tone(n(12), start: 0.16, dur: 0.11, gain: 0.85),
      Tone(n(19), start: 0.16, dur: 0.22, gain: 0.45),
    ],
    // تغيّر السعر: هبوط نغمي ثلاثي.
    // ★ مختلف عن `rejected` (ثنائي ثقيل منخفض) وعن `replaced`
    //   (نقرتان سريعتان عاليتان): هنا ثلاث نبر متوسطة هابطة،
    //   فيفهم الزبون «شيء تغيّر» بلا أن يظنّه رفضاً أو استبدالاً.
    'price_changed': [
      Tone(n(7), start: 0.00, dur: 0.12, gain: 0.72),
      Tone(n(2), start: 0.11, dur: 0.12, gain: 0.82),
      Tone(n(-3), start: 0.22, dur: 0.30, gain: 0.90),
    ],
    // توصيل الطلب: ثلاثية صاعدة عالية + ذيل مبهج.
    'delivered': [
      Tone(n(7), start: 0.00, dur: 0.16, gain: 0.70),
      Tone(n(12), start: 0.10, dur: 0.16, gain: 0.78),
      Tone(n(16), start: 0.20, dur: 0.16, gain: 0.84),
      Tone(n(19), start: 0.30, dur: 0.40, gain: 0.95),
    ],
    // تنبيه عام: رنّة واحدة قصيرة محايدة.
    'alert': [
      Tone(n(12), start: 0.00, dur: 0.26, gain: 0.90),
      Tone(n(19), start: 0.00, dur: 0.26, gain: 0.30),
    ],
  };

  const lengths = <String, double>{
    'new_order': 0.60,
    'accepted': 0.62,
    'delivering': 0.66,
    'rejected': 0.70,
    'replaced': 0.45,
    'price_changed': 0.58,
    'delivered': 0.78,
    'alert': 0.34,
  };

  files.forEach((name, tones) {
    final bytes = buildWav(tones, lengths[name] ?? 1.0);
    final kb = (bytes.length / 1024).toStringAsFixed(1);
    File('${assetDir.path}/$name.wav').writeAsBytesSync(bytes);
    File('${rawDir.path}/$name.wav').writeAsBytesSync(bytes);
    stdout.writeln('🔔 $name.wav  ($kb كيلوبايت) → assets/sounds + res/raw');
  });

  stdout.writeln('تم توليد ${files.length} نغمة عند $sampleRate هرتز.');
}
