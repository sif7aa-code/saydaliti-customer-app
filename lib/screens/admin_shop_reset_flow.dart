import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../services/admin_password_session.dart';
import '../services/supabase_service.dart';

/// نتيجة محاولة التصفير.
///
/// * [done] — هل مضت المحاولة فعليًا (لم يُلغِها الأدمن ولم تَقف عند كلمة
///   ناقصة). لا تُستعمل إلا لإخفاء/إظهار رسالة.
/// * [ok] — الخادم نفّذ التصفير؛ بعدها تُعاد قراءة الأرقام.
class AdminShopResetResult {
  const AdminShopResetResult({
    required this.done,
    required this.ok,
    this.message = '',
  });

  final bool done;
  final bool ok;
  final String message;
}

/// ★ تصفير **صيدلية واحدة** من لوحة الأدمن — بطلب واحد يفعل كل شيء:
///
///   • يسجّل «دفعة» بقيمة المستحق فيصير **المبلغ صفراً** (لا يُحذف سجل)،
///   • ينقل **خط أساس ذلك الصيدلية** إلى الآن ⇒ أرقام بطاقته
///     «طلبات / مكتملة / أرباح (علامة الدولار)» تصير **صفرًا فورًا**،
///   • **«منتجات» لا يُمَس**: يبقى عدّاد المنتجات الحيّ الذي يتغيّر عند الحذف.
///
/// المنطق كله في `public.admin_reset_shop_balance` (ملف
/// `SQL_SHOP_WALLET_FULL_RESET.sql` + عرض `v_shop_owner_stats`)، وهذه الدالة
/// هي الطريق الوحيد إليها من اللوحة: تستعملها بطاقة الصيدلية في «أصحاب الصيدليات»
/// (تصفير مباشر بلا الدخول للصيدلية) وشاشة تفاصيل الصيدلية (زر المحفظة) —
/// **سلوك واحد لا نسختان** تتباعدان مع كل تعديل.
///
/// كلمة اللوحة/التذكرة: تُكتب مرة واحدة لكل فتح للتطبيق
/// (`AdminPasswordSession.cached`)، فلا تُطلب ثانية بعد كل تصفير.
Future<AdminShopResetResult> adminResetShopBalance(
  BuildContext context, {
  required String phone,
  required String shopName,
  required double balance,
}) async {
  if (phone.isEmpty) {
    return const AdminShopResetResult(
      done: false,
      ok: false,
      message: 'لا رقم هاتف لهذا الحساب',
    );
  }

  final net = balance > 0 ? balance : 0.0;
  final cachedPw = AdminPasswordSession.cached;
  final hasCached = (cachedPw ?? '').isNotEmpty;
  final pwCtrl = TextEditingController();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'تصفير رصيد الصيدلية',
        style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            net > 0
                ? '«$shopName»\n\nسيُسجَّل أنك دفعت ${CurrencyFormatter.format(net)} '
                    'فيصبح الرصيد صفراً، وتُصفَّر معه أرقام البطاقة '
                    '(طلبات / مكتملة / علامة الدولار) في نفس اللحظة.\n'
                    'لا يُحذف أي سجل من الدفتر — تبقى معرفة كم استحق الصيدلية '
                    'وكم دُفع له، و«منتجات» يبقى عددًا حيًّا.'
                : '«$shopName»\n\nالرصيد صفر أصلاً، فلا مبلغ يُسجَّل — '
                    'لكن أرقام البطاقة (طلبات / مكتملة / علامة الدولار) '
                    'تعود إلى الصفر من هذه اللحظة، ويبقى «منتجات» حيًّا.',
            style: GoogleFonts.cairo(fontSize: 13, height: 1.6),
          ),
          // ★ حقل الكلمة يظهر فقط إن لم تكن محفوظة لهذه الجلسة.
          if (!hasCached) ...[
            const SizedBox(height: 14),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'كلمة مرور الأدمن',
                labelStyle: GoogleFonts.cairo(),
                border: const OutlineInputBorder(),
              ),
              style: GoogleFonts.cairo(),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('إلغاء', style: GoogleFonts.cairo()),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          child: Text('تصفير', style: GoogleFonts.cairo()),
        ),
      ],
    ),
  );

  if (confirmed != true) {
    pwCtrl.dispose();
    return const AdminShopResetResult(done: false, ok: false);
  }

  final password = hasCached ? cachedPw! : pwCtrl.text.trim();
  pwCtrl.dispose();
  if (password.isEmpty) {
    return const AdminShopResetResult(
      done: false,
      ok: false,
      message: 'كلمة مرور الأدمن مطلوبة',
    );
  }
  if (!hasCached) AdminPasswordSession.remember(password);

  final res = await SupabaseService.instance
      .adminResetShopBalance(phone, password);

  if (res == null) {
    return const AdminShopResetResult(
      done: true,
      ok: false,
      message: 'تعذّر الاتصال أو الدالة غير مُثبَّتة على الخادم',
    );
  }
  if (res['ok'] != true) {
    return AdminShopResetResult(
      done: true,
      ok: false,
      message: '${res['error'] ?? res['message'] ?? 'تعذّر التصفير'}',
    );
  }

  final paid = (res['reset_amount'] as num?)?.toDouble() ?? 0;
  return AdminShopResetResult(
    done: true,
    ok: true,
    message: paid > 0
        ? 'تم التصفير — سُجّلت دفعة ${CurrencyFormatter.format(paid)} '
            'وصفّرت الأرقام'
        : 'تم التصفير — صفّرت الأرقام (الرصيد كان صفرًا)',
  );
}
