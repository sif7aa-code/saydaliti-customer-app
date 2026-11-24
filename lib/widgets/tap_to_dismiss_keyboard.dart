import 'package:flutter/material.dart';

/// ★ يغلّف واجهة فيها حقل بحث: أي نقرة في أي مكان خارج الحقل تُخفي
/// لوحة المفاتيح (وتُنهي تركيز الحقل) — بلا زر «إلغاء» ولا سحب.
///
/// لماذا `GestureDetector` وليس `Listener`؟ الـ`Listener` يستقبل كل نقرة
/// وينشرها، فتشمله النقرة **داخل** حقل البحث نفسه — فيُغلق الكيبورد لحظة
/// فتحه. أما هنا فيخسر هذا الكاشف المعركة أمام حقل النص حين تكون النقرة
/// داخله (`HitTestBehavior.translucent` تسمح بوصول النقر إلى الأزرار
/// والبطاقات تحت الطبقة)، فتنطبق القاعدة فقط على النقر «في أي مكان آخر».
///
/// لا يغيّر أي شكل: طبقة شفافة بلا خلفية ولا ظل ولا قيود.
class TapToDismissKeyboard extends StatelessWidget {
  const TapToDismissKeyboard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) {
        final focus = FocusManager.instance.primaryFocus;
        // لا شيء مركّز = لا شيء يُخفى (لا ضريبة على كل نقرة).
        if (focus == null || !focus.hasFocus) return;
        // النقرة داخل حقل النص تركّه كما هو (الحقل يفوز بها أصلاً).
        debugPrint('KEYBOARD_DISMISS');
        focus.unfocus();
      },
      child: child,
    );
  }
}
