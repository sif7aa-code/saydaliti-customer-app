import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/models/category_item.dart';
import 'package:saydaliti/models/product.dart';
import 'package:saydaliti/models/shop.dart';
import 'package:saydaliti/screens/home_screen.dart';

CategoryItem cat(String id, String title, {String? shopId}) => CategoryItem(
  id: id,
  title: title,
  icon: Icons.category_rounded,
  color: Colors.green,
  shopId: shopId,
);

Shop shop(
  String id, {
  String categoryId = '',
  String name = 'متجر',
  List<String> directoryKeys = const [],
}) => Shop(
  id: id,
  name: name,
  logo: Icons.storefront_rounded,
  backgroundColor: Colors.green,
  categoryId: categoryId,
  directoryKeys: directoryKeys,
);

Product product(String id, String shopId, {String? categoryId}) => Product(
  id: id,
  name: 'منتج $id',
  shopId: shopId,
  shopName: 'متجر $shopId',
  backgroundColor: Colors.green,
  categoryId: categoryId,
);

void main() {
  test('منتجات متجرٍ مربوطٍ بقسم تظهر فيه حتى لو حملت قسماً آخر', () {
    final categories = [
      cat('restaurants', 'مطاعم'),
      cat('bakery', 'افران ومخابز'),
    ];
    final shops = [
      shop('s-rest', categoryId: 'restaurants'),
      shop('s-baker', categoryId: 'bakery', name: 'كليجه اهلنا'),
    ];
    // الواقع: منتجات المخبز مسجّلة «مطاعم» في القاعدة.
    final products = [
      product('p1', 's-rest', categoryId: 'restaurants'),
      product('p2', 's-baker', categoryId: 'restaurants'),
      product('p3', 's-baker'),
    ];

    final sections = buildCategorySections(categories, products, shops);
    final byId = {
      for (final s in sections) s.$1.id: s.$2.map((p) => p.id).toList(),
    };

    expect(byId['restaurants'], ['p1']);
    expect(byId['bakery'], ['p2', 'p3']);
    expect(byId.containsKey('all-products'), isFalse);
  });

  test('الربط من جهة categories.shop_id يكفي', () {
    final categories = [cat('bakery', 'افران ومخابز', shopId: 's-baker')];
    // المتجر نفسه بلا category_id.
    final shops = [shop('s-baker')];
    final products = [
      product('p1', 's-baker'),
      product('p2', 's-baker', categoryId: 'ghost'),
    ];

    final sections = buildCategorySections(categories, products, shops);
    expect(sections.length, 1);
    expect(sections.single.$1.title, 'افران ومخابز');
    expect(sections.single.$2.length, 2);
  });

  test('قسم جديد يُظهر منتجاته فور إضافتها', () {
    final categories = [
      cat('restaurants', 'مطاعم'),
      cat('bakery', 'افران ومخابز'),
    ];
    final shops = [shop('s-baker', categoryId: 'bakery')];
    final products = [product('new', 's-baker', categoryId: 'bakery')];
    final sections = buildCategorySections(categories, products, shops);
    expect(sections.map((s) => s.$1.id), ['bakery']);
    expect(sections.single.$2.single.id, 'new');
  });

  test('لا يُسقط منتجاً: قسم مجهول ومتجر بلا قسم ⇒ منتجات أخرى', () {
    final categories = [cat('restaurants', 'مطاعم')];
    final shops = [shop('s-no-cat')];
    final products = [product('orphan', 's-no-cat', categoryId: 'ghost')];

    final sections = buildCategorySections(categories, products, shops);
    expect(sections.single.$1.id, 'all-products');
    expect(sections.single.$2.single.id, 'orphan');
  });

  test('متجر بقسم مجهول لا يُخفي منتجاته بلا قسم', () {
    final categories = [cat('restaurants', 'مطاعم')];
    final shops = [shop('s-broken', categoryId: 'ghost')];
    final products = [product('p', 's-broken')];

    final sections = buildCategorySections(categories, products, shops);
    expect(sections.single.$1.id, 'all-products');
    expect(sections.single.$2.single.id, 'p');
  });

  test('القسم الفارغ يُخفى، والترتيب يتبع شريط الأقسام', () {
    final categories = [
      cat('gifts', 'هدايا'),
      cat('restaurants', 'مطاعم'),
      cat('empty', 'قسم فارغ'),
      cat('bakery', 'افران ومخابز'),
      cat('more', 'المزيد'),
    ];
    final shops = [
      shop('s-gift', categoryId: 'gifts'),
      shop('s-rest', categoryId: 'restaurants'),
      shop('s-baker', categoryId: 'bakery'),
    ];
    final products = [
      product('b1', 's-baker', categoryId: 'bakery'),
      product('g1', 's-gift', categoryId: 'gifts'),
      product('r1', 's-rest', categoryId: 'restaurants'),
    ];
    final sections = buildCategorySections(categories, products, shops);
    expect(sections.map((s) => s.$1.id), ['gifts', 'restaurants', 'bakery']);
  });

  test('متجر بلا قسم يتبع قسم منتجه الصالح', () {
    final categories = [cat('health', 'صحة وجمال'), cat('food', 'مطاعم')];
    final shops = [shop('s-free')];
    final products = [
      product('h1', 's-free', categoryId: 'health'),
      product('f1', 's-free', categoryId: 'food'),
    ];
    final sections = buildCategorySections(categories, products, shops);
    expect(sections.map((s) => s.$1.id), ['health', 'food']);
    expect(sections[0].$2.single.id, 'h1');
    expect(sections[1].$2.single.id, 'f1');
  });

  test('صيدلية مسندة لدليل بلا قسم أدوية تبقى منتجاتها تحت أقسامها', () {
    final categories = [cat('meds', 'أدوية')];
    final shops = [
      shop('s-dir', directoryKeys: ['pharmacies'], name: 'صيدلية الدليل'),
    ];
    final products = [product('d1', 's-dir', categoryId: 'meds')];

    final sections = buildCategorySections(categories, products, shops);
    expect(sections.single.$1.id, 'meds');
    expect(sections.single.$2.single.id, 'd1');
  });

  test('صيدلية بلا قسم أدوية وبلا أقسام دليل تبقى كما كانت', () {
    final categories = [cat('meds', 'أدوية')];
    final shops = [shop('s-free')];
    final products = [product('p1', 's-free')];

    final sections = buildCategorySections(categories, products, shops);
    expect(sections.single.$1.id, 'all-products');
    expect(sections.single.$2.single.id, 'p1');
  });
}
