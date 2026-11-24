import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/order_display.dart';
import '../core/utils/session_gate.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import '../widgets/location_map_picker.dart';

/// طلب مندوب حر: يرسل الزبون طلب توصيل شخصي بدون منتجات، ويصل الطلب
/// للمندوبين فقط تحت وسم #طلب_مندوب مع ملاحظات الزبون وموقعه.
class FreeDriverRequestScreen extends StatefulWidget {
  const FreeDriverRequestScreen({super.key});

  @override
  State<FreeDriverRequestScreen> createState() =>
      _FreeDriverRequestScreenState();
}

class _FreeDriverRequestScreenState extends State<FreeDriverRequestScreen> {
  static const String hashtag = '#طلب_مندوب';

  final TextEditingController _notesCtrl = TextEditingController();
  final FocusNode _notesFocus = FocusNode();

  bool _locating = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // تحديد الموقع تلقائياً عند فتح الشاشة (الموقع محفوظ مسبقاً عادةً).
    WidgetsBinding.instance.addPostFrameCallback((_) => _detectLocation());
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  Future<void> _detectLocation({bool manual = false}) async {
    if (_locating) return;
    setState(() => _locating = true);
    await LocationService.instance.determinePosition(overridePin: manual);
    if (!mounted) return;
    setState(() => _locating = false);
  }

  /// ★ منتقي الخريطة: الدبوس + «تأكيد موقعي» ثم يُعرض العنوان فوراً.
  ///   `LocationService` صار مصدر الحقيقة للإحداثيات، فلا السطر أعلاه
  ///   ولا `_send()` يحتاجان نسخة محلية من الموقع.
  Future<void> _pickOnMap() async {
    final ok = await LocationMapPicker.open(context);
    if (!ok || !mounted) return;
    setState(() {});
  }

  Future<void> _send() async {
    // ★ الدخول إجباري: لا يصل طلب مندوب بلا حساب، وتُفتح شاشة الدخول
    //   ثم يكمل الإرسال تلقائياً بعد النجاح.
    if (!hasAppSession) {
      pushAppLogin(context, onSuccess: () {
        _send();
      });
      return;
    }
    final phone = AuthService.instance.phone!;
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });

    // إعادة تحديد الموقع لحظة الإرسال لضمان وصول المندوب لنفس المكان.
    // ★ `overridePin: false` الضمني مقصود: السؤال الآن ليس «أين أنت؟» بل
    //   «إلى أين يأتي المندوب؟» — فمن ثبّت دبوسه على الخريطة قال مكانه
    //   بيدِه، ولو أعدنا GPS هنا لمحونا اختياره في لحظة الإرسال.
    await LocationService.instance.determinePosition();

    final note = _notesCtrl.text.trim();
    final notes = note.isEmpty ? hashtag : '$hashtag · $note';

    final order = await SupabaseService.instance.createOrder(
      orderNumber: OrderDisplay.newOrderTag(),
      userPhone: phone,
      userName: AuthService.instance.name,
      totalAmount: 0,
      deliveryFee: 0,
      address: LocationService.instance.currentAddress,
      latitude: LocationService.instance.currentLat,
      longitude: LocationService.instance.currentLng,
      notes: notes,
      isFreeDriverRequest: true,
    );

    if (!mounted) return;
    setState(() => _sending = false);
    if (order == null) {
      final reason = SupabaseService.instance.lastOrderError ?? 'بلا تفاصيل';
      _fail('تعذر إرسال الطلب: $reason');
      return;
    }
    await _showSentDialog(order);
    if (!mounted) return;
    // ★ 2026-10-26 — جذر «الشاشة السوداء» عند صاحب الصيدلية:
    //   هذه الشاشة تُدفع من الرئيسية عند الزبون (`Navigator.push`) فـ`pop`
    //   يرجعه إليها. أما في `ShopOwnerShell` فهي **تبويب** داخل
    //   `IndexedStack`، و`ShopOwnerShell` نفسه محتوى مسار `home` في
    //   `MaterialApp` — فـ`pop` يفرّغ الملاح كله ويرمي **شاشة سوداء**.
    //   `canPop()` هو الفاصل الآمن: لا دفعة قبل `home`.
    if (!Navigator.of(context).canPop()) {
      // التبويب يبقى مفتوحاً: تُفرَّغ الملاحظات فقط حتى لا يُرسل نفس
      // الكلام مرتين، والطلب نفسه صار عند المندوبين.
      _notesCtrl.clear();
      return;
    }
    Navigator.of(context).pop(true);
  }

  void _fail(String msg) {
    setState(() => _error = msg);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, textAlign: TextAlign.center),
          backgroundColor: AppColors.danger,
        ),
      );
  }

  Future<void> _showSentDialog(Map<String, dynamic> order) async {
    final serial = OrderDisplay.serial(order);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        icon: const Icon(
          Icons.pan_tool_alt_rounded,
          color: AppColors.primary,
          size: 42,
        ),
        title: Text(
          'تم إرسال طلبك للمندوبين',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                hashtag,
                style: GoogleFonts.cairo(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'سيصل طلبك للمندوبين القريبين منك، وسيتصل بك أقرب مندوب '
              'لتأكيد التفاصيل.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
            if (serial != '#---') ...[
              const SizedBox(height: 8),
              Text(
                'رقم طلبك: $serial',
                style: GoogleFonts.cairo(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('تم'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = LocationService.instance;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('طلب مندوب'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1) شرح مختصر + الهاشتاك
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'تحتاج مندوب توصيل فقط؟',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'اكتب ما تحتاجه وسيظهر طلبك للمندوبين فوراً مع موقعك. '
                  'الملاحظات اختيارية.',
                  style: GoogleFonts.cairo(
                    fontSize: 12.5,
                    height: 1.6,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    hashtag,
                    style: GoogleFonts.cairo(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 2) الموقع: يُحدَّد تلقائياً
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      _locating
                          ? Icons.location_searching_rounded
                          : Icons.location_on_rounded,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loc.manualPinActive
                                ? 'موقعك المثبّت على الخريطة'
                                : (_locating
                                      ? 'جاري تحديد موقعك...'
                                      : 'موقعك الحالي'),
                            style: GoogleFonts.cairo(
                              fontWeight: FontWeight.w800,
                              fontSize: 12.5,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            loc.currentAddress,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 11.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _locating
                          ? null
                          : () => _detectLocation(manual: true),
                      child: Text(
                        'تحديث',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                // ★ نفس الخريطة التي يراها الزبون في السلة: دبوس + تأكيد.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _locating ? null : _pickOnMap,
                    icon: const Icon(Icons.pin_drop_rounded, size: 18),
                    label: Text(
                      'حدد موقعي على الخريطة',
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.45),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // 3) ملاحظات اختيارية
          TextField(
            controller: _notesCtrl,
            focusNode: _notesFocus,
            maxLines: 4,
            minLines: 3,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              labelText: 'ملاحظاتك (اختياري)',
              hintText: 'مثال: أحتاج مندوب لزيارة عنواني وإنجاز مهمة.',
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(14),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  color: AppColors.danger,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: GoogleFonts.cairo(
                      color: AppColors.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send_rounded, size: 20),
            label: Text(
              _sending ? 'جاري الإرسال...' : 'إرسال طلب المندوب',
              style: GoogleFonts.cairo(
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'ملاحظة: يظهر هذا الطلب للمندوبين فقط، ولا يظهر في طلبات الصيدليات.',
            textAlign: TextAlign.center,
            style: GoogleFonts.cairo(fontSize: 11, color: AppColors.textHint),
          ),
        ],
      ),
    );
  }
}
