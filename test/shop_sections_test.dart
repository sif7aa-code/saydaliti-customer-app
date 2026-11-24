import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saydaliti/core/theme/app_colors.dart';
import 'package:saydaliti/core/utils/shop_sections.dart';
import 'package:saydaliti/models/category_item.dart';
import 'package:saydaliti/models/product.dart';
import 'package:saydaliti/widgets/shelf_chip.dart';

CategoryItem cat(String id, String title, {String? shopId}) => CategoryItem(
  id: id,
  title: title,
  icon: Icons.category_rounded,
  color: Colors.green,
  shopId: shopId,
);

Product prod(String id, {String? categoryId}) => Product(
  id: id,
  name: 'منتج $id',
  shopId: 's1',
  shopName: 'حلويات س1',
  backgroundColor: Colors.green,
  categoryId: categoryId,
);

void main() {
  const sweets = CategoryItem(
    id: 'sweet',
    title: 'الحلويات',
    icon: Icons.cake_rounded,
    color: Colors.green,
    shopId: 's1',
  );
  const drinks = CategoryItem(
    id: 'drink',
    title: 'المشروبات',
    icon: Icons.local_cafe_rounded,
    color: Colors.green,
    shopId: 's1',
  );
  final public = cat('rest', 'مطاعم');

  group('أقسام المتجر الداخلية', () {
    test('ofShop يقبل أقسام المتجر وحدها ويستثني العام و«المزيد»', () {
      final found = ShopSections.ofShop([
        public,
        sweets,
        cat('more', 'المزيد', shopId: 's1'),
        drinks,
      ], 's1');
      expect(found.map((c) => c.id), ['sweet', 'drink']);
    });

    test('ofShop يجفّف المعرّف الفارغ و«null» النصي فلا قسم لمتجر مجهول', () {
      expect(
        ShopSections.ofShop([
          cat('a', 'أ', shopId: ''),
          cat('b', 'ب', shopId: 'null'),
        ], 's1'),
        isEmpty,
      );
      expect(ShopSections.ofShop([sweets], ''), isEmpty);
    });

    test('المتجر بلا أقسام ⇒ توزيع فارغ، فتبقى صفحة الزبون كما كانت', () {
      expect(
        ShopSections.groupProducts(
          products: [prod('p1')],
          sections: const [],
          shopCategoryId: 'rest',
        ),
        isEmpty,
      );
    });

    test('الرفّ الخاص يقدَّم على رأس المتجر', () {
      final shelves = ShopSections.groupProducts(
        products: [prod('p1', categoryId: 'drink')],
        sections: [sweets, drinks],
        shopCategoryId: 'sweet',
      );
      expect(shelves['drink'], hasLength(1));
      expect(shelves['sweet'], isEmpty);
    });

    test('منتج بقسم خارج أقسام متجره يعود لرأس المتجر (المتجر أولاً)', () {
      final shelves = ShopSections.groupProducts(
        products: [
          prod('p1', categoryId: 'rest'),
          prod('p2', categoryId: 'stale-id'),
          prod('p3'),
        ],
        sections: [sweets, drinks],
        shopCategoryId: 'sweet',
      );
      expect(shelves['sweet'], hasLength(3));
      expect(shelves['drink'], isEmpty);
    });

    test('بلا رأس: غير المصنَّف يذهب إلى «بدون قسم» ولا يختفي', () {
      final shelves = ShopSections.groupProducts(
        products: [
          prod('p1'),
          prod('p2', categoryId: 'rest'),
        ],
        sections: [sweets, drinks],
        shopCategoryId: '',
      );
      expect(shelves[ShopSections.unplacedId], hasLength(2));
      expect(shelves['sweet'], isEmpty);
    });

    test('القسم بلا منتجات يبقى رفّاً مرئياً بعدد صفر', () {
      final shelves = ShopSections.groupProducts(
        products: [prod('p1', categoryId: 'sweet')],
        sections: [sweets, drinks],
        shopCategoryId: 'sweet',
      );
      expect(shelves.containsKey('drink'), isTrue);
      expect(shelves['drink'], isEmpty);
    });

    test('headId: الرأس صالح فقط إذا كان أحد أقسام المتجر', () {
      expect(
        ShopSections.headId(shopCategoryId: 'sweet', sections: [sweets]),
        'sweet',
      );
      expect(
        ShopSections.headId(shopCategoryId: 'rest', sections: [sweets]),
        isNull,
      );
      expect(
        ShopSections.headId(shopCategoryId: 'null', sections: [sweets]),
        isNull,
      );
    });

    test('لا منتج يُفقد: مجموع الرفوف يساوي عدد المنتجات', () {
      final shelves = ShopSections.groupProducts(
        products: [
          prod('p1'),
          prod('p2', categoryId: 'drink'),
          prod('p3', categoryId: 'rest'),
          prod('p4', categoryId: 'sweet'),
        ],
        sections: [sweets, drinks],
        shopCategoryId: 'sweet',
      );
      final total = shelves.values.fold<int>(
        0,
        (sum, list) => sum + list.length,
      );
      expect(total, 4);
    });
  });

  group('شريحة القسم', () {
    Future<void> pumpChip(
      WidgetTester tester, {
      required bool isSelected,
      required VoidCallback onTap,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: ShelfChip(
              label: 'الحلويات',
              count: 12,
              isSelected: isSelected,
              onTap: onTap,
            ),
          ),
        ),
      ),
    );

    testWidgets('تعرض الاسم والعدد وتستدعي onTap عند الضغط', (tester) async {
      var taps = 0;
      await pumpChip(tester, isSelected: false, onTap: () => taps++);
      expect(find.text('الحلويات'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(taps, 1);
    });

    Color chipBackground(WidgetTester tester) => tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(ShelfChip),
            matching: find.byType(Material),
          ),
        )
        .first
        .color!;

    testWidgets('المختارة تكتسي لون الهوية، وغير المختارة تبقى مسطّحة', (
      tester,
    ) async {
      await pumpChip(tester, isSelected: true, onTap: () {});
      expect(chipBackground(tester), AppColors.primary);

      await pumpChip(tester, isSelected: false, onTap: () {});
      expect(chipBackground(tester), AppColors.surface);
    });
  });
}
