import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/order_duplicates.dart';

/// ★ **لوحة الطلبات المكررة عند المندوبين** — أعلى «مراقبة الطلبات».
///
/// ## كيف تُقرأ هذه اللوحة (ترتيبها وتمييزها)
/// - **الأخطر أولاً**: مجموعة فيها نسخة «مكتمل» (دُفع ثمنها فعلاً وتحتاج
///   تسوية) قبل «في الطريق» قبل «مقبول» قبل المرفوض/الملغى — ثم الأكثر
///   نسخاً، ثم الأحدث (`OrderDuplicates.sortGroups`).
/// - **كل مجموعة بطاقة مرقّمة** «م1، م2…» بأرقام لاتينية تُقرأ بلا خلط،
///   فلو ظهرت بطاقات متشابهة يشير إليها الأدمن برقمها لا بـ«الثانية».
/// - **التمييز لوناً وكلمة**: الأساس سطر أخضر بشارة «الأساس»، وكل نسخة
///   بعده سطر أحمر بشارة «مكرر» + رقم نسختها، مع مفتاح ألوان في الرأس.
/// - **سطران مرتّبان لكل نسخة** بدل نص طويل موصول بنقاط: الأول «الأول:
///   #5 · اسم المندوب · رقمه»، والثاني الوقت والحالة في شارات.
///
/// مكوّن مستقل بلا حالة: قائمة المجموعات تُحسب في الشاشة
/// (`OrderDuplicates.find`)، وهو يُبلَّغ بالعرض الكامل وبضغط أي سطر.
/// لماذا مستقلاً؟ حتى يمكن إظهاره في معاينة محلية واختباره كاختبار
/// واجهة بلا شبكة ولا قاعدة، فيُرى شكله قبل أن يُركَّب على هاتف.
///
/// ★ يختفي تماماً (`SizedBox.shrink`) حين لا تكرار، فلا سطر فراغ ولا
///   «لا شيء» يزعج الأدمن.
/// ★ بلا ظل ولا خلفية رمادية (قاعدة الخلفية المسطّعة في المنصة):
///   اللوحة تدرّج أحمر خفيف، وكل بطاقة بيضاء بحدّ يميّزها.
class DuplicateOrdersPanel extends StatelessWidget {
  const DuplicateOrdersPanel({
    super.key,
    required this.groups,
    required this.expanded,
    required this.onToggle,
    required this.statusLabel,
    this.onOpenReceipt,
    this.visibleLimit = 3,
  });

  final List<DuplicateGroup> groups;

  /// هل تُعرض كل المجموعات أم [visibleLimit] فقط؟
  final bool expanded;
  final ValueChanged<bool> onToggle;

  /// ترجمة حالة الطلب إلى كلمة عربية — تمرَّر من الشاشة حتى يبقى
  /// مصدر التسمية واحداً لا نسخة ثانية تختلف لوناً أولفظاً.
  final String Function(String status) statusLabel;

  final void Function(DuplicateReceipt receipt)? onOpenReceipt;

  /// عدد المجموعات الظاهرة قبل زر «عرض البقية».
  final int visibleLimit;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) return const SizedBox.shrink();

    final shown = expanded
        ? groups
        : groups.take(visibleLimit).toList(growable: false);
    final hidden = groups.length - shown.length;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 4),
          Text(
            'نفس الزبون ونفس السلة خلال ست ساعات، والنسخ عند مندوبين '
            'مختلفين. الأخطر أولاً: ما اكتمل تسليمه ثم ما هو في الطريق.',
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          _legend(),
          const SizedBox(height: 8),
          // ★ الارتفاع محدود والقائمة داخله قابلة للتمرير: التحذير يجب
          //   ألّا يبتلع الشاشة ويدفن قائمة الطلبات، حتى لو كثر التكرار.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.3,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < shown.length; i++)
                    _groupCard(shown[i], number: i + 1),
                ],
              ),
            ),
          ),
          // ★ زرّا التوسيع والتقليص **خارج** الحد المحدود: داخل القائمة
          //   كانتا يختفيان خلف التمرير حين تكون المكررات كثيرة — فيظنّ
          //   الأدمن أنه لا مزيد. خارجها يبقيان مرئيين دائماً.
          if (hidden > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => onToggle(true),
                child: Text(
                  'عرض البقية ($hidden)',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          if (hidden == 0 && groups.length > visibleLimit && expanded)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => onToggle(false),
                child: Text(
                  'تقليص',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// الرأس: إنذار + عدّاد المجموعات + كلمة واحدة عن السبب.
  Widget _header() {
    return Row(
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 22,
          color: AppColors.danger,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'تنبيه: طلب مكرر عند أكثر من مندوب',
            style: GoogleFonts.cairo(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: AppColors.danger,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.danger,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${groups.length}',
            style: GoogleFonts.cairo(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  /// مفتاح الألوان: حتى لا يُحسب الأحمر أساساً أو الأخضر مكرراً.
  Widget _legend() {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _chip(label: 'الأساس', foreground: AppColors.success, filled: true),
        Text(
          'أول من استلم السلّة، وهو الأساس للمقارنة',
          style: GoogleFonts.cairo(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
        _chip(label: 'مكرر', foreground: AppColors.danger, filled: true),
        Text(
          'كل نسخة بعده عند مندوب آخر — تُراجَع قبل التسوية',
          style: GoogleFonts.cairo(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  /// بطاقة مجموعة واحدة: رأس بالزبون والحصيلة، ثم سطور النسخ.
  Widget _groupCard(DuplicateGroup g, {required int number}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _numberBadge(number),
              const SizedBox(width: 7),
              Expanded(child: _groupTitle(g)),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            'عدد المستلِمين ${g.receipts.length} · سلة '
            '${CurrencyFormatter.format(g.basketAmount)}',
            style: GoogleFonts.cairo(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          _receiptRow(g.receipts.first, isFirst: true, index: 1),
          for (var i = 1; i < g.receipts.length; i++)
            _receiptRow(g.receipts[i], isFirst: false, index: i + 1),
        ],
      ),
    );
  }

  /// رقم المجموعة في مربّع أخضر هادئ — مرجع سريع عند التخاطب.
  Widget _numberBadge(int number) {
    return Container(
      width: 27,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Text(
        // «م1» — رقم المجموعة، للتخاطب والإشارة بلا لبس مع عدّاد الرأس.
        'م$number',
        style: GoogleFonts.cairo(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: AppColors.primary,
        ),
      ),
    );
  }

  /// سطر الزبون وحده: الاسم بارز والرقم إلى جواره، بلا حشو عن الأرقام.
  Widget _groupTitle(DuplicateGroup g) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: g.customerName,
            style: GoogleFonts.cairo(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          TextSpan(
            text: '  ${g.customerPhone}',
            style: GoogleFonts.cairo(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textHint,
            ),
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// نسخة واحدة: شارة التمييز، ثم سطر الهوية وسطر الوقت والحالة.
  Widget _receiptRow(
    DuplicateReceipt r, {
    required bool isFirst,
    required int index,
  }) {
    final color = isFirst ? AppColors.success : AppColors.danger;
    final label = isFirst ? 'الأول: ' : 'تكرر عند: ';
    final who = r.driverPhone.isEmpty
        ? r.driverName
        : '${r.driverName} · ${r.driverPhone}';
    final state = statusLabel(r.status);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onOpenReceipt == null ? null : () => onOpenReceipt!(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _chip(
              label: isFirst ? 'الأساس' : 'مكرر $index',
              foreground: color,
              filled: isFirst,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: label,
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        TextSpan(
                          text: '${r.serial} · $who',
                          style: GoogleFonts.cairo(
                            fontSize: 11.5,
                            fontWeight: isFirst
                                ? FontWeight.w900
                                : FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // ★ سطر الوقت والحالة: الوقت قابل للقصّ وشارة الحالة
                  //   محدودة العرض، فلا يتجاوز اسم حالة طويل حدود الصف.
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          OrderDuplicates.stampLabel(r),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.cairo(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textHint,
                          ),
                        ),
                      ),
                      if (state.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 132),
                          child: _chip(
                            label: state,
                            foreground: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// شارة مسطّحة بلا ظل: مملوءة للتمييز الأساسي، ومحدّدة للحالة.
  Widget _chip({
    required String label,
    required Color foreground,
    bool filled = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: filled ? foreground.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: foreground.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.cairo(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: foreground,
        ),
      ),
    );
  }
}
