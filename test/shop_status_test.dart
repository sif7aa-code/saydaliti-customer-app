import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/core/utils/shop_status.dart';
import 'package:saydaliti/models/shop.dart';
import 'package:saydaliti/services/shop_hours_store.dart';
import 'package:saydaliti/widgets/shop_gate.dart';

/// ★ وقت ثابت: الأربعاء ٢٠٢٦-١٠-٢٨ الساعة ١٢:٠٠ — لا ساعة الجهاز،
///   فالاختبار لا يتغيّر بتغيّر اليوم الذي يُشغَّل فيه.
final DateTime noon = DateTime(2026, 10, 28, 12, 0);
final DateTime lateNight = DateTime(2026, 10, 28, 23, 30);
final DateTime earlyMorning = DateTime(2026, 10, 28, 7, 0);
final DateTime afterMidnight = DateTime(2026, 10, 29, 1, 0);

Shop shop({
  String id = 's1',
  String name = 'الزوزايه',
  String hours = '09:00 ص – 11:00 م',
  String days = 'يومياً',
  bool open = true,
}) => Shop(
  id: id,
  name: name,
  logo: Icons.storefront_rounded,
  backgroundColor: Colors.white,
  isOpen: open,
  workingHours: hours,
  workingDays: days,
);

void main() {
  setUp(ShopHoursStore.instance.clear);
  tearDown(ShopHoursStore.instance.clear);

  group('حالة المتجر من الوقت الحقيقي', () {
    test('داخل النافذة ⇒ مفتوح، ويُخبر متى يغلق', () {
      final s = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        at: noon,
      );
      expect(s.isOpen, isTrue);
      expect(s.closesAt, DateTime(2026, 10, 28, 23, 0));
      expect(s.stateLine, contains('مفتوح'));
      expect(s.countdownLine(), contains('يغلق بعد'));
    });

    test('قبل الفتح ⇒ مغلق والسبب صريح ويفتح اليوم', () {
      final s = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        at: earlyMorning,
      );
      expect(s.isOpen, isFalse);
      expect(s.reason, ShopClosedReason.beforeOpening);
      expect(s.opensAt, DateTime(2026, 10, 28, 9, 0));
      expect(s.blockMessage('الزوزايه'), contains('يفتح اليوم'));
      expect(s.countdownLine(), contains('يفتح بعد'));
    });

    test('بعد الإغلاق ⇒ مغلق ويفتح غداً بنفس الساعة', () {
      final s = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        at: lateNight,
      );
      expect(s.isOpen, isFalse);
      expect(s.reason, ShopClosedReason.afterClosing);
      expect(s.opensAt, DateTime(2026, 10, 29, 9, 0));
      expect(s.blockMessage('الزوزايه'), contains('غداً'));
    });

    test('يوم عطلة ⇒ مغلق بسبب اليوم لا الساعة', () {
      final s = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        workingDays: 'الجمعة',
        at: noon, // الأربعاء
      );
      expect(s.isOpen, isFalse);
      expect(s.reason, ShopClosedReason.holiday);
      expect(s.opensAt, DateTime(2026, 10, 30, 9, 0));
      // الحالة تقول «بعد يومين» (لا اسم اليوم) لأن الفارق يومان —
      // والصيغة نفسها المستعملة في كل شاشات الزبون.
      expect(s.blockMessage('الزوزايه'), contains('يفتح'));
    });

    test('نافذة تعبر منتصف الليل: ١:٠٠ صباحاً ما زال مفتوحاً', () {
      final late = shopStatusAt(
        workingHours: '10:00 م – 03:00 ص',
        at: afterMidnight,
      );
      expect(late.isOpen, isTrue);
      expect(late.closesAt, DateTime(2026, 10, 29, 3, 0));

      final midday = shopStatusAt(
        workingHours: '10:00 م – 03:00 ص',
        at: noon,
      );
      expect(midday.isOpen, isFalse);
      expect(midday.reason, ShopClosedReason.beforeOpening);
    });

    test('الإيقاف اليدوي يغلب الوقت', () {
      final s = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        manualOpen: false,
        at: noon,
      );
      expect(s.isOpen, isFalse);
      expect(s.isManualClosed, isTrue);
      expect(s.blockMessage('الزوزايه'), contains('موقوف'));
      expect(s.countdownLine(), contains('يدوياً'));
    });

    test('«٢٤ ساعة» قرار صريح: مفتوح حتى ٣ فجراً', () {
      final s = shopStatusAt(
        workingHours: '٢٤ ساعة',
        at: afterMidnight,
      );
      expect(s.isOpen, isTrue);
      expect(s.closesAt, isNull);
      expect(s.stateLine, contains('طوال اليوم'));
    });

    test('جدول لا يُفهم ⇒ لا نُغلق متجراً لم يضبط أحدٌ وقته', () {
      final s = shopStatusAt(workingHours: 'حسب المزاج', at: afterMidnight);
      expect(s.isOpen, isTrue);
      expect(s.schedule.hoursKnown, isFalse);
      // لا جدول ⇒ لا بوابة تُغلق: البوابة تسأل وتجد الحالة مفتوحة.
      expect(ShopGate.isOpen(shopId: 's1'), isTrue);
    });

    test('أرقام عربية في الوقت تُقرأ مثل الإنجليزية', () {
      final s = shopStatusAt(
        workingHours: '٠٩:٠٠ ص – ١١:٠٠ م',
        at: noon,
      );
      expect(s.isOpen, isTrue);
    });

    // ★ صفحة المتاجر تعرض [windowLine] بدل نص القاعدة الخام، فسطر الوقت فيها
    //   ساعة مُنسَّقة دائماً، وموعد الفتح حين يكون المتجر مغلقاً.
    test('سطر النافذة: وقت منسّق من الجدول، لا النص كما خُزّن', () {
      final s = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        workingDays: 'يومياً',
        at: noon,
      );
      expect(s.windowLine, '09:00 ص – 11:00 م');
    });

    test('سطر النافذة: الأيام المقيّدة تُذكر مع الوقت', () {
      // noon = الأربعاء ٢٠٢٦-١٠-٢٨، فيوم العمل نفسه حتى تكون النافذة قائمة.
      final s = shopStatusAt(
        workingHours: '07:00 - 22:00',
        workingDays: 'الأربعاء فقط',
        at: noon,
      );
      expect(s.isOpen, isTrue);
      expect(s.windowLine, contains('07:00 ص – 10:00 م'));
      expect(s.windowLine, contains('الأربعاء فقط'));
    });

    test('سطر النافذة: «٢٤ ساعة» ⇒ طوال اليوم، ومغلق ⇒ متى يفتح', () {
      expect(
        shopStatusAt(workingHours: '٢٤ ساعة', at: afterMidnight).windowLine,
        'مفتوح طوال اليوم',
      );
      final closed = shopStatusAt(
        workingHours: '09:00 ص – 11:00 م',
        at: lateNight,
      );
      expect(closed.windowLine, startsWith('مغلق •'));
      expect(closed.windowLine, contains('يفتح'));
    });

    test('سطر النافذة: جدول لا يُفهم يُعرض كما كتبه الأدمن، بلا اختلاق', () {
      final s = shopStatusAt(workingHours: 'حسب المزاج', at: afterMidnight);
      expect(s.windowLine, 'حسب المزاج');
      final empty = shopStatusAt(workingHours: '   ', at: afterMidnight);
      expect(empty.windowLine, 'مفتوح الآن');
    });
  });

  group('بوابة السلة', () {
    test('الجدول غير معروف ⇒ لا منع', () {
      expect(
        ShopGate.blockMessage(shopId: 'unknown', shopName: 'مجهول'),
        isNull,
      );
    });

    test('متجر موقوف يدوياً ⇒ رسالة باسمه الحقيقي', () {
      ShopHoursStore.instance.remember(shop(open: false));
      final msg = ShopGate.blockMessage(
        shopId: 's1',
        shopName: 'الزوزايه',
      );
      expect(msg, isNotNull);
      expect(msg, contains('الزوزايه'));
      expect(ShopGate.isOpen(shopId: 's1'), isFalse);
    });

    test('متجر داخل وقته ⇒ المرور بلا رسالة', () {
      ShopHoursStore.instance.remember(shop(hours: '٢٤ ساعة'));
      expect(ShopGate.isOpen(shopId: 's1'), isTrue);
      expect(
        ShopGate.blockMessage(shopId: 's1', shopName: 'الزوزايه'),
        isNull,
      );
    });
  });
}
