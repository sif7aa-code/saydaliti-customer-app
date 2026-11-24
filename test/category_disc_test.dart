import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/core/theme/app_colors.dart';
import 'package:saydaliti/models/category_item.dart';
import 'package:saydaliti/widgets/category_circle.dart';
import 'package:saydaliti/widgets/category_strip.dart';

/// ★ شكل الأقسام الجديد (2026-10-29): حلقة أزرق فاتح ثابتة، فراغ أبيض،
///   حلقة بلون القسم، ثم الاسم بلا أي مسطرة تحته.
///
///   الصور هنا بلا `imageUrl` عمداً: القالب هو المقصود (الحلقتان والاسم)،
///   ولا نحتاج شبكة في اختبار شكل.
CategoryItem _cat(String id, String title, Color color) => CategoryItem(
  id: id,
  title: title,
  icon: Icons.category_rounded,
  color: color,
);

/// أي Container دائري بحدّ لونه [color] — الحلقة.
Finder _ring(Color color) => find.byWidgetPredicate((w) {
  if (w is! Container) return false;
  final d = w.decoration;
  if (d is! BoxDecoration || d.shape != BoxShape.circle) return false;
  final b = d.border;
  return b is Border && b.top.color == color;
});

void main() {
  const pink = Color(0xFFE0557F);
  const green = Color(0xFF1B7A3E);

  testWidgets('لكل قسم حلقتان: الزرقاء الفاتحة ثم حلقة بلونه', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CategoryDisc(category: _cat('1', 'ايسكريم', pink), size: 78),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    // الحلقة الخارجية: لون المرجع نفسه لكل الأقسام.
    expect(_ring(categoryRimBlue), findsOneWidget);
    // والحلقة الداخلية: لون القسم.
    expect(_ring(pink.withValues(alpha: 0.9)), findsOneWidget);
    expect(_ring(green.withValues(alpha: 0.9)), findsNothing);

    // القرص يشغل القطر المطلوب بالضبط.
    final box = tester.getSize(find.byType(CategoryDisc));
    expect(box, const Size(78, 78));
  });

  testWidgets('اسم القسم بلا مسطرة تحته', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CategoryStrip(
            categories: [_cat('1', 'ايسكريم', pink), _cat('2', 'خضار', green)],
          ),
        ),
      ),
    );

    expect(find.text('ايسكريم'), findsOneWidget);
    expect(find.text('المزيد'), findsOneWidget);

    // كل الأسماء بلون واحد — لا قسم «محدَّد» بلون أخضر.
    final label = tester.widget<Text>(find.text('ايسكريم'));
    expect(label.style?.color, AppColors.textPrimary);

    // المسطرة القديمة كانت شريطاً أخضر بعرض 18 وارتفاع 3 تحت الاسم.
    final underlines = find.byWidgetPredicate(
      (w) => w is SizedBox && w.height == 3,
    );
    expect(underlines, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('الشريط: قسم + «المزيد» بقطر 78 نفسه', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CategoryStrip(categories: [_cat('1', 'ايسكريم', pink)]),
        ),
      ),
    );

    final discs = find.byType(CategoryDisc);
    expect(discs, findsNWidgets(2));
    for (final d in tester.widgetList<CategoryDisc>(discs)) {
      expect(d.size, 78);
    }
  });
}
