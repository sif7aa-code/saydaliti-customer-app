import 'package:intl/intl.dart';

abstract final class CurrencyFormatter {
  static const String symbol = 'د.ع';

  /// نسخة واحدة فقط: بُني `NumberFormat` يحلّل النمط ويهيّئ بيانات اللغة
  /// في المُنشئ، وتكراره مع كل استدعاء كان يبني مئات الكائنات في الثانية
  /// (مرتان لكل بطاقة منتج) فيبطئ البناء والتمرير.
  static final NumberFormat _formatter = NumberFormat('#,##0.###', 'ar_IQ');

  static String format(num amount) => '${_formatter.format(amount)} $symbol';

  static String formatPlain(num amount) => _formatter.format(amount);
}
