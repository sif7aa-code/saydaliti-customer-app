import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_colors.dart';

import '../models/product.dart';
import '../models/shop.dart';
import 'real_data_service.dart';

/// الصيدليات التي شاهدتها مؤخراً — تُحفظ فعلياً على الجهاز وتتحدث
/// تلقائياً بمجرد فتح أي صيدلية (قسم "شاهدتها مؤخراً" الحقيقي في الرئيسية).
class RecentViewsStore {
  RecentViewsStore._();
  static final instance = RecentViewsStore._();

  static const _kKey = 'recent_viewed_shops';
  static const _kMax = 10;

  /// يُستدعى فور فتح أي صيدلية من أي شاشة.
  Future<void> addShop(Shop shop) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _load(prefs);
      list.removeWhere((e) => e['id'] == shop.id);
      list.insert(0, {
        'id': shop.id,
        'name': shop.name,
      });
      if (list.length > _kMax) list.removeRange(_kMax, list.length);
      await prefs.setString(_kKey, jsonEncode(list));
    } catch (_) {}
  }

  /// ★ يُستدعى عند حذف الصيدلية من اللوحة: يمسحه من «شاهدتها مؤخراً»
  ///   فلا يعود ظاهراً في الصيدليات من ذاكرة الجهاز.
  Future<void> removeShop(String shopId) async {
    if (shopId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _load(prefs);
      final before = list.length;
      list.removeWhere((e) => e['id']?.toString() == shopId);
      if (list.length != before) {
        await prefs.setString(_kKey, jsonEncode(list));
      }
    } catch (_) {}
  }

  Future<void> addProductView(Product product) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'recent_viewed_products';
      final raw = prefs.getString(key);
      final list = <Map<String, dynamic>>[];
      if (raw != null && raw.isNotEmpty) {
        try {
          final dec = jsonDecode(raw) as List;
          list.addAll(dec.map((e) => Map<String, dynamic>.from(e as Map)));
        } catch (_) {}
      }
      list.removeWhere((e) => e['id'] == product.id);
      list.insert(0, {'id': product.id, 'name': product.name});
      if (list.length > 20) list.removeRange(20, list.length);
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {}
  }

  /// يحمّل الصيدليات المحفوظة ويحلّها إلى نماذج Shop (بالبينات الحقيقية).
  Future<List<Shop>> resolveShops() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _load(prefs);
      if (list.isEmpty) return <Shop>[];
      final all = await RealDataService.instance.fetchAllShops();
      final byId = {for (final s in all) s.id: s};
      final shops = <Shop>[];
      // ★ صيدلية محفوظ لم يعد في الكتالوج = حُذف من القاعدة، فلا نُعيده من
      //   الذاكرة المحلية كصفٍّ بديل: البديل يبقى على كل الأجهزة يفتح صيدليةاً
      //   ميتاً. يُستعمل الصف البديل فقط إن فشل تحميل الكتالوج كله (بلا شبكة
      //   ولا نسخة محفوظة)، حفظاً لسرعة الفتح في هذه الحالة وحدها.
      final catalogEmpty = all.isEmpty;
      for (final e in list) {
        final id = e['id']?.toString() ?? '';
        final name = e['name']?.toString() ?? '';
        final real = byId[id];
        if (real != null) {
          shops.add(real);
        } else if (catalogEmpty) {
          shops.add(Shop(
            id: id,
            name: name.isEmpty ? 'صيدلية' : name,
            backgroundColor: AppColors.brandDark,
            logo: Icons.storefront_rounded,
          ));
        }
      }
      return shops;
    } catch (_) {
      return <Shop>[];
    }
  }

  List<Map<String, dynamic>> _load(SharedPreferences prefs) {
    final raw = prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return List<Map<String, dynamic>>.from(
        (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (_) {
      return [];
    }
  }
}
