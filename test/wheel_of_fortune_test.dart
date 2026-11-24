import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/wheel_service.dart';
import 'package:saydaliti/widgets/wheel_of_fortune.dart';

/// ★ عجلة الحظ: الطبقة في الهاتف **تعرض**، والخادم يقرّر.
///
/// هذه الاختبارات تحرس الخطّ الذي لا يجوز أن ينكسر: أن يظهر زرّ اللفّ
/// لأن الهاتف ظنّ أن الدور جاء، أو أن تُنسب جائزة لم يقلها الخادم.
/// كل حالة هنا مختارة من ثغرة حقيقية: غياب الحقل، اتصال منقطع، ردّ
/// بلا قطعة معروفة، ضغطتان في ثانية واحدة.
const _prizes = [
  {'id': 1, 'kind': 'none', 'amount': null, 'label': 'حظ أوفر', 'weight': 60},
  {'id': 2, 'kind': 'amount', 'amount': 250, 'label': 'خصم ٢٥٠', 'weight': 20},
  {'id': 3, 'kind': 'amount', 'amount': 500, 'label': 'خصم ٥٠٠', 'weight': 10},
  {'id': 4, 'kind': 'amount', 'amount': 750, 'label': 'خصم ٧٥٠', 'weight': 6},
  {'id': 5, 'kind': 'amount', 'amount': 1000, 'label': 'خصم ١٠٠٠', 'weight': 4},
];

WheelStatus status([Map<String, dynamic> extra = const {}]) =>
    WheelStatus.fromJson(<String, dynamic>{
      'ok': true,
      'known': true,
      'logged_in': true,
      'enabled': true,
      'ready': true,
      'seconds_left': 0,
      'spins': 0,
      'cooldown_hours': 24,
      'message': '',
      'prizes': _prizes,
      ...extra,
    });

/// الزاوية modulo الدورة، ثم مُقاربة من الصفر في أي اتجاه.
double _offCircle(double a) {
  final t = a % (math.pi * 2);
  final signed = t > math.pi ? t - math.pi * 2 : (t < -math.pi ? t + math.pi * 2 : t);
  return signed.abs();
}

void main() {
  group('زرّ اللفّ لا يُضاء إلا بقول الخادم', () {
    test('قال جاهزًا مع قطع ⇒ جاهز', () {
      expect(status().ready, isTrue);
    });

    test('قال مقفولًا ⇒ مقفول ولو عدّاد الهاتف صفر', () {
      expect(status({'ready': false, 'seconds_left': 0}).ready, isFalse);
    });

    test('الأدمن أوقف العجلة ⇒ لا تلفّ لأحد', () {
      final s = status({'enabled': false, 'ready': false});
      expect(s.ready, isFalse);
      expect(s.stopped, isTrue);
    });

    test('بلا قطع ⇒ لا عجلة (ولا زرّ يلفّ في فراغ)', () {
      expect(status({'prizes': const []}).ready, isFalse);
    });

    test('الحقل مفقود من قاعدة قديمة ⇒ مقفول، لا «لعله شغّال»', () {
      final s = WheelStatus.fromJson(const {
        'ok': true,
        'logged_in': true,
        'ready': true,
        'prizes': _prizes,
      });
      expect(s.serverEnabled, isFalse);
      expect(s.ready, isFalse);
    });

    test('لم يسجّل الدخول ⇒ يُقال له، ولا تلفّ', () {
      final s = status({'logged_in': false, 'ready': false});
      expect(s.needsLogin, isTrue);
      expect(s.ready, isFalse);
    });

    test('تعذّر القراءة ⇒ حالة مجهولة لا جائزة ولا عدّاد مخترع', () {
      const s = WheelStatus.unavailable();
      expect(s.known, isFalse);
      expect(s.ready, isFalse);
      expect(s.countdown, '');
      expect(s.label, contains('تعذّر'));
    });

    test('مدة اللفّ تُقرأ من الخادم، واحتياطها ٢٤ ساعة', () {
      expect(status({'cooldown_hours': 12}).cooldownHours, 12);
      expect(status().cooldownHours, 24);
      expect(
        WheelStatus.fromJson(const {'enabled': true}).cooldownHours,
        24,
      );
    });

    test('العدّاد يعرض الساعات والدقائق من ثواني الخادم', () {
      expect(status({'seconds_left': 5 * 3600 + 20 * 60}).countdown,
          contains('س'));
      expect(status({'seconds_left': 0}).countdown, 'الآن');
    });
  });

  group('النتيجة لا تُختلق في الهاتف', () {
    test('ربح مبلغ بكود ⇒ فيه كود', () {
      final r = WheelSpinResult.fromJson(const {
        'ok': true,
        'spun': true,
        'prize_id': 3,
        'kind': 'amount',
        'label': 'خصم ٥٠٠',
        'amount': 500,
        'code': 'w1028-ab12',
        'message': 'مبروك',
      });
      expect(r.spun, isTrue);
      expect(r.hasCode, isTrue);
      // ★ الكود يُطبَّع كما في بقية أكواد القاعدة: كبير بلا مسافات.
      expect(r.code, 'W1028-AB12');
    });

    test('«حظ أوفر» ربحٌ بلا كود', () {
      final r = WheelSpinResult.fromJson(const {
        'ok': true,
        'spun': true,
        'prize_id': 1,
        'kind': 'none',
        'label': 'حظ أوفر',
      });
      expect(r.spun, isTrue);
      expect(r.hasCode, isFalse);
      expect(r.code, '');
    });

    test('قال «لم يحن دورك» ⇒ ليست لفّة ولا جائزة', () {
      final r = WheelSpinResult.fromJson(const {
        'ok': false,
        'spun': false,
        'too_soon': true,
        'seconds_left': 3600,
        'error': 'لفّتك القادمة بعد ساعة',
      });
      expect(r.spun, isFalse);
      expect(r.tooSoon, isTrue);
      expect(r.hasCode, isFalse);
    });

    test('`ok: true` بلا `spun` لا تُقرأ ربحًا', () {
      final r = WheelSpinResult.fromJson(const {'ok': true, 'kind': 'amount'});
      expect(r.spun, isFalse);
      expect(r.hasCode, isFalse);
    });

    test('حالة مجهولة ⇒ خطأ صادق لا قطعة', () {
      const r = WheelSpinResult.unknown();
      expect(r.known, isFalse);
      expect(r.spun, isFalse);
      expect(r.prizeId, 0);
      expect(r.error, isNotEmpty);
    });
  });

  group('القطع كما يرسلها الخادم', () {
    test('الأرقام قد تأتي نصًا فتُحلّ كما هي', () {
      final p = WheelPrize.fromJson(const {
        'id': '4',
        'kind': 'amount',
        'amount': '750.00',
        'label': '  خصم ٧٥٠  ',
        'weight': '6',
      });
      expect(p.id, 4);
      expect(p.amount, 750);
      expect(p.weight, 6);
      expect(p.label, 'خصم ٧٥٠');
      expect(p.isWin, isTrue);
    });

    test('«حظ أوفر» ليست ربحًا، والتفعيل افتراضي صحيح', () {
      final p = WheelPrize.fromJson(const {'id': 1, 'kind': 'none'});
      expect(p.isWin, isFalse);
      expect(p.active, isTrue);
    });

    test('موضع القطعة من ترتيب الخادم، والمجهولة لا موضع لها', () {
      WheelService.instance.status.value = status();
      expect(WheelService.instance.indexOfPrize(1), 0);
      expect(WheelService.instance.indexOfPrize(5), 4);
      // ★ قطعة لا توجد في العجلة ⇒ ‎-1، أي بلا حركة: الحركة بلا أساس
      //   تُوقف العجلة على قطعة وهمية وتبيع الزبون ربحًا لم يربحه.
      expect(WheelService.instance.indexOfPrize(999), -1);
      expect(WheelService.instance.indexOfPrize(0), -1);
    });
  });

  group('هندسة الوقوف: العجلة تقف حيث قال الخادم', () {
    for (var i = 0; i < 5; i++) {
      test('القطعة رقم $i تقف تحت المؤشر', () {
        const count = 5;
        final step = math.pi * 2 / count;
        final angle = wheelStopAngle(index: i, count: count, from: 0);
        // مركز القطعة بعد الدوران = زاوية المؤشر أعلى الدائرة (-π/2).
        final center = angle + (i + 0.5) * step;
        expect(_offCircle(center + math.pi / 2), lessThan(1e-9));
      });
    }

    test('لا وقف قصير: أربع دورات كاملات على الأقل', () {
      final from = 1.234;
      final angle = wheelStopAngle(index: 2, count: 5, from: from);
      expect(angle, greaterThan(from + math.pi * 2 * 3));
    });

    test('الرقم خارج النطاق يُردّ إلى دورة العجلة', () {
      expect(
        wheelStopAngle(index: 7, count: 5, from: 0),
        wheelStopAngle(index: 2, count: 5, from: 0),
      );
      expect(
        wheelStopAngle(index: -3, count: 5, from: 0),
        wheelStopAngle(index: 2, count: 5, from: 0),
      );
    });

    test('عجلة بلا قطع لا تتحرك', () {
      expect(wheelStopAngle(index: 0, count: 0, from: 0.5), 0.5);
    });
  });

  group('ترتيب العرض داخل العجلة — «تخربيط» بلا مسّ بالقرار', () {
    // ★ نفس ما يبذره `SQL_WHEEL_PRIZES_80.sql`: ستّ قطع، قطعتا خاسر
    //   بالاسم نفسه، وأربع جوائز بأسماء مختلفة.
    const six = [
      {'id': 1, 'kind': 'none', 'amount': null, 'label': 'حظ أوفر', 'weight': 40},
      {'id': 2, 'kind': 'amount', 'amount': 250, 'label': 'خصم ٢٥٠', 'weight': 10},
      {'id': 3, 'kind': 'amount', 'amount': 500, 'label': 'خصم ٥٠٠', 'weight': 5},
      {'id': 4, 'kind': 'amount', 'amount': 750, 'label': 'خصم ٧٥٠', 'weight': 3},
      {'id': 5, 'kind': 'amount', 'amount': 1000, 'label': 'خصم ١٠٠٠', 'weight': 2},
      {'id': 6, 'kind': 'none', 'amount': null, 'label': 'حظ أوفر', 'weight': 40},
    ];
    final src = [for (final m in six) WheelPrize.fromJson(m)];

    test('الخلط يحفظ كل قطعة مرّة واحدة (نفس المعرّفات)', () {
      final out = scrambleWheelPrizes(src, math.Random(7));
      expect(out.length, src.length);
      expect(out.map((p) => p.id).toSet(), src.map((p) => p.id).toSet());
      expect(out.map((p) => p.weight).fold(0, (a, b) => a + b), 100);
    });

    test('قطعتا «حظ أوفر» لا تتجاوران — ولا عند التقاء طرفَي الدائرة', () {
      for (var seed = 0; seed < 60; seed++) {
        expect(
          prizesAreSpread(scrambleWheelPrizes(src, math.Random(seed))),
          isTrue,
          reason: 'الترتيب خرج متجاورًا عند البذرة $seed',
        );
      }
    });

    test('البحث عن جائزة الخادم يُصيب مكانها في الترتيب الجديد', () {
      final out = scrambleWheelPrizes(src, math.Random(3));
      final i = out.indexWhere((p) => p.id == 5);
      expect(i, greaterThanOrEqualTo(0));
      expect(out[i].amount, 1000);
      // والسهم يقف على مركز القطعة رقم [i]، وهي الجائزة نفسها.
      final angle = wheelStopAngle(index: i, count: out.length, from: 0);
      final center = -math.pi / 2;
      expect(_offCircle(angle + (i + 0.5) * (math.pi * 2 / out.length) - center),
          lessThan(0.001));
    });

    test('الخلط يُغيّر ترتيب المعرّفات في أغلب البذور', () {
      var changed = 0;
      for (var seed = 0; seed < 20; seed++) {
        final out = scrambleWheelPrizes(src, math.Random(seed));
        if (out.map((p) => p.id).join(',') != '1,2,3,4,5,6') changed++;
      }
      expect(changed, greaterThan(15));
    });

    test('قطع قليلة لا تُخلط ولا تنقلب عليها', () {
      final two = src.take(2).toList();
      expect(scrambleWheelPrizes(two, math.Random(1)).map((p) => p.id).join(','),
          '1,2');
    });
  });
}
