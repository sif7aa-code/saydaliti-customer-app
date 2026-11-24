import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:saydaliti/services/catalog_cache.dart';
import 'package:saydaliti/services/real_data_service.dart';
import 'package:saydaliti/services/recent_view_store.dart';

/// ★ حراسة «حذف المنتج فوري وبلا كاش».
///
/// المنتج يُحذف من القاعدة نهائياً، لكن جهاز الزبون/التاجر يحمل نسخة قرص
/// منه (`catalog_products` ونسخ المتاجر `catalog_products_<shopId>`)،
/// فتعيد الشاشات رسم السطر المحذوف. الدالة
/// [RealDataService.purgeProductFromCaches] تمسح السطر من كل نسخة،
/// وهذه الاختبارات تثبت أنها تمسح **السطر وحده** ولا تلمس شيئاً آخر.
Map<String, dynamic> _row(String id, String name, {String shopId = 'shop-1'}) =>
    {
      'id': id,
      'name': name,
      'price': 1000,
      'is_active': true,
      'shop_id': shopId,
      'shop_name': 'زوزايه',
    };

Future<void> _seed(
  String key,
  List<Map<String, dynamic>> rows, {
  String savedAt = '2026-01-01T00:00:00.000',
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'catalog_$key',
    jsonEncode({'saved_at': savedAt, 'rows': rows}),
  );
}

Future<List<Map<String, dynamic>>> _readRaw(String key) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('catalog_$key');
  if (raw == null) return const [];
  final data = jsonDecode(raw) as Map<String, dynamic>;
  return ((data['rows'] ?? []) as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}

Future<String> _savedAt(String key) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('catalog_$key');
  if (raw == null) return '';
  return (jsonDecode(raw) as Map<String, dynamic>)['saved_at']?.toString() ??
      '';
}

void main() {
  // مرآة الذاكرة في `CatalogCache` تبقى بين الاختبارات (مفردة)، فتُطهَّر
  // المفاتيح المستعملة هنا وإلا قرأ اختبارٌ نسخة اختبارٍ سابق.
  const keys = [
    'products',
    'products_shop-1',
    'products_shop-2',
    'products_shop-3',
    'shops',
    'categories',
    'banners',
  ];

  // ★ تُهيَّأ المتجر الوهمي **مرة** قبل كل الاختبارات: إعادة تهيئتها بين
  //   الاختبارات تُبدّل نسخة `SharedPreferences` المحفوظة داخل
  //   `CatalogCache`، فيقرأ الكاش مخزناً آخر ولا يرى ما بذرناه.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('catalog_') || key == 'recent_viewed_shops') {
        await prefs.remove(key);
      }
    }
  });

  setUp(() async {
    for (final key in keys) {
      await CatalogCache.instance.clearFor(key);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('recent_viewed_shops');
  });

  group('purgeProductFromCaches', () {
    test('يمسح السطر المحذوف من الكتالوج الكامل ولا يمسّ بقيته', () async {
      await _seed('products', [_row('a', 'لبن'), _row('b', 'تمر'), _row('c', 'دقيق')]);

      await RealDataService.instance.purgeProductFromCaches('b');

      final left = await _readRaw('products');
      expect(left.map((r) => r['id']), ['a', 'c']);
      expect(left.map((r) => r['name']), ['لبن', 'دقيق']);
    });

    test('يمسحه من نسخ المتاجر المحفوظة على القرص وإن لم تفتح الذاكرة',
        () async {
          await _seed('products', [_row('a', 'لبن')]);
          await _seed('products_shop-1', [
            _row('a', 'لبن'),
            _row('b', 'تمر'),
          ]);
          await _seed('products_shop-2', [
            _row('b', 'تمر'),
            _row('d', 'خبز'),
          ]);

          await RealDataService.instance.purgeProductFromCaches('b');

          expect((await _readRaw('products_shop-1')).map((r) => r['id']), ['a']);
          expect((await _readRaw('products_shop-2')).map((r) => r['id']), ['d']);
        });

    test('لا يلمس الأقسام والمتاجر واللافتات', () async {
      await _seed('products', [_row('a', 'لبن'), _row('b', 'تمر')]);
      await _seed('shops', [
        {'id': 'b', 'name': 'متجر حرف b'},
        {'id': 'z', 'name': 'متجر حرف z'},
      ]);
      await _seed('categories', [
        {'id': 'b', 'name_ar': 'قسم حرف b'},
      ]);
      await _seed('banners', [
        {'id': 'b', 'title': 'بانر حرف b'},
      ]);

      await RealDataService.instance.purgeProductFromCaches('b');

      // سطر المتجر الذي معرّفه 'b' باقٍ: العملية مقصورة على نسخ المنتجات.
      expect((await _readRaw('shops')).map((r) => r['id']), ['b', 'z']);
      expect((await _readRaw('categories')).map((r) => r['id']), ['b']);
      expect((await _readRaw('banners')).map((r) => r['id']), ['b']);
      // والكتالوج تخلص من المحذوف فقط.
      expect((await _readRaw('products')).map((r) => r['id']), ['a']);
    });

    test('المعرّف الفارغ لا يغيّر شيئاً', () async {
      await _seed(
        'products',
        [_row('a', 'لبن'), _row('b', 'تمر')],
        savedAt: '2026-01-01T00:00:00.000',
      );

      await RealDataService.instance.purgeProductFromCaches('');

      expect((await _readRaw('products')).length, 2);
      expect(await _savedAt('products'), '2026-01-01T00:00:00.000');
    });

    test('النبض يُبلغ الشاشات المفتوحة (catalogGeneration يزداد)', () async {
      await _seed('products', [_row('a', 'لبن'), _row('b', 'تمر')]);
      final before = RealDataService.instance.catalogGeneration.value;

      await RealDataService.instance.purgeProductFromCaches('b');

      expect(RealDataService.instance.catalogGeneration.value,
          greaterThan(before));
    });

    test('بلا نسخة محفوظة: لا استثناء ولا كسر', () async {
      await RealDataService.instance.purgeProductFromCaches('ghost');
      expect(await _readRaw('products'), isEmpty);
    });
  });

  group('CatalogCache.purgeRowFrom', () {
    test('يعيد المفاتيح التي تغيّرت فقط', () async {
      await _seed('products_shop-1', [_row('b', 'تمر')]);
      await _seed('products_shop-2', [_row('x', 'حليب')]);
      await _seed('products_shop-3', [
        _row('b', 'تمر'),
        _row('y', 'ماء'),
      ]);

      final touched = await CatalogCache.instance.purgeRowFrom('products_', 'b');

      expect(touched.toSet(), {'products_shop-1', 'products_shop-3'});
      // الذي لم يتغيّر بقي وقته كما هو (لا إعادة كتابة عبثية).
      expect(await _savedAt('products_shop-2'), '2026-01-01T00:00:00.000');
    });

    test('قصر السطر يحدّذ مرآة الذاكرة فلا تُقرأ نسخة قديمة', () async {
      await _seed('products', [_row('a', 'لبن'), _row('b', 'تمر')]);
      // تُحمَّل المرآة أولاً كما تفعل الشاشة عند الفتح.
      final loaded = await CatalogCache.instance.read('products');
      expect(loaded!.length, 2);

      await CatalogCache.instance.purgeRowFrom('product', 'b');

      expect((await CatalogCache.instance.read('products') ?? const []).length, 1);
    });
  });

  group('purgeShopFromCaches', () {
    test('المتجر يختفي هو ومنتجاته وأقسامه، وغيره يبقى حرفياً', () async {
      await _seed('shops', [
        {'id': 'shop-1', 'name': 'زوزايه'},
        {'id': 'shop-2', 'name': 'الرافدين'},
      ]);
      await _seed('products', [
        _row('a', 'لبن'),
        _row('b', 'تمر'),
        _row('z', 'ماء', shopId: 'shop-2'),
      ]);
      await _seed('products_shop-1', [
        _row('a', 'لبن'),
        _row('b', 'تمر'),
      ]);
      await _seed('products_shop-2', [
        _row('z', 'ماء', shopId: 'shop-2'),
      ]);
      await _seed('categories', [
        {'id': 'c1', 'name_ar': 'قسم المتجر', 'shop_id': 'shop-1'},
        {'id': 'c2', 'name_ar': 'قسم عام', 'shop_id': null},
      ]);

      await RealDataService.instance.purgeShopFromCaches('shop-1');

      expect((await _readRaw('shops')).map((r) => r['id']), ['shop-2']);
      expect((await _readRaw('products')).map((r) => r['id']), ['z']);
      expect((await _readRaw('products_shop-2')).map((r) => r['id']), ['z']);
      expect((await _readRaw('categories')).map((r) => r['id']), ['c2']);
      // نسخة المتجر المحذوف تُحذف بمفتاحها لا تُترك فارغة.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('catalog_products_shop-1'), isFalse);
    });

    test('النبض يُبلغ الشاشات المفتوحة (catalogGeneration يزداد)', () async {
      await _seed('shops', [
        {'id': 'shop-1', 'name': 'زوزايه'},
      ]);
      final before = RealDataService.instance.catalogGeneration.value;

      await RealDataService.instance.purgeShopFromCaches('shop-1');

      expect(RealDataService.instance.catalogGeneration.value,
          greaterThan(before));
    });

    test('المعرّف الفارغ لا يغيّر شيئاً', () async {
      await _seed('shops', [
        {'id': 'shop-1', 'name': 'زوزايه'},
      ]);
      await _seed('products', [_row('a', 'لبن')], savedAt: '2026-01-01T00:00:00.000');

      await RealDataService.instance.purgeShopFromCaches('');

      expect((await _readRaw('shops')).length, 1);
      expect((await _readRaw('products')).length, 1);
      expect(await _savedAt('products'), '2026-01-01T00:00:00.000');
    });
  });

  group('RecentViewsStore.removeShop', () {
    test('يمسح المتجر المحذوف من «شاهدتها مؤخراً» ويبقي غيره', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'recent_viewed_shops',
        jsonEncode([
          {'id': 'shop-1', 'name': 'زوزايه'},
          {'id': 'shop-2', 'name': 'الرافدين'},
        ]),
      );

      await RecentViewsStore.instance.removeShop('shop-1');

      final left = (jsonDecode(prefs.getString('recent_viewed_shops')!) as List)
          .map((e) => (e as Map)['id'])
          .toList();
      expect(left, ['shop-2']);
    });
  });
}
