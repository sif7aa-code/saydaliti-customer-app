import 'currency_formatter.dart';

/// ★ طريقة الاستقطاع — يحددها الأدمن لكل عيادة وصيدلية من لوحة التحكم.
enum DeductionMethod {
  fixed('مبلغ ثابت'),
  percent('نسبة %');

  const DeductionMethod(this.label);
  final String label;
}

DeductionMethod deductionMethodOf(Object? raw) =>
    '$raw'.trim() == 'percent' ? DeductionMethod.percent : DeductionMethod.fixed;

/// ★ النص الوحيد لوصف استقطاع في التطبيق كله — الشاشات لا تكتب
///   «500» ولا «10%» بنفسها: الرقم يصل من القاعدة عبر هذه الدالة.
String deductionText(
  DeductionMethod method,
  double value, {
  required String unit,
}) {
  final v = value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2);
  if (method == DeductionMethod.percent) {
    return '$v% من كل $unit';
  }
  return '${CurrencyFormatter.format(value)} لكل $unit';
}
