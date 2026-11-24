import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/services/deleted_products_guard.dart';

/// ★ اختبارات «حُذف ⇒ لا يظهر مرة أخرى» (بلاغ الأدمن ٢٠٢٦-١٠-٢٨).
///
/// الحارس كائن نقي — بلا شبكة ولا قرص — فيُختبَر وحده، وهذه بالذات
/// القطعة التي يجب أن تُختبَر وحدها: لأنها الضمان أن أي جلبٍ قادم،
/// من أي مصدر وفي أي ترتيب، لا يستطيع إحياء صفٍ محذوف.
void main() {
  final t0 = DateTime.utc(2026, 10, 28, 12);
  Map<String, dynamic> row(String id, {bool active = true}) =>
      {'id': id, 'name': 'منتج $id', 'is_active': active};

  group('DeletedProductsGuard', () {
    test('بلا شاهد: كل صف يُقبل', () {
      final g = DeletedProductsGuard();
      expect(g.blocks('a'), isFalse);
      expect(g.keeps(row('a')), isTrue);
      expect(g.length, 0);
    });

    test('المعرّف الفارغ لا يُسجَّل ولا يُحجب', () {
      // لو سُمِح له بالمرور لأخفى **كل** منتج بلا معرّف — أي إخفاء
      // الكتالوج كاملاً بحدثٍ واحد ناقص.
      final g = DeletedProductsGuard();
      g.mark('');
      expect(g.length, 0);
      expect(g.blocks(''), isFalse);
      expect(g.keeps({'id': '', 'name': 'بلا معرّف'}), isTrue);
    });

    test('شاهد واحد يُسقط صفَّه من مجموعة صفوف', () {
      final g = DeletedProductsGuard()..mark('x');
      final kept = g.filterRows([row('a'), row('x'), row('b')]);
      expect(kept.map((r) => r['id']), ['a', 'b']);
    });

    test('★ الجلب القديم الذي انطلق قبل الحذف لا يُحيي المحذوف', () {
      // هذا هو السباق الذي كان يُبقي المنتج ظاهراً في الرئيسية:
      // الطلب خرج، ثم حُذف المنتج، ثم رجع الردّ بالسطر المحذوف.
      final g = DeletedProductsGuard();
      final staleResponse = [row('a'), row('x')]; // جُمعت قبل الحذف
      g.mark('x');
      expect(g.filterRows(staleResponse).map((r) => r['id']), ['a']);
    });

    test('الشاهد ينتهي بعد العمر فيعود الصف (ولو أعاد الأدمن النشر)', () {
      final g = DeletedProductsGuard(ttl: const Duration(minutes: 15))
        ..mark('x', at: t0);
      expect(
        g.keeps(row('x'), at: t0.add(const Duration(minutes: 14, seconds: 59))),
        isFalse,
        reason: 'قبل العمر: الحظر قائم',
      );
      expect(
        g.blocks('x', at: t0.add(const Duration(minutes: 15))),
        isFalse,
        reason: 'انقضاء العمر يُسقط الشاهد عند السؤال',
      );
      expect(
        g.keeps(row('x'), at: t0.add(const Duration(minutes: 15))),
        isTrue,
        reason: 'والصف يعود يُقبل من اللحظة نفسها',
      );
      // وسقوطه أُزيل من الخريطة فلا يتراكم.
      expect(g.length, 0);
      expect(g.keeps(row('x'), at: t0.add(const Duration(minutes: 16))), isTrue);
    });

    test('الشاهد يسقط بالتحديد لا بحساب المعرّف', () {
      final g = DeletedProductsGuard()..mark('bb');
      expect(g.blocks('b'), isFalse);
      expect(g.blocks('bb'), isTrue);
    });

    test('★ السقف: التقليم يحذف الأقدم ويُبقي أحدث الشواهد', () {
      // بلا سقف كان الحذف طوال الجلسة ينمو بلا حدّ في الذاكرة.
      final g = DeletedProductsGuard(maxEntries: 3)
        ..mark('1')
        ..mark('2')
        ..mark('3')
        ..mark('4');
      expect(g.length, 3);
      expect(g.blocks('1'), isFalse, reason: 'الأقدم قُلم');
      expect(g.blocks('2'), isTrue);
      expect(g.blocks('4'), isTrue);
    });

    test('إعادة التسجيل تُجدّد العمر لا تُضاعف الصف', () {
      final g = DeletedProductsGuard(ttl: const Duration(minutes: 15))
        ..mark('x', at: t0)
        ..mark('x', at: t0.add(const Duration(minutes: 10)));
      expect(g.length, 1);
      expect(g.blocks('x', at: t0.add(const Duration(minutes: 20))), isTrue);
      expect(g.blocks('x', at: t0.add(const Duration(minutes: 26))), isFalse);
    });

    test('unmark: الإنذار الكاذب يُرجع الصف فوراً', () {
      // بوابة الأمان: حدث حذفٍ لم يحدث فعلاً لا يجوز أن يُخفي منتجاً
      // حيّاً خمس عشرة دقيقة.
      final g = DeletedProductsGuard()..mark('x');
      expect(g.keeps(row('x')), isFalse);
      g.unmark('x');
      expect(g.keeps(row('x')), isTrue);
      expect(g.liveIds, isEmpty);
    });

    test('clear: تبديل الحساب يمسح شواهد الجلسة السابقة', () {
      final g = DeletedProductsGuard()
        ..mark('x')
        ..mark('y');
      expect(g.liveIds, hasLength(2));
      g.clear();
      expect(g.length, 0);
      expect(g.keeps(row('x')), isTrue);
    });

    test('الإطفاء (is_active=false) مسألة القراءة لا الحارس', () {
      // الحارس لا ينظر إلى is_active إطلاقاً: وظيفته الحذف فقط،
      // والفلتر الآخر يبقى في `parse`. هذا الاختبار يثبث ألا التباس.
      final g = DeletedProductsGuard()..mark('a');
      expect(g.keeps(row('a', active: false)), isFalse);
      expect(g.keeps(row('b', active: false)), isTrue);
    });
  });
}
