import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../screens/admin_dashboard_screen.dart';
import 'admin_password_session.dart';
import 'auth_service.dart';
import 'supabase_service.dart';

/// ★★ بوابة فتح لوحة تحكم الأدمن — انتقلت كاملة من «حسابي» إلى هنا
///   (2026-10-11) حين صارت اللوحة تطبيقاً منفصلاً (`lib/main_admin.dart`).
///
/// **لماذا ملف خدمة مستقل؟**
///   لأن بناء الزبائن يجب ألّا يحوي اللوحة إطلاقاً: أدوات Flutter تُسقط
///   من `libapp.so` أي مكتبة لا يصلها ملف الدخول. `main.dart` (الزبائن) لا
///   يشير هذا الملف ولا `admin_dashboard_screen`، فلا تدخل اللوحة إلى نسخة
///   الزبائن — بينما يستدعيها `main_admin.dart` عبر هذه البوابة بنفس
///   المنطق حرفياً.
///
/// المنطق نفسه لم يتغيّر ولا سطر من شروطه: تذكرة محفوظة ⇒ تُفتح اللوحة،
/// مع فحص صامت واحد في القاعدة لكل فتح تطبيق؛ انقطاع شبكة ⇒ يبقى ثقة
/// الجهاز؛ رفض مؤكّد ⇒ تُمسح وتُطلب الكتابة من جديد.
class AdminPanelGate {
  AdminPanelGate._();

  /// ★★ بوابة الفتح قبل لوحة التحكم.
  ///
  /// ★ هذه **ليست** كلمة مرور الحساب: نطلب كلمة `admin_secret` (كلمة فتح
  ///   اللوحة) نفحصها على القاعدة، ثم — منذ حماية اللوحة من السرقة
  ///   (2026-10-10) — تُبدَّل في القاعدة **تذكرةَ جلسة** (`admin_panel_login`)
  ///   هي ما يبقى على الجهاز، لا الكلمة. استدعاء `verifyLogin` هنا كان يجعل
  ///   كلمة مرور أي حساب يفتح اللوحة — وهذا ما أصلحناه.
  ///
  ///   الفصل مقصود: كلمة الدخول إلى التطبيق شيء، ومفتاح اللوحة شيء آخر،
  ///   وتغيير إحداهما لا يمسّ الأخرى.
  ///
  /// منفصلة عن تسجيل الدخول عمداً: من تبقى جلسته على جهاز آخر لا
  /// يستطيع فتح اللوحة إلا بالمفتاح.
  /// ★ الثقة بالأدمن: كلمة الفتح تُكتب **مرة واحدة**، ثم تُكتب تذكرتها
  ///   وتبقى على الجهاز (بتمويه) بعد إغلاق التطبيق — فلا سؤال بعد قفل
  ///   الهاتف وفتحه. تُتحقق منها هنا بصمت مرة واحدة لكل فتح: انتهت أو
  ///   سُحب الدور أو تغيّرت الكلمة في القاعدة ⇒ تُمسح وتُطلب الكتابة من
  ///   جديد، وتُمسح عند تسجيل الخروج.
  static Future<void> open(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final phone = AuthService.instance.phone ?? '';

    final remembered = AdminPasswordSession.cached;
    if (remembered != null && remembered.isNotEmpty) {
      // ★ قيمة جاءت من القرص (فتح تطبيق سابق) ولم تُتحقق في هذا الفتح:
      //   نفحصها في القاعدة **بصمت مرة واحدة**. تنجح ⇒ تُفتح اللوحة بلا
      //   سؤال. تُرفض ⇒ انتهت التذكرة أو تغيّرت الكلمة في القاعدة، فننساها
      //   ونسأل صاحبها.
      // ★ التذكرة لا تُمرَّر أبداً كبوابة كلمة: `unlockAdminPanel` يميّز
      //   الشكلين، فتمرير تذكرة إلى `admin_panel_password_ok` كان يحسبها
      //   محاولة فاشلة ويقفل الحساب بعد خمس.
      if (AdminPasswordSession.needsServerCheck) {
        final check = await SupabaseService.instance.unlockAdminPanel(
          phone,
          remembered,
        );
        if (check['ok'] == true) {
          final t = check['ticket'];
          if (t is String && AdminPasswordSession.isTicket(t)) {
            // ★ الكلمة اختفت من القرص وحلت مكانها التذكرة.
            AdminPasswordSession.promoteToTicket(t);
          } else {
            AdminPasswordSession.markVerified();
          }
        } else if (check['offline'] == true) {
          // ★ انقطاع شبكة لا يُنسي ما عند الجهاز: كان السلوك السابق كذلك،
          //   ونُبقيه حتى لا يُطلب إعادة الكتابة عند كل تقطيع.
          AdminPasswordSession.markVerified();
        } else {
          // رفض مؤكَّد: انتهت التذكرة أو تغيّرت الكلمة في القاعدة.
          AdminPasswordSession.clear();
        }
        if (!context.mounted) return;
        if (!AdminPasswordSession.hasPassword) {
          // رُفضت ⇒ نكمل إلى النافذة أدناه فيُعيد الكتابة.
        } else {
          navigator.push(
            MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
          );
          return;
        }
      } else {
        navigator.push(
          MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
        );
        return;
      }
    }

    final password = await _askAdminPanelPassword(context);
    if (password == null || !context.mounted) return;
    if (password.isEmpty) return;

    final result = await SupabaseService.instance.unlockAdminPanel(
      phone,
      password,
    );
    if (!context.mounted) return;

    if (result['ok'] != true) {
      final message = (result['message'] ?? 'تعذّر الاتصال بالخادم').toString();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              message,
              style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.danger,
          ),
        );
      // ★ البوابة لا تُبطل جلسة المستخدم: كلمة خاطئة هنا تعني فقط منع
      //   الفتح. (السابق كان يُخرج المستخدم من حسابه بالكامل.)
      return;
    }

    // ★ ما نحفظه هو **ما أعطتنا القاعدة**: تذكرة جلسة إن كانت مثبّتة،
    //   وإلا الكلمة نفسها (فترة ما قبل تنفيذ SQL) — فتُكتب مرة واحدة ولا
    //   تُطلب بعد إغلاق التطبيق.
    final ticket = result['ticket'];
    if (ticket is String && AdminPasswordSession.isTicket(ticket)) {
      AdminPasswordSession.promoteToTicket(ticket);
    } else {
      AdminPasswordSession.remember(password);
    }

    if (!context.mounted) return;
    navigator.push(
      MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
    );
  }

  /// نافذة إدخال كلمة المرور. تعيد `null` عند الإلغاء.
  static Future<String?> _askAdminPanelPassword(BuildContext context) {
    final ctrl = TextEditingController();
    var obscure = true;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'كلمة فتح اللوحة',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'أدخل كلمة فتح لوحة التحكم.',
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                autofocus: true,
                obscureText: obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (v) => Navigator.pop(ctx, v),
                decoration: InputDecoration(
                  labelText: 'كلمة المرور',
                  prefixIcon: const Icon(Icons.key_rounded, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 20,
                    ),
                    tooltip: obscure ? 'إظهار' : 'إخفاء',
                    onPressed: () => setDlgState(() => obscure = !obscure),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'كلمة فتح اللوحة — منفصلة عن كلمة مرور حسابك.',
                style: GoogleFonts.cairo(
                  fontSize: 10.5,
                  color: AppColors.textHint,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إلغاء', style: GoogleFonts.cairo()),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: Text(
                'فتح',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
