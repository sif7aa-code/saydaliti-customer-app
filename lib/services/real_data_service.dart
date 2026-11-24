import 'dart:async';

import 'package:flutter/material.dart';

import '../models/banner_item.dart';
import '../models/category_item.dart';
import '../models/product.dart';
import '../models/shop.dart';
import '../widgets/app_image.dart';
import '../widgets/emerald_banner_background.dart';
import 'auth_service.dart';
import 'catalog_cache.dart';
import 'deleted_products_guard.dart';
import 'shop_hours_store.dart';
import 'supabase_service.dart';

/// يجلب البيانات الحقيقية من قاعدة البيانات فقط.
/// لا يحتوي أي بيانات تجريبية — الشاشات تعرض ما هو مخزّن فعلاً سيرفراً
/// (الصيدليات والمنتجات والأقسام والبانرات التي يضيفها الأدمن).
///
/// الأداء: تُعرض نسخة محفوظة على الجهاز فوراً (حتى مع بطء أو انقطاع
/// الإنترنت) ثم يُحَدَّث المحتوى في الخلفية من السيرفر، وهذا يجعل فتح
/// التطبيق والتنقل سريعاً جداً.
class RealDataService {
  RealDataService._();
  static final RealDataService instance = RealDataService._();

  /// يزداد كل مرة يتغيّر فيها محتوى الكتالوج من الشبكة.
  ///
  /// كان `main_shell` ينفّذ `refreshAll()` عند كل ضغطة تبويب: تُحدَّث
  /// الذاكرة وتُكتب القرص كاملاً… ولا تُعاد بناء ولا شاشة واحدة، فيحسب
  /// المستخدم «ريفرش» بلا نتيجة. الآن تصل الشاشات إشعاراً حقيقياً.
  final ValueNotifier<int> catalogGeneration = ValueNotifier<int>(0);

  void _bumpGeneration() {
    if (catalogGeneration.value < 1 << 30) catalogGeneration.value++;
  }

  /// ★ شواهد المنتجات المحذوفة (انظر [DeletedProductsGuard]).
  ///
  /// لماذا هو حقل على الخدمة لا متغيّر عام: لأنه يخصّ **هذه الجلسة** من
  /// هذا الجهاز، ومكانه الصحيح هو نفس المكان الذي يقرأ منه الكل منتجاته —
  /// مجر التصفية في `_products` ونسخ الصيدليات — فلا تفلت شاشة منه.
  final DeletedProductsGuard _deletedProducts = DeletedProductsGuard();

  /// ★ صورة كل منتج مُحذوف بانتظار **تأكيد** الحذف قبل تحرير ملفها.
  ///
  /// المفتاح = معرّف المنتج، والقيمة = رابط الصورة كما هو في الصف. يضعها
  /// [purgeProductFromCaches] حين يستدعيها حدث البث (حذف لم نره بأنفسنا)،
  /// ويحسمها [recheckDeletedProduct]: إن غاب المعرّف عن القاعدة طُرِّد
  /// الملف من الجهاز، وإن ظهر فالحدث كان إنذاراً كاذبًا فتُمحى النيّة
  /// وحدها وتبقى الصورة محفوظة لمنتجٍ حيّ.
  final Map<String, String> _pendingImagePurge = {};

  // ---------------------------------------------------------------
  //  نطاق صاحب الصيدلية: يرى صيدليته ومنتجاته فقط
  // ---------------------------------------------------------------
  //  ★ نقطة تسوية واحدة (scope) تمرّ بها كل الشاشات: أي استدعاء
  //    للصيدليات أو المنتجات من حساب صاحب صيدلية يُقصَّى إلى صيدليته هو.
  //    لو رشّينا الفلتر في الشاشات نفسها لنسينا واحدة، فتظهر له منتجات
  //    صيدليات أخرى. هنا مستحيل: المجر واحد.
  //
  //  ★ الأدمن لا يُقصّى أبداً (قد يكون صاحب صيدلية وحساب المنصّة معاً).
  //  ★ الفلتر على **القراءة** لا على البناء: الكاش يبقى كاملاً، فتسجيل
  //    الخروج ثم دخول زبون يعرض الكتالوج كاملاً بلا إعادة تحميل.
  String? get _ownerScopeShopId {
    final a = AuthService.instance;
    if (!a.isShopOwner || a.isAdmin) return null;
    final id = a.shopId?.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  /// صيدلية واحدة فقط: صيدلية صاحب الحساب.
  List<Shop> _scopeShops(List<Shop> all) {
    final id = _ownerScopeShopId;
    if (id == null) return all;
    return all.where((s) => s.id == id).toList(growable: false);
  }

  /// منتجات صيدليته فقط.
  List<Product> _scopeProducts(List<Product> all) {
    final id = _ownerScopeShopId;
    if (id == null) return all;
    return all.where((p) => p.shopId == id).toList(growable: false);
  }

  // ---- الأقسام ----
  late final _Dataset<CategoryItem> _categories = _Dataset<CategoryItem>(
    diskKey: 'categories',
    network: () => SupabaseService.instance.fetchCategories(),
    // ★ الهوية تشمل الاسم والصورة والصيدلية المرتبط: تغيير أيٍّ منها يجب
    //   أن يُحدّث الشاشات المفتوحة، لا أن يبقى الكاش القديم صامتاً.
    identity: (c) => '${c.id}|${c.shopId}|${c.imageUrl}|${c.title}',
    onBackgroundUpdate: _bumpGeneration,
    parse: (rows) => rows.where((r) => r['is_active'] == true).map((r) {
      final id = r['id']?.toString() ?? '';
      final shopId = r['shop_id']?.toString().trim();
      return CategoryItem(
        id: id,
        title: r['name_ar']?.toString() ?? r['name_en']?.toString() ?? 'قسم',
        icon: _categoryIcon(id, r['icon_name']?.toString()),
        color: _categoryColor(r['color_hex']?.toString(), id),
        imageUrl: _firstNonEmpty([
          r['image_url']?.toString(),
          r['image_path']?.toString(),
        ]),
        shopId: (shopId == null || shopId.isEmpty || shopId == 'null')
            ? null
            : shopId,
      );
    }).toList(),
  );

  // ---- الصيدليات ----
  late final _Dataset<Shop> _shops = _Dataset<Shop>(
    diskKey: 'shops',
    network: () => SupabaseService.instance.fetchShops(),
    // ★ الهوية تشمل كل ما يراه المستخدم في بطاقة الصيدلية — الاسم والصورة
    //   والفتح/الإغلاق وساعات العمل — لا القسم فقط: تغيير الاسم أو الصورة
    //   وحده (بنفس المعرّف والقسم) كان يمرّ صامتاً فلا تُبلَّغ الشاشات،
    //   وتبقى النسخة المحلية القديمة معروضة («تظهر على شكل محلية»).
    identity: (s) =>
        '${s.id}|${s.categoryId}|${s.name}|${s.logoImage}|${s.isOpen}|'
        '${s.workingHours}|${s.workingDays}|${s.deliveryFee}|${s.specialNote}|'
        '${s.directoryKeys.join(",")}',
    // ★ والمحذوف يُقصى من ذاكرة الصيدليات لا من القرص فقط: بلا هذا كانت
    //   بطاقة الصيدلية المحذوف تبقى معروضة حتى انتهاء عمر الكاش.
    matchesId: (s, id) => s.id == id,
    onBackgroundUpdate: _bumpGeneration,
    parse: (rows) {
      final nameById = <String, String>{
        for (final c in _categories.value) c.id: c.title,
      };
      // ★ المخفي (`is_active=false`) صيدلية أُعيد صاحبها زبوناً: تختفي
      //   من الرئيسية والأقسام، وتبقى بياناتها ومنتجاتها في القاعدة.
      return rows
          .where((r) => r['is_active'] != false)
          .map((r) => _shopFromRow(r, categoryNames: nameById))
          .toList();
    },
  );

  // ---- البانرات ----
  late final _Dataset<BannerItem> _banners = _Dataset<BannerItem>(
    diskKey: 'banners',
    network: () => SupabaseService.instance.fetchBanners(),
    identity: (b) => '${b.title}|${b.imageUrl}|${b.targetUrl}|${b.shopId}',
    onBackgroundUpdate: _bumpGeneration,
    parse: (rows) => rows.where((r) => r['is_active'] == true).map((r) {
      final imagePath = r['image_path']?.toString();
      final imageUrl = r['image_url']?.toString();
      final shopId = r['shop_id']?.toString();
      return BannerItem(
        title: r['title']?.toString() ?? 'عرض جديد',
        subtitle: r['subtitle']?.toString() ?? '',
        // ★ لا شارة افتراضية: تُعرض شارة البانر فقط إذا كتبها الأدمن،
        //   وإلا تبقى فارغة فلا تظهر أي كلمة فوق البانر.
        badge: r['badge']?.toString() ?? '',
        palette: _bannerPalette(r['color_hex']?.toString()),
        icon: Icons.local_offer_rounded,
        imageUrl: _firstNonEmpty([imageUrl, imagePath]),
        // ★ المدى ٣–٣٠ ثانية هو ما يضبطه الأدمن من اللوحة، ونفس الحدّ
        //   مفروض في `BannerCarousel.minSeconds` ⇒ ما يختاره هو ما يراه.
        speedSeconds: (r['speed_seconds'] is num)
            ? ((r['speed_seconds'] as num).toInt().clamp(3, 30))
            : 6,
        shopId: (shopId == null || shopId.isEmpty || shopId == 'null')
            ? null
            : shopId,
        targetUrl: _firstNonEmpty([r['target_url']?.toString()]),
      );
    }).toList(),
  );

  Future<List<CategoryItem>> fetchCategories() => _categories.get();

  /// ★ أقسام الذاكرة وحدها بلا قرص ولا شبكة ولا `await` — للعرض
  ///   الفوري، ثم تُحدَّث من القاعدة في الخلفية. تُعيد null حين لم
  ///   يُحمَّل الكتالوج بعد.
  List<CategoryItem>? categoriesFromMemory() => _categories.peek();

  /// ★ تحديث الأقسام من الشبكة مباشرة: قسم أضافه الأدمن من «إدارة
  ///   الأقسام» يظهر فوراً بلا انتظار عمر الكاش.
  Future<List<CategoryItem>> refreshCategories() => _categories.refreshNow();

  /// ★ البانرات: صاحب الصيدلية يرى فقط بانرات صيدليته، مع البانرات العامة
  ///   (التي بلا صيدلية) لأنها لا تخصّ أحداً. بانر صيدلية آخر = تسريب
  ///   لاسم/صورة صيدلية لا ينبغي أن يراه.
  Future<List<BannerItem>> fetchBanners() async {
    final own = _ownerScopeShopId;
    if (own == null) return _banners.get();
    final all = await _banners.get();
    return all
        .where((b) => b.shopId == null || b.shopId!.isEmpty || b.shopId == own)
        .toList(growable: false);
  }

  /// تحديث البانرات من الشبكة مباشرة (يظهر أي شعار جديد فوراً).
  Future<List<BannerItem>> refreshBanners() => _banners.refreshNow();

  /// مُقصّاة لصاحب الصيدلية (انظر `_ownerScopeShopId`).
  Future<List<Shop>> fetchAllShops() async => _scopeShops(await _shops.get());

  /// الصيدليات المقترحة: كل صيدلية جديدة يضيفه الأدمن يظهر تلقائياً هنا.
  /// ★ مُقصّاة لصاحب الصيدلية.
  Future<List<Shop>> fetchSuggestedShops() async =>
      _scopeShops(await _shops.get());

  /// ★ منتجات صيدلية من **الذاكرة وحدها**: بلا قرص ولا شبكة ولا `await`.
  ///
  ///   لماذا وهي موجودة في [fetchProducts]؟ لأنه نداء `Future`، فأول إطار
  ///   لصفحة الصيدلية يُبنى بمنتجات فارغة ثم يمتلئ بعده. التمهيد هنا يسبق أول
  ///   رسم، فتظهر القائمة كاملة مع الغلاف في اللحظة نفسها.
  ///   تُعيد null حين لم يُحمَّل الكتالوج بعد — فيُستعمل المسار العادي.
  List<Product>? productsForShopFromMemory(String shopId) {
    if (shopId.isEmpty) return null;
    final loaded = _products.peek();
    if (loaded == null) return null;
    return _scopeProducts(
      loaded,
    ).where((p) => p.shopId == shopId).toList(growable: false);
  }

  /// ★ تسخين الكتالوج من شاشة الصيدليات: أول ما تُعرض القائمة نطلب `_products`
  ///   في الخلفية، فيكون محمَّلاً حين يلمس الزبون بطاقة صيدلية. بلا هذا تظهر
  ///   الصيدليات (لأنها مُحمَّلة) بينما منتجات الصيدلية الذي فُتح تنتظر رحلة شبكة
  ///   كاملة — وهذا هو البطء الذي يشتكي منه الزبون عند الدخول.
  ///   `get()` يعيد نسخة الجهاز فوراً ويحدّث خلفياً، فالكلفة على شبكة الجوال
  ///   صفر إن كان المحمَّل ما زال حديثاً.
  void warmProducts() => unawaited(_products.get());

  Future<List<Product>> fetchProducts({String? shopId}) {
    final isAll = shopId == null || shopId.isEmpty || shopId == 'all';
    // ★ صاحب الصيدلية لا يرى إلا منتجاته: نتجاهل أي shopId آخر
    //   حتى لو مرّرته شاشة، ونثبّت الطلب على صيدليته.
    if (isAll) return _products.get().then(_scopeProducts);

    // ★★ لا تطلب من الشبكة ما هو في الذاكرة أصلاً.
    // كان كل صيدلية يُفتح يُطلق `products?shop_id=eq.X` منفصلاً + كاش
    // قرص خاص به، رغم أن الكتالوج كاملاً محمّل في `_products`.
    // النتيجة: تأخير عند كل فتح صيدلية + ازدواج في التخزين.
    // الآن: نفلتر من المحمَّل فوراً، ولا نلجأ للشبكة إلا إن لم يكن
    // الكتالوج متاحاً بعد (أول زيارة قبل اكتمال التحميل).
    final loaded = _products.peek();
    if (loaded != null) {
      final filtered = loaded
          .where((p) => p.shopId == shopId)
          .toList(growable: false);
      if (filtered.isNotEmpty || loaded.isNotEmpty) {
        return Future<List<Product>>.value(filtered);
      }
    }

    return _productsByShop
        .putIfAbsent(
          shopId,
          () => _Dataset<Product>(
            diskKey: 'products_$shopId',
            network: () => SupabaseService.instance.fetchProductsOrNull(
              shopId: shopId,
              activeOnly: true,
            ),
            identity: _productIdentity,
            matchesId: (p, id) => p.id == id,
            onBackgroundUpdate: _bumpGeneration,
            // نجاح فارغ = كل منتجات الصيدلية أُطفئت ⇒ يُمسح القرص أيضاً.
            writeEmpty: true,
            parse: (rows) => _deletedProducts
                .filterRows(rows)
                .where((r) => r['is_active'] == true)
                .map(_productFromRow)
                .toList(),
          ),
        )
        .get();
  }

  late final _Dataset<Product> _products = _Dataset<Product>(
    diskKey: 'products',
    // ★ التصفية على الخادم (حمولة أصغر) — لا نعيد حسابها في العميل.
    //   والنسخة الفارغة الناجحة (كل المنتجات مطفأة) تمسح القرص أيضاً.
    network: () =>
        SupabaseService.instance.fetchProductsOrNull(activeOnly: true),
    writeEmpty: true,
    // ★ إعادة ربط المنتج بقسم (لا يتغيّر المعرّف ولا عدد الصفوف) يجب أن
    //   تُحدّث الشاشات المفتوحة أيضاً، وإلا بقيت المنتجات في قسمها القديم.
    //   والهوية تشمل الاسم والسعر والصورة واسم الصيدلية: تعديلها لا يغيّر
    //   عدد الصفوف، فبدونها يُعرض اسم/سعر قديم من النسخة المحلية.
    identity: _productIdentity,
    matchesId: (p, id) => p.id == id,
    onBackgroundUpdate: _bumpGeneration,
    // ★ الشواهد هنا (انظر [DeletedProductsGuard]): الحذف في القاعدة نهائي،
    //   لكن نسخة محمولة من القرص أو من جلبٍ سبق الحذف ثانيةً قد تحمل السطر
    //   المحذوف. التصفية في **المجر** وحده تغطي المصدرين معاً.
    parse: (rows) => _deletedProducts
        .filterRows(rows)
        .where((r) => r['is_active'] == true)
        .map(_productFromRow)
        .toList(),
  );

  final Map<String, _Dataset<Product>> _productsByShop = {};

  /// صيدلية واحدة بمعرّفها من قاعدة البيانات (أو null).
  /// ★ لا يُعيد صيدليةً غير مملوكة لصاحب الصيدلية.
  Future<Shop?> fetchShopById(String shopId) async {
    if (shopId.isEmpty) return null;
    final own = _ownerScopeShopId;
    if (own != null && own != shopId) return null;
    final shops = _scopeShops(await _shops.get());
    for (final s in shops) {
      if (s.id == shopId) return s;
    }
    return null;
  }

  /// صيدليات تابعة لقسم معيّن.
  /// ★ مُقصّاة لصاحب الصيدلية. القسم الذي سُجّل له صيدلية (`categories.shop_id`)
  ///   يعرض صيدليته حتى لو كان `shops.category_id` فارغاً (الوضع الشائع
  ///   عند إنشاء الصيدلية قبل ربطه بقسم).
  Future<List<Shop>> fetchShopsByCategory(String categoryId) async {
    final shops = _scopeShops(await _shops.get());
    if (categoryId == 'all') return shops;
    final ownerShopId = await _shopIdOfCategory(categoryId);
    if (ownerShopId != null) {
      return shops
          .where((s) => s.categoryId == categoryId || s.id == ownerShopId)
          .toList();
    }
    // ★ قسم عام (`shop_id` فارغ): صيدلياته هي التي أسندت إليه منتجاً
    //   مباشرة. بدون هذا كان رأس «صيدليات القسم (0)» يظهر فارغاً رغم أن
    //   منتجات الصيدليات تحته.
    final having = <String>{
      for (final p in _scopeProducts(await _products.get()))
        if ((p.categoryId ?? '').trim() == categoryId) p.shopId,
    };
    return shops.where((s) => having.contains(s.id)).toList();
  }

  /// معرّف الصيدلية المرتبط بقسم (‏`categories.shop_id`)، أو null.
  Future<String?> _shopIdOfCategory(String categoryId) async {
    for (final c in await _categories.get()) {
      if (c.id == categoryId) {
        final id = c.shopId?.trim() ?? '';
        return (id.isEmpty || id == 'null') ? null : id;
      }
    }
    return null;
  }

  /// منتجات قسم معيّن — بنفس قاعدة الصفحة الرئيسية بالضبط:
  ///
  /// ★ **الصيدلية أولاً**: منتج صيدليةٍ مربوطٍ بقسم يُعرض في قسم صيدليته،
  ///   حتى لو حمل `products.category_id` قسماً آخر (القسم الافتراضي
  ///   القديم في نموذج إضافة المنتج). بدون هذا كان قسم «افران ومخابز»
  ///   يظهر فارغاً رغم أن صيدليته فيه ١٢ منتجاً مسجّلة «مطاعم».
  /// ★ **الرفّ يقدَّم على الصيدلية**: منتج أسنده الأدمن إلى قسم من أقسام
  ///   صيدليته الداخلية (`categories.shop_id` = صيدليته) يظهر في ذلك القسم
  ///   وحده، لا في وجه الصيدلية العام.
  /// ★ صيدلية بلا قسم ⇒ قسم المنتج نفسه إن كان صالحاً، وإلا لا شيء.
  ///
  /// توحيد القاعدة هنا وفي [buildCategorySections] ضروري: لو اختلف
  /// قسمُ المنتج بين الرئيسية وصفحة القسم لظهر في واحدة واختفى من الأخرى.
  /// مُقصّاة لصاحب الصيدلية.
  Future<List<Product>> fetchProductsByCategory(String categoryId) async {
    final products = _scopeProducts(await _products.get());
    if (categoryId == 'all') return products;

    final categories = await _categories.get();
    final categoryIds = {for (final c in categories) c.id};
    // أقسام عامة (`categories.shop_id` فارغ): تجمع منتجات عدة صيدليات.
    final globalIds = <String>{
      for (final c in categories)
        if ((c.shopId ?? '').trim().isEmpty) c.id,
    };
    final categoryOfShop = <String, String>{};
    for (final s in _scopeShops(await _shops.get())) {
      final cid = s.categoryId.trim();
      if (cid.isEmpty || cid == 'null' || !categoryIds.contains(cid)) continue;
      categoryOfShop.putIfAbsent(s.id, () => cid);
    }
    // أقسام كل صيدلية الداخلية (`categories.shop_id`)، ووجهه في الرئيسية.
    final shelvesOfShop = <String, Set<String>>{};
    for (final c in categories) {
      final owner = c.shopId?.trim() ?? '';
      if (owner.isEmpty || owner == 'null') continue;
      if (!categoryIds.contains(c.id)) continue;
      (shelvesOfShop[owner] ??= <String>{}).add(c.id);
      // ★ `putIfAbsent`: صيدليةٌ بأقسام داخلية عدة كانت آخرُها تزحف وتُصيّرهُ
      //   يعرض كل منتجاته تحتها في كل شاشة، فيختفي وجهه الرئيسي.
      categoryOfShop.putIfAbsent(owner, () => c.id);
    }

    return products.where((p) {
      final direct = (p.categoryId ?? '').trim();
      // ★ منتج أسنده الأدمن إلى رفّ داخل صيدليته يُعرض في ذلك الرف وحده،
      //   ولا يزاحم بقية منتجات الصيدلية تحت قسم الصيدلية العام.
      if (shelvesOfShop[p.shopId]?.contains(direct) == true) {
        return direct == categoryId;
      }
      // ★ قسم عام اختاره الأدمن للمنتج يعلو على قسم وجه صيدليته، وإلا
      //   استحال تجميع منتجات عدة صيدليات تحت قسم واحد («العناية
      //   بالبشرة» مثلاً) ما دام كل صيدلية مربوطة بقسم وجه.
      if (globalIds.contains(direct)) return direct == categoryId;
      final shopCategory = categoryOfShop[p.shopId];
      if (shopCategory != null) return shopCategory == categoryId;
      return direct == categoryId;
    }).toList();
  }

  /// أكثر المنتجات طلباً: تجميع حقيقي من بنود الطلبات في قاعدة البيانات.
  /// ★ مُقصّاة لصاحب الصيدلية (لا تظهر له مبيعات غيره).
  Future<List<Product>> fetchBestsellerProducts({int limit = 8}) async {
    try {
      final items = await SupabaseService.instance.fetchAllOrderItems();
      if (items.isNotEmpty) {
        // اسم صيدلية صاحب الحساب: نحتاجه للبند الذي `shop_id` فيه فارغ
        // (بنود قديمة أنشئت قبل ربط الصيدليات).
        final ownId = _ownerScopeShopId;
        var ownName = '';
        if (ownId != null) {
          for (final s in await _shops.get()) {
            if (s.id == ownId) {
              ownName = s.name.trim().toLowerCase();
              break;
            }
          }
        }
        final agg = <String, _Agg>{};
        for (final it in items) {
          if (ownId != null) {
            final sid = (it['shop_id']?.toString() ?? '').trim();
            final sname = (it['shop_name']?.toString() ?? '')
                .trim()
                .toLowerCase();
            final mine =
                (sid.isNotEmpty && sid == ownId) ||
                (sid.isEmpty && ownName.isNotEmpty && sname == ownName);
            if (!mine) continue;
          }
          final name = (it['product_name']?.toString() ?? '').trim();
          final shopName = (it['shop_name']?.toString() ?? '').trim();
          if (name.isEmpty) continue;
          final key = name.toLowerCase();
          final qty = (it['quantity'] is num)
              ? (it['quantity'] as num).toInt()
              : 1;
          final price = (it['price'] is num)
              ? (it['price'] as num).toDouble()
              : double.tryParse(it['price']?.toString() ?? '') ?? 0;
          final a = agg.putIfAbsent(
            key,
            () => _Agg(name: name, shopName: shopName, qty: 0, price: price),
          );
          a.qty += qty;
          a.price = a.price <= 0 ? price : a.price;
        }
        if (agg.isNotEmpty) {
          // مطابقة الاسم مع الكتالوج الحقيقي لعرض صورة المنتج وصيدليته.
          // ★ مُقصّاة: لو تطابق اسم منتج مع منتج صيدلية آخر نأخذ
          //   نسخة صيدلية صاحب الحساب فقط.
          final catalog = _scopeProducts(await _products.get());
          final byName = <String, Product>{
            for (final p in catalog) p.name.trim().toLowerCase(): p,
          };
          final ranked = agg.values.toList()
            ..sort((a, b) => b.qty.compareTo(a.qty));
          final result = <Product>[];
          for (final a in ranked.take(limit)) {
            final match = byName[a.name.toLowerCase()];
            if (match != null) {
              result.add(
                Product(
                  id: match.id,
                  name: match.name,
                  shopId: match.shopId,
                  shopName: match.shopName,
                  logo: match.logo,
                  logoImage: match.logoImage,
                  backgroundColor: match.backgroundColor,
                  price: a.price > 0 ? a.price : match.price,
                  oldPrice: match.oldPrice,
                  specialNote: match.specialNote,
                  isVideo: match.isVideo,
                  categoryId: match.categoryId,
                ),
              );
            } else {
              result.add(
                Product(
                  id: 'real_${a.name.hashCode}',
                  name: a.name,
                  shopId: 'real_${a.shopName.hashCode}',
                  shopName: a.shopName.isEmpty ? 'صيدلية التوصيل' : a.shopName,
                  backgroundColor: _colorFromId(a.name),
                  price: a.price,
                ),
              );
            }
          }
          return result;
        }
      }
    } catch (_) {}
    return const [];
  }

  /// ★ تسخين الكتالوج عند إقلاع التطبيق — يُنادى من `main.dart` قبل
  ///   أن يُبنى أي شيء، فتكون رحلة الشبكة قد بدأت داخل زمن شاشة البداية.
  ///
  /// للزبون **الجديد** (لا نسخة على جهازه): لا شيء كان يبدأ قبل بناء
  /// القشرة، أي أن أول ثانية من عمر التطبيق تُمضي في الأيقونة والصوت
  /// ثم تبدأ الشبكة من الصفر ⇒ الرئيسية تقف منتظرة. الآن تنتهي الرحلات
  /// الأربع غالباً قبل أن يلمس شيئاً.
  ///
  /// للزبون **القديم**: `get()` يقرأ نسخة الجهاز ويعيد فوراً ويحدّث من
  /// الشبكة في الخلفية، فهذا النداء لا يكلّف ولا بايت على المسار الحَر.
  ///
  /// الترتيب كما في [refreshAll]: الأقسام قبل الصيدليات، لأن اسم قسم
  /// الصيدلية يُشتق من `_categories.value` وقت التحليل.
  Future<void> prefetchCatalog() async {
    // إن سبق وأن حُمِّل شيء فلا نُكرّر الرحلات: نكتفي بما هو محمَّل.
    if (_products.peek() != null || _categories.peek() != null) return;
    try {
      await _categories.get();
      await _shops.get();
      await Future.wait([_banners.get(), _products.get()]);
    } catch (_) {}
  }

  /// إعادة تحقّق هادئة عند التنقّل بين التبويبات.
  ///
  /// كان `_reloadTab` يستدعي [refreshAll] ⇒ أربع رحلات REST **قسرية**
  /// متجاوزة كل كاش مع كل ضغطة تبويب، فتدفع شبكة الجوال ثمن نقرة،
  /// والنتيجة أن البطاقات تظهر أصلاً من الذاكرة. هنا نسأل `get()`:
  /// إن كان المحمَّل عمره أقل من TTL تُعاد الذاكرة بلا شبكة إطلاقاً،
  /// وإن كان أقدم تُعرض نسخته فوراً ويُحدَّث في الخلفية ثم تُبلَّغ
  /// الشاشات عبر `catalogGeneration`. نفس الحدّة في المحتوى، بجزء من
  /// زمن النقرة واستهلاكها.
  Future<void> revalidate() async {
    // الصيدليات خلف الأقسام عمداً: تحليل صف الصيدلية يقرأ `_categories.value`
    // ليشتق اسم قسمه، فبتوازيهما يُخزَّن اسم قسم قديم (انظر [refreshAll]).
    unawaited(
      Future<void>(() async {
        await _categories.get();
        await _shops.get();
      }),
    );
    unawaited(_banners.get());
    unawaited(_products.get());
  }

  /// إلغاء كل النتائج المخزّنة مؤقتاً (ذاكرة + قرص) لتُعيد الشاشات الجلب
  /// الطازج. يُستدعى من لوحة الأدمن بعد أي إضافة/حذف/تعديل.
  Future<void> clearCache() async {
    for (final d in [
      _categories,
      _shops,
      _banners,
      _products,
      ..._productsByShop.values,
    ]) {
      d.invalidate();
    }
    // أسماء الصيدليات التي لها كاش قرص خاص (products_<shopId>).
    // كان الحذف يتركها على القرص ⇒ تفاصيل الصيدلية يعرض نسخة قديمة للأبد.
    final shopKeys = _productsByShop.keys.toList();
    _productsByShop.clear();
    await CatalogCache.instance.clearFor('categories');
    await CatalogCache.instance.clearFor('shops');
    await CatalogCache.instance.clearFor('banners');
    await CatalogCache.instance.clearFor('products');
    for (final key in shopKeys) {
      await CatalogCache.instance.clearFor('products_$key');
    }
  }

  /// ★ حذف منتج = يختفي فوراً بلا كاش **وبلا رجوع**.
  ///
  /// تُستدعى **عقب نجاح الحذف مباشرة** (لوحة الأدمن وشاشة صاحب الصيدلية،
  /// وعند وصول حدث `product.deleted` من البث). تمسح معرّف المنتج من كل نسخ
  /// المنتجات على الجهاز: الكتالوج الكامل `products`، ونسخ كل صيدلية فُتح
  /// `products_<shopId>`، ثم تُبلغ الشاشات عبر [_bumpGeneration].
  ///
  /// ★ الترتيب داخلياً مفروض لا شكليّ:
  ///   ١) `mark` — الشاهد يسبق أي شيء، ومنذ لحظته يُطرَد الصف في **كل**
  ///      `parse` (قرص كان أم شبكة)، فيصبح مستحيلاً أن يُحييه جلبٌ قديم؛
  ///   ٢) تنقية الذاكرة ثم نبضة أولى ⇒ تختفي البطاقة في هذا الإطار؛
  ///   ٣) ثم انتظار الجلب الجاري وكتابة القرص الجارية وقصر السطر من القرص
  ///      (انظر [purgeRowById])؛
  ///   ٤) ثم نبضة ثانية، فتقرأ الشاشات نسخة نظيفة من المصدرين معاً؛
  ///   ٥) ثم — وأخيراً فقط — إعادة الجلب من الشبكة إن طُلبت، لأن جلباً
  ///      يسبق المسح كان هو سبب الشكوى: يرجع بالسطر المحذوف ويكتبه من جديد.
  ///
  /// لا تلمس الأقسام ولا الصيدليات ولا اللافتات ولا بقية المنتجات: العملية
  /// محصورة في سطر واحد، والقراءة من القرص لا تُعاد عبر الشبكة افتراضياً.
  ///
  /// ★ [deletionConfirmed] = «الحذف مؤكَّد» حين تستدعيه شاشة الأدمن أو
  ///   شاشة صاحب الصيدلية (كلاهما ينتظر ردّ السيرفر بالنجاح قبل أن يستدعي
  ///   هذه الدالة)، فيُحرَّر ملف صورة المنتج من الجهاز فوراً. أما حدث
  ///   البث `product.deleted` فيستدعيها بـ`false` ويبقى التحرير معلَّقاً
  ///   حتى يفحص [recheckDeletedProduct] القاعدة: قد يكون الحدث إنذاراً
  ///   كاذباً، وتحرير صورة منتجٍ حيّ يعني إعادة تنزيلها بالبيانات.
  Future<void> purgeProductFromCaches(
    String productId, {
    bool refetch = false,
    bool deletionConfirmed = false,
  }) async {
    if (productId.isEmpty) return;
    // ١) الشاهد: قبل أي انتظار، فأي مسار يمس هذا المعرّف بعد الآن يُطرَد.
    _deletedProducts.mark(productId);
    // ★ صورة المنتج تُؤخَّذ من الذاكرة قبل المسح (بلا شبكة بلا انتظار)،
    //   فهي آخر لحظةٍ ما زال فيها المعرّف قادراً على صورة. تحرير ملف
    //   الصورة من الجهاز مشروط بتأكيد الحذف — انظر [_freeProductImage].
    final image = _knownProductImage(productId);
    if (image.isNotEmpty) {
      if (deletionConfirmed) {
        _freeProductImage(image);
      } else {
        _pendingImagePurge[productId] = image;
      }
    }
    // ٢) ★ الاختفاء في هذا الإطار: تنقية الذاكرة (بلا انتظار شيء) ثم النبض،
    //    وإلا بقيت البطاقة ظاهرة مدة الجلب الجاري — وقد تصل اثنتي عشرة
    //    ثانية إن كانت الشبكة بطيئة، فيحسبها الزبون «لم يُخفَ».
    _products.purgeFromMemory(productId);
    for (final d in _productsByShop.values) {
      d.purgeFromMemory(productId);
    }
    _bumpGeneration();
    // ٣) ثم القرص مع انتظار أي جلبٍ وكتابة جاريين فيهما.
    await _products.purgeRowById(productId);
    for (final d in _productsByShop.values) {
      await d.purgeRowById(productId);
    }
    // نسخ الصيدليات على القرص: قد لا تكون مولَّدة في الذاكرة بعد، فنسأل
    // القرص نفسه عن كل مفتاح يبدأ بـ `products_` ونقصر السطر منه.
    final touched = await CatalogCache.instance.purgeRowFrom(
      'products_',
      productId,
    );
    for (final entry in _productsByShop.entries) {
      if (touched.contains('products_${entry.key}')) entry.value.invalidate();
    }
    // ٤) نبضة ثانية: الشاشات المفتوحة (الرئيسية/الصيدليات/الشورتس/القسم)
    //    تسمع هذا العدّاد فتعيد القراءة — فتجد النسخة التي لم يعد فيها
    //    السطر المحذوف لا من الذاكرة ولا من القرص.
    _bumpGeneration();
    // ٥) الجلب بعد المسح لا قبله: هذا وحده يضمن أن آخر من يكتب هو النتيجة
    //    الطازجة، لا الطلب القديم.
    if (refetch) await refreshProducts();
  }

  /// صورة منتج محفوظة على هذا الجهاز، أو نص فارغ إن لم نعرفها.
  ///
  /// قراءة **ذاكرة** خالصة (`value` لا `get()`) — بلا شبكة وبلا قرص، لأن
  /// المستدعي هو مسار الحذف نفسه ولا يحتمل انتظراً. تُغطّى نسخة الكتالوج
  /// الكامل أولاً ثم نسخ الصيدليات المفتوحة.
  String _knownProductImage(String productId) {
    for (final p in _products.value) {
      if (p.id == productId) return p.logoImage ?? '';
    }
    for (final d in _productsByShop.values) {
      for (final p in d.value) {
        if (p.id == productId) return p.logoImage ?? '';
      }
    }
    return '';
  }

  /// ★ تحرير ملف صورة المنتج من الجهاز (قرصاً وذاكرة) بعد تأكيد حذفه.
  ///
  /// الكاش المشترك للصور (`AppImage.imageCache`) يحفظ ٦٠٠ ملف ويقرأ
  /// عمرها ثلاثين يوماً، فبلا هذا التحرير تبقى صورة منتجٍ محذوفٍ تأخذ
  /// مكانها على القرص وقد تُرسم من الذاكرة في نفس الجلسة.
  void _freeProductImage(String image) {
    if (image.isEmpty) return;
    unawaited(AppImage.forget(image));
  }

  /// ★ هل كان الحذف حقيقياً؟ اسأل القاعدة نفسها، وأرجع المنتج إن كان كذباً.
  ///
  /// الشاهد يُخفي المنتج فوراً — وهو المطلوب — لكنه يبقى حيّاً خمس عشرة
  /// دقيقة. لو جاء حدث `product.deleted` من السيرفر بلا حذفٍ فعلي (ردّ شبكة
  /// ناقص، أو كشف الحذف في `watcher.js` وهو يقارن عدّ صفوف لا حالة صفوف)
  /// فسيختفي منتج حيّ عن كل الزبائن، وهذا أضرّ من الشكوى الأصلية.
  ///
  /// لذلك نفحص بعد المسح: جلب واحد **طازج** من الشبكة (لا كاش ولا ذاكرة).
  /// إن كان المعرّف موجوداً فيه ⇒ الحذف لم يقع، فنُسقط الشاهد ونُنبض
  /// فيعود المنتج من وحده. وإن غاب ⇒ الحذف صحيح والشاهد يبقى إلى أن ينتهي.
  ///
  /// يُستدعى بعد [purgeProductFromCaches] فقط، ولا يُعاد إن زال الشاهد.
  Future<void> recheckDeletedProduct(String productId) async {
    if (productId.isEmpty) return;
    if (!_deletedProducts.blocks(productId)) return;
    List<Map<String, dynamic>> rows;
    try {
      rows = await SupabaseService.instance.fetchProducts();
    } on Object catch (_) {
      return; // لا شبكة الآن: الشاهد يبقى، والمحاولة القادمة تُحسم.
    }
    if (rows.isEmpty) return; // ردّ فارغ لا يُثبت شيئاً — لا نُرجع ولا نُخفي.
    final alive = rows.any((r) => (r['id']?.toString() ?? '') == productId);
    if (!alive) {
      // ★ الحذف صحيح: الآن فقط يُحرَّر ملف الصورة من القرص والذاكرة.
      final image = _pendingImagePurge.remove(productId);
      if (image != null) _freeProductImage(image);
      return;
    }
    // إنذار كاذب: المنتج حيّ، فتُطرَّد نيّة التحرير لا الصورة — لو حُرّر
    // ملفها الآن لاضطر الجهاز لتنزيل صورة منتجٍ موجود من جديد.
    _pendingImagePurge.remove(productId);
    _deletedProducts.unmark(productId);
    // النسخة في الذاكرة كُتبت والشاهد حيّ، فأُقصيت منها الصفقة كلها:
    // نُبطلها مرة واحدة كي تُقرأ من القرص/الشبكة وتعود البطاقة.
    _products.invalidate();
    for (final d in _productsByShop.values) {
      d.invalidate();
    }
    _bumpGeneration();
  }

  /// ★ حذف صيدلية = يختفي هو وكل ما يخصّه فوراً بلا كاش.
  ///
  /// تُستدعى **عقب نجاح الحذف مباشرة** (لوحة الأدمن). تُطهر:
  /// - سطر الصيدلية من `shops`،
  /// - كل منتج يحمل `shop_id` هذا من الكتالوج الكامل ونسخ الصيدليات،
  /// - نسخة `products_<shopId>` كلها من القرص،
  /// - الأقسام التي كانت مربوطة بالصيدلية (`categories.shop_id`).
  ///
  /// بقية الصيدليات والمنتجات والأقسام تبقى حرفياً كما هي، ثم يُنبض
  /// [catalogGeneration] فتعيد الشاشات المفتوحة الرسم بالقوائم النظيفة.
  Future<void> purgeShopFromCaches(String shopId) async {
    if (shopId.isEmpty) return;
    bool ofShop(Map<String, dynamic> r) =>
        (r['shop_id']?.toString() ?? '') == shopId;

    await _shops.purgeRowById(shopId);
    // المنتجات: الكتالوج الكامل + كل نسخة صيدلية، ونسخة الصيدلية المحذوف تُحذف
    // بمفتاحها بدل تفريغها.
    await CatalogCache.instance.purgeWhereFrom(
      'products',
      ofShop,
      removeKey: 'products_$shopId',
    );
    await CatalogCache.instance.purgeWhereFrom('categories', ofShop);
    _products.invalidate();
    _categories.invalidate();
    _productsByShop.remove(shopId)?.invalidate();
    _bumpGeneration();
  }

  /// ★★ استدعاءات refreshAll قيد التنفيذ/الدمج.
  ///
  ///   كانت النقرات المتكررة على تبويب «الرئيسية/الصيدليات»، وسحب التحديث،
  ///   وإشعارات الكتالوج تستدعي `refreshAll()` بشكل مستقل فتُطلق **أربع
  ///   رحلات REST قسرية** في كل مرة — متجاوزة TTL والكاش. هنا نُشرك أي
  ///   استدعاء ثانٍ في نفس الجريانة الجارية (coalescing)، ونضع نافذة
  ///   دمج قصيرة جداً (٥ ثوانٍ) لاستدعاءات «تحديث خلفي/نقرة تبويب»
  ///   المتقاربة. السحب اليدوي للتحديث يمر عبر `_load(force:true)` الذي
  ///   يستدعي `refreshAll()` مباشرة — والنافذة لا تؤخره أكثر من إتمام
  ///   الرحلة الجارية؛ النتيجة الصحيحة نفسها تُسلَّم.
  Future<void>? _refreshAllInFlight;
  DateTime? _refreshAllAt;
  static const Duration _refreshAllMergeWindow = Duration(seconds: 5);

  /// يجلب الكتالوج كاملاً من الشبكة متجاوزاً TTL والكاش.
  ///
  /// يُستدعى عند السحب للتحديث أو فتح تبويب (الرئيسية/الصيدليات) ليجد
  /// المستخدم أي تعديل جديد من الأدمن **دون** تلف حالة الشاشة.
  ///
  /// الترتيب مقصود ومتسلسل: `_shops` يشتق أسماء أقسامه من
  /// `_categories.value` (انظر [_shopFromRow])، فبتوازيهما كان الصيدلية
  /// يُحلَّل مقابل أقسام **قديمة** فيبقى اسم القسم الجديد فارغاً.
  Future<void> refreshAll() {
    final running = _refreshAllInFlight;
    if (running != null) return running;
    final last = _refreshAllAt;
    if (last != null &&
        DateTime.now().difference(last) < _refreshAllMergeWindow) {
      // تحديث حديث جداً: نكتفي به (بيانات طازجة بما يكفي)، ونُنهي فوراً.
      return Future<void>.value();
    }
    final f = _doRefreshAll();
    _refreshAllInFlight = f;
    return f.whenComplete(() => _refreshAllInFlight = null);
  }

  Future<void> _doRefreshAll() async {
    _refreshAllAt = DateTime.now();
    await _categories.refreshNow();
    await _shops.refreshNow();
    await Future.wait([_banners.refreshNow(), _products.refreshNow()]);
    // مولّد التحديث: نخبر الشاشات بأن الكتالوج تغيّر فتعيد جلبه وتعرضه.
    _bumpGeneration();
  }

  /// ★ تحديث **المنتجات فقط** — عند إطفاء منتج أو تغيير سعره.
  ///
  /// `refreshAll` كان يجلب الأقسام والصيدليات واللافتات أيضاً، وكل
  /// تغيير سعر لمنتج واحد كان يسحب الكتالوج كاملاً: حمولة غير
  /// مبرَّرة على شبكة الجوال، وتحديث واجهات لا علاقة لها بالمنتج.
  ///
  /// ★★ 2026-11-06 — نافذة دمج [_productsMergeWindow]، لسببين مقاسين:
  ///   ١) البثّ يرسل **حدثاً لكل منتج** عدّله الأدمن (تغيير سعر جماعي
  ///      لعشرة منتجات = عشرة أحداث في نفس اللحظة). و`refreshNow`
  ///      ينتظر الجلب الجاري ثم يطلق غيره ⇒ عشرة سحب كاملة للكتالوج،
  ///      كل واحد ٢٢٫٧KB على الشبكة، والنتيجة واحدة. الآن: الأول فوراً
  ///      والباقي يُدمج في نبضة لاحقة واحدة داخل النافذة — فلا يفقد
  ///      أي تعديل (آخر حدث يضمن جلباً بعده) ولا يتأخر أكثر من ثلاث
  ///      ثوانٍ على جهاز مفتوح.
  ///   ٢) نسخ الصيدليات `_productsByShop` لا تُقرأ ما دام الكتالوج
  ///      محمَّلاً في الذاكرة — [fetchProducts] يصفّي منها مباشرة (انظر
  ///      هناك). فكان تحديثها مع كل حدث ينزل من الشبكة نسخاً مطابقة
  ///      لما نُزيله، بلا أن يلمسها أحد. تُحدَّث الآن فقط حين تكون هي
  ///      المصدر الوحيد فعلاً (الكتالوج غير محمَّل).
  static const Duration _productsMergeWindow = Duration(seconds: 3);

  DateTime? _productsRefreshedAt;
  Future<void>? _productsMerged;

  Future<void> refreshProducts() {
    final last = _productsRefreshedAt;
    if (last == null ||
        DateTime.now().difference(last) >= _productsMergeWindow) {
      return _doRefreshProducts();
    }
    // داخل النافذة: نشارك الجريانة، أو نعد بنبضة واحدة في نهايتها.
    final running = _productsMerged;
    if (running != null) return running;
    final wait = _productsMergeWindow - DateTime.now().difference(last);
    final pending = Future<void>.delayed(wait).then((_) {
      _productsMerged = null;
      return _doRefreshProducts();
    });
    _productsMerged = pending;
    return pending;
  }

  Future<void> _doRefreshProducts() async {
    _productsRefreshedAt = DateTime.now();
    // قبل أي جلب: هل نسخ الصيدليات هي المصدر الوحيد؟
    final shopCopiesNeeded = _products.peek() == null;
    await Future.wait([
      _products.refreshNow(),
      if (shopCopiesNeeded)
        for (final d in _productsByShop.values) d.refreshNow(),
    ]);
    _bumpGeneration();
  }

  DateTime? _shopsRefreshedAt;

  /// ★ تحديث **الصيدليات فقط** — بعد بث حذفٍ من السيرفر.
  ///
  /// حذف صيدلية يمحو منتجاته، فيصل لكل جهاز حدث `product.deleted` عن كل
  /// منتج فيه؛ وهذا يجعل بطاقة الصيدلية المحذوف تبقى في كاش الجهاز حتى
  /// انتهاء عمره. تحديث الصيدليات هنا يُسقطها فوراً على كل الأجهزة.
  ///
  /// [guard]: حدث واحد لكل منتج، فصيدلية بخمسين منتجاً يرسل خمسين حدثاً في
  /// نفس الدورة — ندمجها بتحديث واحد كل ٣ ثوانٍ بدل خمسين طلباً.
  Future<void> refreshShops() async {
    final now = DateTime.now();
    final last = _shopsRefreshedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _shopsRefreshedAt = now;
    await _shops.refreshNow();
    _bumpGeneration();
  }

  // ==================== تحويلات الصفوف ====================

  Shop _shopFromRow(
    Map<String, dynamic> r, {
    Map<String, String> categoryNames = const {},
  }) {
    final id = r['id']?.toString() ?? '';
    final categoryId = r['category_id']?.toString() ?? '';
    final imagePath = r['image_path']?.toString() ?? '';
    final logoImage = r['logo_image']?.toString() ?? '';
    final amount = (r['delivery_fee_amount'] is num)
        ? (r['delivery_fee_amount'] as num).toDouble()
        : 0.0;
    final shop = Shop(
      id: id,
      name: r['name']?.toString() ?? 'صيدلية',
      logo: Icons.storefront_rounded,
      logoImage: _firstNonEmpty([imagePath, logoImage]),
      backgroundColor:
          _hexToColor(r['background_color']?.toString()) ?? _colorFromId(id),
      deliveryFee: r['delivery_fee']?.toString() ?? '',
      deliveryFeeAmount: amount,
      specialNote: r['special_note']?.toString(),
      isOpen: r['is_open'] == true,
      workingHours: r['working_hours']?.toString() ?? 'يومياً',
      workingDays: r['working_days']?.toString() ?? 'يومياً',
      categoryId: categoryId,
      categoryName: categoryNames[categoryId] ?? '',
      directoryKeys: (r['directory_keys'] is List)
          ? (r['directory_keys'] as List)
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList(growable: false)
          : const [],
    );

    // ★ جدول الأوقات يُسجَّل هنا وحده: كل صيدلية يصل إلى أي شاشة زبون مرّ
    //   من هذا السطر، فبوابة السلة (`ShopHoursStore`) تعرف وقته بلا أن
    //   تحفظ كل صفحة نسخة ثانية من الجدول.
    ShopHoursStore.instance.remember(shop);

    return shop;
  }

  Product _productFromRow(Map<String, dynamic> r) {
    final id = r['id']?.toString() ?? '';
    final name = r['name']?.toString() ?? 'منتج';
    final shopId = r['shop_id']?.toString() ?? '';
    final shopName = r['shop_name']?.toString() ?? 'صيدلية التوصيل';
    final price = (r['price'] is num)
        ? (r['price'] as num).toDouble()
        : double.tryParse(r['price']?.toString() ?? '') ?? 0;
    final oldPrice = (r['old_price'] is num)
        ? (r['old_price'] as num).toDouble()
        : double.tryParse(r['old_price']?.toString() ?? '');
    return Product(
      id: id,
      name: name,
      shopId: shopId,
      shopName: shopName,
      logo: Icons.storefront_rounded,
      logoImage: _firstNonEmpty([
        r['image_path']?.toString(),
        r['logo_image']?.toString(),
      ]),
      backgroundColor: _colorFromId(id),
      price: price,
      oldPrice: (oldPrice != null && oldPrice > 0) ? oldPrice : null,
      specialNote: r['special_note']?.toString(),
      isVideo: r['is_video'] == true,
      categoryId: r['category_id']?.toString(),
      requiresPrescription: r['requires_prescription'] == true,
    );
  }

  /// هوية المنتج للمقارنة بين النسختين: تشمل كل ما يراه المستخدم —
  /// الاسم والسعر والصورة واسم الصيدلية. بدونها كان تعديلها (بنفس عدد
  /// الصفوف) يمرّ صامتاً وتبقى النسخة المحلية القديمة هي المعروضة.
  String _productIdentity(Product p) =>
      '${p.id}|${p.categoryId}|${p.shopId}'
      '|${p.name}|${p.price}|${p.oldPrice}|${p.logoImage}|${p.shopName}'
      '|${p.specialNote}|${p.isVideo}|${p.requiresPrescription}';

  /// لون البانر الأساسي: يُقرأ من `color_hex`، ويُشتق منه كل تدرّج الخلفية.
  ///
  /// الألوان القديمة (GREEN/ORANGE/BLUE) ما زالت تُقبَّل للتوافق مع البانرات
  /// الموجودة، وكل ما عداها يُعامل كـ`#RRGGBB`.
  Color _bannerSeedColor(String? hex) {
    final raw = (hex ?? '').trim().toUpperCase();
    switch (raw) {
      case 'GREEN':
        return const Color(0xFF008000);
      case 'ORANGE':
        return const Color(0xFFB45309);
      case 'BLUE':
        return const Color(0xFF1A76F3);
    }
    var h = raw.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return const Color(0xFF008000);
    final v = int.tryParse(h, radix: 16);
    if (v == null) return const Color(0xFF008000);
    return Color(v);
  }

  EmeraldBannerPalette _bannerPalette(String? hex) =>
      EmeraldBannerPalette.of(_bannerSeedColor(hex));

  IconData _categoryIcon(String id, String? iconName) {
    switch (iconName ?? id) {
      case 'restaurants':
      case 'restaurant':
        return Icons.restaurant_rounded;
      case 'supermarket':
        return Icons.shopping_basket_rounded;
      case 'pharmacy':
        return Icons.local_pharmacy_rounded;
      case 'coffee':
      case 'cafe':
        return Icons.local_cafe_rounded;
      case 'bakery':
        return Icons.bakery_dining_rounded;
      case 'sweets':
      case 'dessert':
        return Icons.icecream_rounded;
      case 'more':
        return Icons.apps_rounded;
      default:
        return Icons.category_rounded;
    }
  }

  static const List<Color> _catColorPalette = [
    Color(0xFF008000),
    Color(0xFF36A9F9),
    Color(0xFF007300),
    Color(0xFFFD8797),
    Color(0xFF2E9E2E),
    Color(0xFFF6BA40),
    Color(0xFF269B26),
    Color(0xFF4A38E0),
  ];

  Color _categoryColor(String? hex, String id) {
    final parsed = _hexToColor(hex);
    if (parsed != null) return parsed;
    return _catColorPalette[id.hashCode.abs() % _catColorPalette.length];
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final v in values) {
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  Color? _hexToColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    var h = hex.replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }

  static const List<Color> _idColorPalette = [
    Color(0xFF008000),
    Color(0xFF36A9F9),
    Color(0xFF007300),
    Color(0xFFFD8797),
    Color(0xFF2E9E2E),
    Color(0xFFF6BA40),
    Color(0xFF269B26),
    Color(0xFF4A38E0),
  ];

  Color _colorFromId(String id) {
    return _idColorPalette[id.hashCode.abs() % _idColorPalette.length];
  }
}

/// مجموعة بيانات حقيقية تُحوَّل إلى نماذج، وتُخزَّن على القرص وتُعرض فوراً
/// (stale-while-revalidate):
/// 1) إن كانت النسخة الحية حديثة → تُعاد فوراً.
/// 2) وإن لم تكن → تُعرض نسخة الجهاز المخزّنة فوراً ويُحدَّث المحتوى خلفياً.
/// 3) وإن لم تكن هناك نسخة محفوظة → جلب مباشر من السيرفر.
class _Dataset<T> {
  _Dataset({
    required this.diskKey,
    required this.network,
    required this.parse,
    this.identity,
    this.matchesId,
    this.onBackgroundUpdate,
    this.writeEmpty = false,
  });

  final String diskKey;

  /// `null` = فشل النقل (شبكة/HTTP) ⇒ يُحتفظ بالكاش.
  /// قائمة فارغة = نجاح بلا صفوف ⇒ المحتوى الجديد فارغ فعلاً.
  final Future<List<Map<String, dynamic>>?> Function() network;
  final List<T> Function(List<Map<String, dynamic>>) parse;

  /// مفتاح يميّز العنصر (مثل `id`) لمقارنة نسختين بلا كلفة.
  final Object? Function(T item)? identity;

  /// ★ هل هذا العنصر هو صاحب هذا المعرّف؟ لازمة لمسح سطر من **الذاكرة**
  ///   عند الحذف، فلا تُترك نسخة حيّة فيه بعد اختفائه من القرص.
  final bool Function(T item, String id)? matchesId;

  /// يُستدعى عند اختلاف المحتوى في تحديث خلفي، ليُعلم الشاشات.
  final void Function()? onBackgroundUpdate;

  /// هل تُكتب القائمة الفارغة على القرص؟ يُفتح فقط حيث يعرف [network]
  /// الفرق بين الفشل والفراغ (المنتجات): إطفاء كل المنتجات يجب أن يمسح
  /// نسخة الجهاز أيضاً، وإلا عادت البطاقات عند أول تشغيل بلا شبكة.
  final bool writeEmpty;

  static const Duration ttl = Duration(seconds: 60);

  List<T>? _value;
  DateTime? _loadedAt;
  bool _refreshing = false;

  Future<List<T>>? _inFlight;

  /// ★ كتابة القرص الجاري بها العمل (تُطلقها `_doRefresh` بلا انتظار كي
  ///   لا تؤخّر العرض). يحتاجها المسح الفوري أن ينتظرها قبل أن يقصر
  ///   السطر من القرص، وإلا رجعت الكتابة بالسطر المحذوف بعد المسح.
  Future<void>? _pendingWrite;

  /// النسخة الحالية الحيّة (تُستخدم لربط الصيدليات بأسماء أقسامها).
  List<T> get value => _value ?? const [];

  /// هل تغيّر المحتوى فعلياً؟ نقارن الهوية (أو الطول) لا الكائنات.
  bool _sameIds(List<T> a, List<T> b) {
    final id = identity;
    if (id == null) return a.length == b.length;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (id(a[i]) != id(b[i])) return false;
    }
    return true;
  }

  void _notifyBackground() => onBackgroundUpdate?.call();

  /// ★ قراءة الذاكرة فقط — بلا شبكة وبلا انتظار.
  ///
  /// تُستعمل حين نستطيع الاشتغال بما هو محمَّل أصلاً (مثل فلترة
  /// منتجات صيدلية من الكتالوج الكامل) فلا داعي لطلب شبكة.
  /// تُعيد null إن لم يُحمَّل شيء بعد.
  List<T>? peek() => _value;

  Future<List<T>> get() async {
    final v = _value;
    if (v != null &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < ttl) {
      return v;
    }
    final disk = await CatalogCache.instance.read(diskKey);
    if (disk != null) {
      final parsed = parse(disk);
      _value = parsed;
      // نسخة القرص قد تكون من أي عمر (لا حدّ زمني يُطبَّق عليها)، فلا
      // نختم عليها بـ _loadedAt = الآن وإلا عوملت كأنها طازجة ٦٠ ثانية
      // كاملة وتخفي التحديث القادم.
      _loadedAt = null;
      _refreshInBackground();
      return parsed;
    }
    return _refresh();
  }

  void _refreshInBackground() {
    if (_refreshing) return;
    // يعرض النسخة المحفوظة فوراً ويحدّث من السيرفر دون انتظار.
    unawaited(_refresh());
  }

  Future<List<T>> _refresh() {
    // إن كان هناك جلب جارٍ نعيده كما هو بدل إطلاق طلب شبكة ثانٍ.
    final running = _inFlight;
    if (running != null) return running;

    final future = _doRefresh();
    _inFlight = future;
    return future;
  }

  Future<List<T>> _doRefresh() async {
    if (_refreshing) {
      return _value ?? const [];
    }
    _refreshing = true;
    final before = _value;
    try {
      final rows = await network();
      // ★ `null` = فشل النقل فقط — لا نمسح المحتوى الجيد عندها.
      //
      // قبل هذا كان الفشل والفراغ سواءً: كلاهما `[]`، فيُحتفظ بالكاش رغم
      // أن الإطفاء نجح فعلاً. فإطفاء آخر منتج ظاهر (أو كل منتجات صيدلية)
      // كان يتركه معروضاً بلا نهاية — بلاغ «عند اطفاء منتج لا يختفي».
      if (rows == null) {
        final existing = _value;
        if (existing != null) {
          _loadedAt = null; // نعيد المحاولة لاحقاً
          return existing;
        }
        final disk = await CatalogCache.instance.read(diskKey);
        _loadedAt = null;
        return _value = disk != null ? parse(disk) : const [];
      }
      final parsed = parse(rows);
      _value = parsed;
      _loadedAt = DateTime.now();
      if (rows.isNotEmpty || writeEmpty) {
        // ★ الكتابة على القرص (JSON + XML) كانت `await` هنا، أي أن
        //   زمنها يقع **على مسار العرض** ويؤخّر ظهور البيانات.
        //   نجعلها في الخلفية: العرض لا ينتظر القرص، والحفظ لا يُفقد
        //   (إن أُغلق التطبيق قبل الانتهاء، فإن أول تحديث تالٍ يعيدها).
        //   ونحتفظ بالـFuture في [_pendingWrite] حتى يستطيع
        //   [purgeRowById] أن ينتظرها: بلا هذا كان مسح السطر من القرص
        //   يسبق هذه الكتابة فتعيد هو الصف المحذوف إلى القرص.
        final w = CatalogCache.instance.write(diskKey, rows);
        _pendingWrite = w;
        unawaited(
          w.whenComplete(() {
            if (_pendingWrite == w) _pendingWrite = null;
          }),
        );
      }
      // تحديث خلفي: إن اختلف المحتوى نُعلم الشاشات لتعيد الجلب.
      // بدون هذا كان الكاش يتبدّل صامتاً فيضيع الجهد بلا فائدة.
      if (before != null && !_sameIds(before, parsed)) {
        _notifyBackground();
      }
      return parsed;
    } on Object catch (_) {
      final v = _value;
      if (v != null) return v;
      final disk = await CatalogCache.instance.read(diskKey);
      return _value = disk != null ? parse(disk) : const [];
    } finally {
      _refreshing = false;
      _inFlight = null;
    }
  }

  void invalidate() {
    _value = null;
    _loadedAt = null;
    _refreshing = false;
  }

  /// ★ أقصى سطراً واحداً بمعرفه من **الذاكرة فقط** — بلا انتظار ولا قرص.
  ///
  /// لماذا هي منفصلة: «فوري» تعني هذا الإطار لا اثنتي عشرة ثانية لاحقاً،
  /// فتنقية الذاكرة تُجرى أولاً وتُنبَض الشاشات بعدها مباشرة، أما انتظار
  /// الجلب الجاري وتقصير القرص فيأتيان بعده (انظر [purgeRowById]).
  void purgeFromMemory(String id) {
    if (id.isEmpty) return;
    final m = matchesId;
    final v = _value;
    if (m == null || v == null) return;
    final kept = v.where((t) => !m(t, id)).toList(growable: false);
    if (kept.length != v.length) _value = kept;
  }

  /// ★ أقصى سطراً واحداً بمعرفه من **الذاكرة** ومن نسخة القرص — بلا شبكة.
  ///
  /// السبب: الحذف في القاعدة نهائي، لكن نسخة الجهاز قد تحمل السطر المحذوف،
  /// فتعيد الشاشات رسمه من القرص. نمسحه من نسختنا فيختفي في نفس اللحظة
  /// على هذا الجهاز، ولا يبقى كاش يقاوم الحذف. بقية الأسطر لا تُمسّ.
  ///
  /// ★ الترتيب هو جوهر الإصلاح (بلاغ ٢٠٢٦-١٠-٢٨: «حذفت منتجاً وبقي ظاهراً
  ///   في الرئيسية»):
  ///   ١) الذاكرة أولاً بلا أي انتظار، لأن الشاشة تعرض ما في [_value]؛
  ///   ٢) ثم انتظار الجلب الجاري وكتابة القرص الجارية — فكلاهما قد يكتب
  ///      **بعدنا** إن تركناه: الجلب انطلق قبل الحذف فيحمل السطر، وكتابة
  ///      القرص تُخرج الصفوف كما هي؛
  ///   ٣) ثم قصر السطر من القرص، فلا يُحييه شيء بعدها.
  ///   وبعد انتظار الجلب نُعيد تنقية الذاكرة، فقد يكون ختم [_value] أثناء
  ///   انتظارنا. لا ننادي [invalidate]: البقية تظل معروضة بلا وميض فراغ.
  Future<void> purgeRowById(String id) async {
    if (id.isEmpty) return;

    purgeFromMemory(id);
    await drainInFlight();
    purgeFromMemory(id);
    final write = _pendingWrite;
    if (write != null) {
      try {
        await write;
      } on Object catch (_) {}
    }
    final rows = await CatalogCache.instance.read(diskKey);
    if (rows != null) {
      final kept = rows
          .where((r) => (r['id']?.toString() ?? '') != id)
          .toList(growable: false);
      // الكتابة فقط إن كان السطر موجوداً فعلاً: بلا هذا كان كل حذف يهزّ
      // ملف القرص كاملاً بلا داعٍ.
      if (kept.length != rows.length) {
        await CatalogCache.instance.write(diskKey, kept);
      }
    }
  }

  /// ★ انتظر الجلب الجاري (إن وُجد) حتى ينتهي، ولا يطلق شبكة جديدة.
  ///
  /// يُستعمل قبل أي عملية «امسح ثم أعد الجلب»: بلا هذا الانتظار يكون الجلب
  /// القديم — المنطلق قبل الحذف — هو آخر من فيكتب، فيرجع ما مسحناه.
  Future<void> drainInFlight() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final running = _inFlight;
      if (running == null) return;
      try {
        await running;
      } on Object catch (_) {}
    }
  }

  /// جلب مباشر من الشبكة متجاوزاً الكاش (عند السحب للتحديث).
  ///
  /// كان السحب المنتظر ينتظر ٣٥٠ ملّي **نوماً أعمى** ثم يجلب، فإما أن
  /// يضيع الانتظار أو ينتهي قبل الجلب. الآن ننتظر الجلب الجاري نفسه
  /// عبر الـ Future المشتركة، ثم نتجاوز الكاش بطلب شبكة واحد.
  Future<List<T>> refreshNow() async {
    final running = _inFlight;
    if (running != null) {
      await running;
    }
    _loadedAt = null;
    return _refresh();
  }
}

class _Agg {
  _Agg({
    required this.name,
    required this.shopName,
    required this.qty,
    required this.price,
  });
  final String name;
  final String shopName;
  int qty;
  double price;
}
