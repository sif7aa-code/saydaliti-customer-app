import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';

/// أدوات تواصل المندوب مع الزبون: اتصال مباشر أو رسالة واتساب.
class ContactTools {
  const ContactTools._();

  /// النمط يُصرَّف مرّة واحدة: `RegExp` لا يُخزَّن مؤقتاً في Dart،
  /// فكان كل استدعاء لـ [normalize] يعيد بناء النمط من الصفر.
  static final RegExp _nonDigits = RegExp(r'[^0-9+]');

  /// رقم الهاتف المحلي: يحوّل 07xxxxxxxxx إلى 9647xxxxxxxx.
  static String normalize(String phone) {
    var p = phone.replaceAll(_nonDigits, '');
    if (p.startsWith('+')) p = p.substring(1);
    if (p.startsWith('00')) p = p.substring(2);
    if (p.startsWith('0')) p = '964${p.substring(1)}';
    return p;
  }

  static Future<bool> _open(
    Uri uri, {
    LaunchMode mode = LaunchMode.externalApplication,
  }) async {
    try {
      return await launchUrl(uri, mode: mode);
    } catch (_) {
      return false;
    }
  }

  /// اتصال هاتفي مباشر بالزبون.
  static Future<void> callCustomer(BuildContext context, String phone) async {
    final p = normalize(phone);
    if (p.isEmpty) {
      _toast(context, 'لا يوجد رقم هاتف للزبون');
      return;
    }
    final ok = await _open(Uri(scheme: 'tel', path: p));
    if (!ok && context.mounted) {
      _toast(context, 'تعذّر فتح تطبيق الاتصال');
    }
  }

  /// مراسلة الزبون عبر واتساب.
  static Future<void> whatsappCustomer(
    BuildContext context,
    String phone, {
    String? message,
  }) async {
    var p = normalize(phone);
    if (p.isEmpty) {
      _toast(context, 'لا يوجد رقم هاتف للزبون');
      return;
    }
    if (!p.startsWith('964')) p = '964$p';
    final text = Uri.encodeComponent(
      message?.trim().isNotEmpty == true
          ? message!.trim()
          : 'السلام عليكم، بخصوص طلبكم في اطباء ذي قار.',
    );
    final ok = await _open(Uri.parse('https://wa.me/$p?text=$text'));
    if (!ok && context.mounted) {
      _toast(context, 'تعذّر فتح واتساب');
    }
  }

  /// المعرّف الرسمي لحساب خدمة العملاء على إنستغرام.
  static const String supportInstagramUser = 'alshatra_center';

  /// صفحة **خدمة العملاء** الرسمية على إنستغرام (رابط نظيف بلا وسوم تتبّع).
  ///
  /// ★ ثابت واحد في كل المشروع: أي زر «خدمة العملاء» يفتحه
  ///   (كانت مجموعة واتساب، واستُبدلت بتاريخ 2026-10-29).
  static const String supportInstagram =
      'https://www.instagram.com/$supportInstagramUser/';

  /// رابط التطبيق المباشر: يفتح تطبيق إنستغرام على صفحة الحساب مباشرة.
  static const String supportInstagramApp =
      'instagram://user?username=$supportInstagramUser';

  /// فتح خدمة العملاء **مباشرة في تطبيق إنستغرام**.
  ///
  /// الترتيب مقصود: يُجرَّب رابط التطبيق أولاً — فمن يملك إنستغرام على
  /// هاتفه يجد نفسه داخل التطبيق على صفحتنا بلا متصفح وبلا صفحة وسطاء.
  /// إن لم يكن التطبيق منصَّباً ينتقل إلى الرابط الرسمي النظيف، وهو رابط
  /// إنستغرام نفسه (يعرفه التطبيق مثبَّتاً ويفتحه) وينتهي في المتصفح
  /// لغير المثبِّت — فلا رسالة خطأ تُسمَّع للزبون.
  static Future<void> openSupport(BuildContext context) async {
    if (await _open(Uri.parse(supportInstagramApp))) return;
    if (await _open(
      Uri.parse(supportInstagram),
      mode: LaunchMode.platformDefault,
    )) {
      return;
    }
    if (!context.mounted) return;
    _toast(context, 'تعذّر فتح صفحة خدمة العملاء — تأكد من الاتصال بالإنترنت');
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
        ),
      );
  }
}
