import 'package:flutter/foundation.dart';
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

  /// رقم خدمة العملاء الرسمي بصيغة دولية (بلا علامة +).
  static const String supportWhatsappPhone = '9647830675033';

  /// رابط خدمة العملاء الرسمي الذي يفتح واتساب على آيفون وأندرويد.
  static const String supportWhatsapp = 'https://iwtsp.com/9647830675033';

  /// رابط التطبيق المباشر: يفتح تطبيق واتساب الرسمي على محادثة الدعم.
  static const String supportWhatsappApp =
      'whatsapp://send?phone=$supportWhatsappPhone';

  /// فتح خدمة العملاء **مباشرة في تطبيق واتساب الرسمي**.
  ///
  /// الترتيب مقصود: يُجرَّب رابط التطبيق أولاً — فمن يملك واتساب على
  /// هاتفه يجد نفسه داخل المحادثة بلا متصفح ولا صفحة وسطاء، على
  /// آيفون وأندرويد معاً. إن لم يكن التطبيق منصَّباً ينتقل إلى الرابط
  /// الرسمي [supportWhatsapp]، وهو بدوره يفتح واتساب أو صفحته على الويب
  /// لغير المثبِّت — فلا رسالة خطأ تُسمَّع للزبون.
  static Future<void> openSupport(BuildContext context) async {
    // ★ المتصفح (نسخة الويب) لا يعرف مخطط whatsapp:// — فُتحت نافذة
    //   فارغة. هناك يُستعمل رابط iwtsp وحده، وهو يعرف إلى أين يوجّه.
    if (!kIsWeb && await _open(Uri.parse(supportWhatsappApp))) return;
    if (await _open(Uri.parse(supportWhatsapp))) return;
    if (!context.mounted) return;
    _toast(context, 'تعذّر فتح واتساب — تأكد من تثبيت التطبيق والاتصال بالإنترنت');
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
