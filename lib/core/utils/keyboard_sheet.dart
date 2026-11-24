import 'package:flutter/widgets.dart';

/// ★ قياسات نافذة سفلية (BottomSheet) تعرف موضع الكيبورد.
///
/// `showModalBottomSheet` **لا** يراعي `MediaQuery.viewInsets` من تلقاء
/// نفسه — بخلاف `Dialog` الذي يضيفها كحشوة داخلية (`Dialog.build` في
/// Flutter تجمع `viewInsets + insetPadding`). لذلك أي شيت فيه حقل كتابة
/// يبقى مثبتاً أسفل الشاشة ويغطيه الكيبورد: يختفي الحقل وزرّه معاً.
///
/// نوافذ أخرى في التطبيق تعالج هذا بسطر مكتوب داخل كل ملف
/// (`admin_products_screen` و`admin_banners_screen` و`login_modal_sheet`
/// …) — هذا الملف يجمع نفس الحساب في مصدر واحد دون أن يغيّر ما سبق،
/// وتستخدمه حالياً «السلة» عند كتابة كود الخصم.
class KeyboardSheet {
  const KeyboardSheet._();

  /// ما يستهلكه الشيت نفسه خارج المساحة المخصصة لمحتواه:
  /// حشوة علوية 20 + حشوة سفلية 20 + هامش أمان أعلى الشاشة 24.
  /// يضمن هذا الثابت أن `maxHeight + keyboard + chrome` لا يتجاوز الشاشة.
  static const double chromeHeight = 64;

  /// أصغر ارتفاع يبقى للشيت: حين يبتلع الكيبورد معظم الشاشة نفضّل
  /// شيتاً قصيراً قابلًا للتمرير على شيت بلا محتوى ظاهر.
  static const double minContentHeight = 240;

  /// أكبر ارتفاع لمحتوى الشيت حين لا كيبورد: حتى لا يملأ الشاشة كلها
  /// على الأجهزة الكبيرة ويترك المستخدم يبحث عن زر الإرسال.
  static const double maxContentHeight = 640;

  /// الحشوة السفلية التي ترفع محتوى الشيت فوق الكيبورد. تُستعمل في
  /// `EdgeInsets` بدل `const EdgeInsets` لأن مقدار الكيبورد متغيّر.
  static double bottomInset(double keyboardInset) =>
      keyboardInset < 0 ? 0 : keyboardInset;

  /// أقصى ارتفاع لمحتوى الشيت بعد خصم الكيبورد — يُمَرَّر إلى
  /// `ConstrainedBox(maxHeight:)` داخل `SingleChildScrollView`، فيبقى
  /// الحقل المرشّح داخل المساحة الظاهرة وقابلاً للتمرير إليها.
  static double maxHeight({
    required Size screenSize,
    required double keyboardInset,
  }) {
    final double available =
        screenSize.height - bottomInset(keyboardInset) - chromeHeight;
    double result = available;
    if (result > maxContentHeight) result = maxContentHeight;
    if (result < minContentHeight) result = minContentHeight;
    return result;
  }

  /// ★ القاعدة (تُختبر في `test/keyboard_sheet_test.dart`): ما دام
  ///   الكيبورد أصغر من المساحة المتبقية، فمجموع الشيت لا يتجاوز
  ///   ارتفاع الشاشة ⇒ لا شيء يُدفع خلف الكيبورد أو خارج الشاشة.
  static bool fitsScreen({
    required Size screenSize,
    required double keyboardInset,
  }) {
    if (keyboardInset + chromeHeight > screenSize.height - minContentHeight) {
      // الكيبورد أكبر من المتاح: القاعدين يُرجعان للحد الأدنى عمداً.
      return false;
    }
    return maxHeight(screenSize: screenSize, keyboardInset: keyboardInset) +
            bottomInset(keyboardInset) +
            chromeHeight <=
        screenSize.height + 0.001;
  }
}
