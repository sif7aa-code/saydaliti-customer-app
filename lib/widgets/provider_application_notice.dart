import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../screens/provider_reapply_screen.dart';
import '../services/auth_service.dart';
import '../services/supabase_service.dart';

/// بطاقة حالة طلب الانضمام كطبيب/ممرض/صيدلاني لصاحب الحساب:
/// تُظهر «قيد المراجعة» أو «مرفوض» مع سبب الرفض الذي كتبه الأدمن.
/// تختفي تماماً لحساب بلا طلب أو طلب معتمد (المعتمد صار له واجهة دوره).
class ProviderApplicationNotice extends StatefulWidget {
  const ProviderApplicationNotice({
    super.key,
    this.padding = EdgeInsets.zero,
    this.reloadTick = 0,
  });

  /// تُزاد بعد إرسال طلب جديد من أي بطاقة، فيُعاد جلب الحالة في كل
  /// المواضع المعروضة بلا انتظار تحديث يدوي.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void notifyChanged() => revision.value++;

  /// هامش خارجي (تُستدعى البطاقة من صفحات بلا هوامش موحّدة).
  final EdgeInsetsGeometry padding;

  /// رقم يتغيّر من الشاشة الأم عند السحب/لمس التبويب لإعادة الجلب.
  final int reloadTick;

  @override
  State<ProviderApplicationNotice> createState() =>
      _ProviderApplicationNoticeState();
}

class _ProviderApplicationNoticeState extends State<ProviderApplicationNotice> {
  Map<String, dynamic>? _app;
  String? _boundPhone;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_onAuthChanged);
    ProviderApplicationNotice.revision.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(covariant ProviderApplicationNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadTick != widget.reloadTick) _load();
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    ProviderApplicationNotice.revision.removeListener(_load);
    super.dispose();
  }

  void _onAuthChanged() {
    final phone = AuthService.instance.phone;
    if (phone != _boundPhone) _load();
  }

  Future<void> _openReapply() async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ProviderReapplyScreen()),
    );
    if (sent == true && mounted) _load();
  }

  Future<void> _load() async {
    final phone = AuthService.instance.phone;
    _boundPhone = phone;
    if (phone == null || phone.isEmpty) {
      if (mounted && _app != null) setState(() => _app = null);
      return;
    }
    final app = await SupabaseService.instance.myProviderApplication();
    if (!mounted) return;
    setState(() => _app = app);
  }

  static String _text(Object? v) => (v ?? '').toString().trim();

  static String _professionLabel(String category) => switch (category) {
        'doctor' => 'طبيب',
        'pharmacist' => 'صيدلاني',
        'nurse' => 'ممرض',
        _ => 'مزوّد خدمة',
      };

  static String _date(Object? v) {
    final raw = _text(v);
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '';
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final status = _text(app?['status']);
    if (app == null || (status != 'rejected' && status != 'pending')) {
      return const SizedBox.shrink();
    }

    final rejected = status == 'rejected';
    final category = _text(app['category']);
    final label = _professionLabel(category);
    final stamp = rejected
        ? _date(app['reviewed_at'])
        : _date(app['created_at']);
    final reason = _text(app['admin_note']);
    final appliedPhone = _text(app['phone']).isEmpty
        ? _text(AuthService.instance.phone)
        : _text(app['phone']);

    final accent = rejected ? AppColors.danger : AppColors.warning;
    final surface =
        rejected ? AppColors.dangerLight : const Color(0xFFFFF7E6);

    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                rejected
                    ? Icons.gpp_bad_rounded
                    : Icons.hourglass_top_rounded,
                color: accent,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rejected
                          ? 'رُفض طلب الانضمام كـ$label'
                          : 'طلب الانضمام كـ$label قيد المراجعة',
                      style: GoogleFonts.cairo(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        height: 1.5,
                        color: rejected
                            ? AppColors.danger
                            : AppColors.textPrimary,
                      ),
                    ),
                    if (stamp.isNotEmpty)
                      Text(
                        rejected ? 'تاريخ الرفض: $stamp' : 'أُرسل في: $stamp',
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    if (appliedPhone.isNotEmpty)
                      Text(
                        'رقم الهاتف المسجَّل في الطلب: $appliedPhone',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: accent.withValues(alpha: 0.4)),
                ),
                child: Text(
                  rejected ? 'مرفوض' : 'قيد المراجعة',
                  style: GoogleFonts.cairo(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          if (rejected) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'سبب الرفض',
                    style: GoogleFonts.cairo(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                      color: AppColors.danger,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    reason.isEmpty
                        ? 'لم يُذكر سبب محدد — تواصل مع إدارة التطبيق.'
                        : reason,
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.7,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openReapply,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(
                  'إعادة التقديم',
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: widget.padding,
      child: rejected
          ? GestureDetector(
              onTap: _openReapply,
              behavior: HitTestBehavior.opaque,
              child: card,
            )
          : card,
    );
  }
}
