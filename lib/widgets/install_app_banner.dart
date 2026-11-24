library;

/// بطاقة «ثبّت التطبيق على شاشتك» — ويب فقط.
///
/// كان هذا الملف يستورد `dart:js_interop` مباشرة، وأي بناء أندرويد يدخل
/// في شجره (الرئيسية) يفشل بـ«Dart library 'dart:js_interop' is not
/// available on this platform». الفصل هنا: نسخة ويب تستدعي دوال
/// `web/index.html`، وبديل صامت على الهاتف. من يستورد هذا الملف لا يرى
/// فرقاً — الاسم واحد.
export 'install_app_banner_stub.dart'
    if (dart.library.js_interop) 'install_app_banner_web.dart';
