import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/models/product.dart';
import 'package:saydaliti/services/wheel_service.dart';
import 'package:saydaliti/widgets/app_image.dart';

void main() {
  group('AppImage.resolve', () {
    test('يترك الرابط الكامل كما هو', () {
      const url = 'https://example.com/a.jpg';
      expect(AppImage.resolve(url), url);
    });

    test('يكمل المسار النسبي برابط التخزين العام', () {
      final out = AppImage.resolve('images/products/x.jpg');
      expect(
        out,
        'https://piepmqbqdxhnsbynjgmg.supabase.co/storage/v1/object/public/'
        'images/products/x.jpg',
      );
    });

    test('يزيل البادئات المكرّرة (public/، object/)', () {
      final expected = 'https://piepmqbqdxhnsbynjgmg.supabase.co/'
          'storage/v1/object/public/images/x.jpg';
      expect(AppImage.resolve('public/images/x.jpg'), expected);
      expect(AppImage.resolve('object/images/x.jpg'), expected);
      expect(
        AppImage.resolve('storage/v1/object/public/images/x.jpg'),
        expected,
      );
    });

    test('يتعامل مع الشرطة المائلة العكسية والمسافات', () {
      final expected = 'https://piepmqbqdxhnsbynjgmg.supabase.co/'
          'storage/v1/object/public/images/x.jpg';
      expect(AppImage.resolve('  images\\x.jpg  '), expected);
      expect(AppImage.resolve('///images/x.jpg'), expected);
    });

    test('الفارغ/null يعيدان فارغاً بلا رابط مكسور', () {
      expect(AppImage.resolve(null), '');
      expect(AppImage.resolve('   '), '');
    });
  });

  group('عجلة الحظ: الجائزة يُقرّها ردّ الخادم لا الهاتف', () {
    test('قطعة مجهولة النوع ليست فوزاً (fail-closed)', () {
      final p = WheelPrize.fromJson(const {
        'id': 1,
        'kind': 'none',
        'amount': null,
        'label': 'حظ أوفر',
        'weight': 60,
      });
      expect(p.isWin, isFalse);
      expect(p.amount, 0);
    });

    test('ردّ بلا حقول: لا نوع مجهول ولا مبلغ مخترَع', () {
      final p = WheelPrize.fromJson(const <String, dynamic>{});
      expect(p.kind, 'none');
      expect(p.isWin, isFalse);
      expect(p.label, isEmpty);
    });

    test('قطعة مبلغ هي الفوز، باسمها كما كتبه الأدمن', () {
      final p = WheelPrize.fromJson(const {
        'id': 3,
        'kind': 'amount',
        'amount': 500,
        'label': 'خصم ٥٠٠',
        'weight': 10,
      });
      expect(p.isWin, isTrue);
      expect(p.amount, 500);
      expect(p.label, 'خصم ٥٠٠');
    });
  });

  group('Product image field', () {
    test('logoImage هو حقل صورة المنتج', () {
      const p = Product(
        id: '1',
        name: 'منتج',
        shopId: 's',
        shopName: 'متجر',
        logoImage: 'images/p.jpg',
        backgroundColor: const Color(0xFF000000),
      );
      expect(p.logoImage, 'images/p.jpg');
      expect(AppImage.resolve(p.logoImage).endsWith('images/p.jpg'), isTrue);
    });
  });
}
