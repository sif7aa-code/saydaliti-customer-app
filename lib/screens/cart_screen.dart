import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/currency_formatter.dart';
import '../core/utils/keyboard_sheet.dart';
import 'dart:async';

import '../core/utils/order_display.dart';
import '../core/utils/session_gate.dart';
import '../services/auth_service.dart';
import '../services/cart_service.dart';
import '../services/local_image_store.dart';
import '../services/location_service.dart';
import '../services/discount_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/app_image.dart';
import '../widgets/location_map_picker.dart';
import '../widgets/section_header.dart';
import '../widgets/shop_gate.dart';
import 'order_tracking_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen>
    // ★ `tabScroll` يكفيها: السلة صارت صفحة تُفتح من دائرة الرأس لا
    //   تبويباً في الشريط، فمعرّف 'cart' لم يعد يناديه أحد.
    with TabRefreshTarget<CartScreen> {
  @override
  String get tabId => 'cart';

  /// السلة محلية بالكامل (لا شبكة فيها)، فسحبها لإعادة العرض فقط —
  /// لا جلب ولا انتظار شبكة خلف المؤشر.
  @override
  Future<void> Function() onTabRefresh() => _onRefresh;

  String _selectedPaymentMethod = 'cash';
  final TextEditingController _notesCtrl = TextEditingController();

  // ★ كود الخصم — المبلغ يحسبه الخادم (check_discount_code)،
  //   والتطبيق لا يقرّر شيئاً. انظر DiscountService.
  final TextEditingController _discountCtrl = TextEditingController();
  bool _discountBusy = false;
  String _discountError = '';
  bool _discountApplied = false;
  String _discountCode = '';

  /// ★ الوصفة الطبية: تُرفع من ورقة الدفع عندما يحوي السلة صنفاً
  ///   `requiresPrescription`، وتُمرَّر مع الطلب. بلاها لا يُقبل الطلب
  ///   (بوابة هنا + تريجر في القاعدة يمنعان الإرسال بلا وصفة).
  String? _prescriptionUrl;
  bool _prescriptionUploading = false;

  @override
  void dispose() {
    _notesCtrl.dispose();
    _discountCtrl.dispose();
    super.dispose();
  }

  /// فحص الكود على الخادم وتطبيق ما حسبه.
  /// ★ نستقبل `setModalState` من الورقة: الحقل يعيش داخل
  /// `showModalBottomSheet` الذي له `StatefulBuilder` خاص. و`setState`
  /// للشاشة **لا يعيد بناء الورقة** — فالكود يُطبَّق على الخادم بنجاح
  /// ولا يتغيّر شيء أمام المستخدم ولا يتحدّث الإجمالي. علة حقيقية.
  Future<void> _applyDiscount(
    double subtotal,
    void Function(VoidCallback) setModalState,
  ) async {
    setState(() {
      _discountBusy = true;
      _discountError = '';
    });
    final res = await DiscountService.instance.applyCode(
      code: _discountCtrl.text,
      phone: AuthService.instance.phone ?? '',
      subtotal: subtotal,
      deliveryFee: CartService.instance.deliveryFee,
    );
    if (!mounted) return;
    setState(() {
      _discountBusy = false;
      _discountApplied = res.ok;
      _discountError = res.ok ? '' : res.message;
      if (res.ok) {
        _discountCode = res.code ?? _discountCtrl.text.trim();
        // ★ بعد القبول لا يبقى الكود «محفوظاً» في الحقل: الشريط
        //   الأخضر يعرضه، والحقل يعود فارغاً فوراً.
        _discountCtrl.clear();
      }
    });
    // ★ إعادة بناء الورقة والحقل والإجمالي معاً.
    setModalState(() {});
    if (res.ok) _toastCoupon(res.message);
  }

  void _clearDiscount(void Function(VoidCallback) setModalState) {
    DiscountService.instance.clear();
    setState(() {
      _discountApplied = false;
      _discountError = '';
      _discountCode = '';
      _discountCtrl.clear();
    });
    setModalState(() {});
  }

  /// ★ اختيار ورفع صورة الوصفة الطبية من ورقة الدفع.
  ///
  /// تُرفع إلى مجلد `prescriptions` في سلة الصور، ويُخزَّن رابطها في
  /// الطلب (`prescription_path`). تظهر الوصفة لصاحب الصيدلية وللأدمن
  /// فقط — المندوب لا يراها إطلاقاً.
  Future<void> _pickPrescription(
    void Function(VoidCallback) setModalState,
  ) async {
    final file = await LocalImageStore.instance.pickImage();
    if (file == null) return;
    setModalState(() => _prescriptionUploading = true);
    final url = await LocalImageStore.instance.uploadPicked(
      file,
      folder: 'prescriptions',
      maxWidth: 1200,
      quality: 80,
    );
    if (!mounted) return;
    setModalState(() {
      _prescriptionUploading = false;
      _prescriptionUrl = url;
    });
    if (url == null) {
      _showInfoDialog(
        'تعذّر رفع الوصفة',
        LocalImageStore.instance.lastUploadFailure,
      );
    }
  }

  void _toastCoupon(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.success,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
  }

  /// يضمن تحديد الموقع فعلياً قبل كل طلب جديد.
  Future<void> _ensureLocation() async {
    final loc = LocationService.instance;
    if (loc.currentLat != null && loc.currentLng != null) return;
    await loc.determinePosition();
  }

  /// ★ زيادة/إنقاص كمية داخل السلة يمرّ بنفس البوابة الزمنية: الصيدلية
  ///   المغلق لا تُزاد كميته صامتة — الرسالة تشرح متى يفتح.
  void _changeQuantity(BuildContext context, String productId, int delta) {
    final block = CartService.instance.updateQuantity(productId, delta);
    if (block != null) ShopGate.showBlocked(context, block);
  }

  void _showCheckoutBottomSheet(double totalWithDelivery) {
    // ★ حقل الكود لا يحفظ شيئاً: عند كل فتح نبدأ بحقل فارغ،
    //   والحالة الحقيقية تُقرأ من خدمة الخصم (مصدر الحقيقة):
    //   كود فعّال ⇒ شريط «مُفعّل»، ولا كود فعّال ⇒ حقل إدخال نظيف.
    final activeCode = DiscountService.instance.appliedCode ?? '';
    setState(() {
      _discountError = '';
      _discountCtrl.clear();
      _discountApplied = activeCode.isNotEmpty;
      _discountCode = activeCode;
    });
    // يمنع الضغط المتكرر على زر التأكيد (تكرار إرسال الطلب).
    var placingOrder = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalContext, setModalState) {
          // ★ الخصم يأتي من الخادم؛ ولا يُقبل من قيمة محلية.
          //   ثم يُقصّ عند سقف الفاتورة حتى لا يصبح الإجمالي سالباً،
          //   وهذا المقصوص — لا المعلن — هو «الخصم الفعلي» الذي
          //   يُحفظ في الطلب ويُعرض في «تفاصيل الطلب».
          final dc = DiscountService.instance;
          final discount = dc.discount > totalWithDelivery
              ? totalWithDelivery
              : dc.discount;
          final finalTotal = totalWithDelivery - discount;
          final fee = CartService.instance.deliveryFee;

          // ★★ الكيبورد لا يملأ الشاشة فوق الحقل.
          //   `showModalBottomSheet` لا يراعي `viewInsets` بنفسه (بخلاف
          //   `Dialog`)، فيبقى الشيت مثبتاً أسفل الشاشة ويغطي «كود
          //   الخصم» وزر «تطبيق». الحساب في `KeyboardSheet`: حشوة
          //   سفلية بمقدار الكيبورد + سقف ارتفاع للمحتوى في المساحة
          //   الظاهرة فقط.
          final keyboard = KeyboardSheet.bottomInset(
            MediaQuery.of(modalContext).viewInsets.bottom,
          );

          return Container(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + keyboard),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: KeyboardSheet.maxHeight(
                    screenSize: MediaQuery.sizeOf(modalContext),
                    keyboardInset: keyboard,
                  ),
                ),
                child: SingleChildScrollView(
                  // ★ سحب الإصبع يُخفي الكيبورد: الزر يبقى لمسه بعد الكتابة.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 44,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppColors.divider,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'تأكيد الطلب والدفع',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.cairo(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // عنوان التوصيل (يتم تحديده تلقائياً لحظة الطلب)
                      const _DeliveryAddressCard(),
                      const SizedBox(height: 16),

                      // ملاحظة التسعير الثابتة — بجانب السعر مباشرةً
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // ★ المبلغ يُعرض فقط عندما تكون الرسوم
                                  //   معروفة (> 0). حالياً الرسوم تُتفق
                                  //   مع المندوب، فعرض «0 د.ع» يوهم
                                  //   الزبون بأن التوصيل مجاني ثم يُفاجأ.
                                  if (fee > 0) ...[
                                    Row(
                                      children: [
                                        Text(
                                          'رسوم التوصيل: ',
                                          style: GoogleFonts.cairo(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w900,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          CurrencyFormatter.format(fee),
                                          style: GoogleFonts.cairo(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w900,
                                            color: AppColors.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                  ],
                                  Text(
                                    'سعر التوصيل حسب الاتفاق بينك وبين المندوب.',
                                    style: GoogleFonts.cairo(
                                      fontSize: 11.5,
                                      height: 1.55,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ملاحظات الزبون (اختياري)
                      // ★ 2026-10-26: طلب الأدمن حذف العنوان «ملاحظات للطلب
                      //   (اختياري)» وسطر الشرح الذي تحته — **المربع وحده
                      //   يبقى** ويعمل كما هو، ونصّه الداخلي يشرح غرضه.
                      TextField(
                        controller: _notesCtrl,
                        textAlign: TextAlign.right,
                        maxLines: 3,
                        maxLength: 200,
                        decoration: InputDecoration(
                          hintText: 'مثال: بدون بصل، اتصل قبل الوصول…',
                          hintStyle: GoogleFonts.cairo(
                            fontSize: 12,
                            color: AppColors.textHint,
                          ),
                          counterText: '',
                          filled: true,
                          fillColor: AppColors.surfaceTint.withValues(
                            alpha: 0.5,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ★ كود الخصم (من «خصوماتي»)
                      _DiscountCodeField(
                        controller: _discountCtrl,
                        busy: _discountBusy,
                        applied: _discountApplied,
                        appliedCode: _discountCode,
                        error: _discountError,
                        onApply: () => _applyDiscount(
                          CartService.instance.subtotal,
                          setModalState,
                        ),
                        onClear: () => _clearDiscount(setModalState),
                      ),
                      const SizedBox(height: 16),

                      // ★ الوصفة الطبية: تظهر هذه البطاقة فقط حين يحوي
                      //   السلة صنفاً `requiresPrescription` — وبدونها لا
                      //   يُقبل الطلب (بوابة تأكيد أدناه + تريجر في القاعدة).
                      if (CartService.instance.items.any(
                        (it) => it.product.requiresPrescription,
                      )) ...[
                        _PrescriptionCard(
                          url: _prescriptionUrl,
                          uploading: _prescriptionUploading,
                          onPick: () => _pickPrescription(setModalState),
                          onClear: () =>
                              setModalState(() => _prescriptionUrl = null),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // طرق الدفع
                      Text(
                        'طريقة الدفع',
                        style: GoogleFonts.cairo(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // ★ خيار واحد فقط للدفع: الكاش عند الاستلام.
                      //   «بطاقة مدى / فيزا» و«محفظة زين كاش» حُذفتا لأن
                      //   خدمتهما لم تُفعّل بعد — عرضهما يوهم الزبون بأنه
                      //   يستطيع الدفع بهما. تعودان عند تفعيل بوابتهما.
                      _PaymentOptionTile(
                        title: 'الدفع عند الاستلام (كاش)',
                        icon: Icons.payments_outlined,
                        isSelected: _selectedPaymentMethod == 'cash',
                        onTap: () {
                          setModalState(() => _selectedPaymentMethod = 'cash');
                          setState(() => _selectedPaymentMethod = 'cash');
                        },
                      ),
                      const SizedBox(height: 16),

                      const SizedBox(height: 20),

                      // زر التأكيد النهائي
                      FilledButton(
                        onPressed: placingOrder
                            ? null
                            : () async {
                                setModalState(() => placingOrder = true);
                                await _confirmOrder(
                                  modalContext,
                                  setModalState,
                                  finalTotal: finalTotal,
                                  appliedDiscount: discount,
                                );
                                // ★ الزر يعود للحياة إن لم يُرسَل الطلب. الورقة
                                //   تبقى مفتوحة على كل فشل — ومنه «الموقع مطلوب» —
                                //   فإبقاء الدوران يحبس الزبون بلا زر: لا يستطيع
                                //   أن يضغط «تحديث» في البطاقة ويعيد الإرسال.
                                //   عند النجاح تُغلق الورقة، فيسقط `mounted` ولا
                                //   rebuild على سياق ميت.
                                if (modalContext.mounted) {
                                  setModalState(() => placingOrder = false);
                                }
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: placingOrder
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'تأكيد وإرسال الطلب — ${CurrencyFormatter.format(finalTotal)}',
                                style: GoogleFonts.cairo(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// إرسال الطلب مع حماية تكرار الطلب: إن كان للعميل طلب نشط
  /// (قيد الانتظار/مقبول/قيد التوصيل) تُمنع إعادة الإرسال وتظهر رسالة
  /// "طلبك قيد التوصيل، انتظر من فضلك".
  Future<void> _confirmOrder(
    BuildContext sheetContext,
    void Function(VoidCallback) setModalState, {
    required double finalTotal,

    /// ★ الخصم **الفعلي** الذي طُرح من الإجمالي أمام الزبون (مقصوص
    ///   عند سقف الفاتورة في ورقة الدفع). يُحفظ في `coupon_discount`
    ///   كما هو، لا القيمة المعلنَة من الخادم: الفرق بينهما يظهر لاحقاً
    ///   في «تفاصيل الطلب» كسعر أصلي محشوّ فوق الحقيقي.
    required double appliedDiscount,
  }) async {
    // ★ الدخول إجباري لإرسال أي طلب: تُفتح شاشة الدخول، وبعد نجاحها
    //   يكمل الإرسال نفسه بلا أن يخسر الزبون سلته أو ورقة الدفع.
    if (!hasAppSession) {
      pushAppLogin(
        sheetContext,
        onSuccess: () {
          if (mounted) {
            _confirmOrder(
              sheetContext,
              setModalState,
              finalTotal: finalTotal,
              appliedDiscount: appliedDiscount,
            );
          }
        },
      );
      return;
    }
    final phone = AuthService.instance.phone!;

    // 1+2) ★ تقليل تأخير إرسال الطلب (2026-11-08، إصلاح app-side فقط):
    //   فحص الطلب النشط وتحديد الموقع كانا يعملان **بالتسلسل** (شبكة + GPS
    //   قد يصلان إلى ثوانٍ عديدة). هما مستقلان ⇒ نُنفّذهما بالتوازي مع
    //   الحفاظ على نفس الشروط تماماً: منع الطلب النشط، والموقع إجباري.
    //   لا تغيير في DB/RPC/السيرفر/منطق الطلبات أو الإشعارات.
    final hasActiveFuture = SupabaseService.instance.hasActiveOrder(phone);
    final locationFuture = _ensureLocation();
    final hasActive = await hasActiveFuture;
    if (hasActive) {
      await locationFuture; // لا نترك Future معلقاً
      setModalState(() {});
      _showInfoDialog(
        'طلبك قيد التوصيل',
        'لديك طلب قيد التجهيز أو التوصيل. انتظر من فضلك حتى اكتماله '
            'قبل إرسال طلب جديد.',
      );
      return;
    }
    await locationFuture;
    if (!mounted) return;

    // ★ **الموقع إجباري**: بلا إحداثيات لا يُرسَل الطلب إطلاقاً.
    //
    // كان الإرسال يمرّ وبلا موقع (٢٠٢٦-١٠-٠٩) لأن تعطل GPS كان يوقف
    // الطلب كله؛ صارت البوابة هنا تُبلّغ الزبون قبل النداء لا بعد رفض
    // القاعدة، فيعرف أن ينقصه موقع لا أن إرساله فشل. البطاقة أعلاه فيها
    // «تحديث» و«حدد موقعي على الخريطة»، فله مخرجان: إنارة الحسّاس أو
    // دبوس على المكان. الأعمدة في القاعدة بقيت كما هي — لا تعديل في
    // جدول ولا في صف قديم، والمنع في التطبيق وحده.
    final loc = LocationService.instance;
    if (loc.currentLat == null || loc.currentLng == null) {
      _showInfoDialog(
        'الموقع مطلوب',
        'لم نحدد موقعك الحالي، فالطلب لا يُرسل بدونه. فعّل خدمة الموقع '
            '(GPS) ثم اضغط «تحديث» في بطاقة عنوان التوصيل، أو ثبّت مكانك '
            'بزر «حدد موقعي على الخريطة» وأعد الإرسال.',
      );
      return;
    }
    final customerNote = _notesCtrl.text.trim();
    final paymentLabel = switch (_selectedPaymentMethod) {
      'card' => 'بطاقة',
      'wallet' => 'محفظة',
      _ => 'كاش',
    };

    // ★ بوابة الوصفة الطبية: صنف يتطلب وصفة وبلا صورة مرفقة = لا إرسال.
    //   الرفض هنا قبل أي نداء، ونسخة أخرى من الحاجز تريجر في القاعدة
    //   يمنع الإدراج حتى لو تُجاوز التطبيق.
    final needsPrescription = CartService.instance.items
        .any((it) => it.product.requiresPrescription);
    if (needsPrescription &&
        (_prescriptionUrl == null || _prescriptionUrl!.isEmpty)) {
      _showInfoDialog(
        'الوصفة الطبية مطلوبة',
        'أحد الأصناف في سلتك دواءٌ يتطلب وصفة طبية. ارفع صورة الوصفة '
        'من بطاقة «الوصفة الطبية» في هذه الورقة ثم أعد الإرسال — '
        'لا يُقبل الطلب بدونها.',
      );
      return;
    }

    final order = await SupabaseService.instance.createOrder(
      orderNumber: OrderDisplay.newOrderTag(),
      userPhone: phone,
      userName: AuthService.instance.name,
      totalAmount: finalTotal,
      // ★ رسوم التوصيل تُرسل كما هي. الخصم محسوب أصلاً في
      //   `totalAmount` أعلاه، فطرحه من الرسوم كان يجعل
      //   `delivery_fee = 0 − الخصم` ⇒ يُقصّ إلى صفر دائماً، ويضيع
      //   أثر الخصم من السجل المالي.
      deliveryFee: CartService.instance.deliveryFee,
      address: LocationService.instance.currentAddress,
      latitude: LocationService.instance.currentLat,
      longitude: LocationService.instance.currentLng,
      notes: customerNote.isEmpty
          ? 'طريقة الدفع: $paymentLabel'
          : 'طريقة الدفع: $paymentLabel · $customerNote',
      // ★ تسجيل أثر الخصم في الطلب نفسه. المبلغ صحيح في
      //   `totalAmount`، لكن بلا هذين لا يُعرف لاحقاً أي كود
      //   استُعمل ولا بكم — والمطابقة المالية مستحيلة.
      couponCode: _discountApplied ? _discountCode : null,
      couponDiscount: _discountApplied ? appliedDiscount : 0,
      prescriptionPath: _prescriptionUrl,
      items: CartService.instance.items
          .map(
            (it) => {
              'name': it.product.name,
              'shopName': it.product.shopName,
              'quantity': it.quantity,
              'price': it.product.price,
              'image': it.product.logoImage,
              'productId': it.product.id,
              'shopId': it.product.shopId,
            },
          )
          .toList(),
    );
    if (!mounted) return;

    // 3) منع التكرار من جهة السيرفر (قاعدة البيانات ترفض طلباً نشطاً ثانياً).
    if (order == null) {
      final activeNow = await SupabaseService.instance.hasActiveOrder(phone);
      if (!mounted) return;
      if (activeNow) {
        _showInfoDialog(
          'طلبك قيد التوصيل',
          'لديك طلب قيد التجهيز أو التوصيل. انتظر من فضلك حتى اكتماله '
              'قبل إرسال طلب جديد.',
        );
      } else {
        // ★ الرفض قد يكون **سدّ التكرار**: كود عجلة الحظ على طلب ثانٍ
        //   ترده القاعدة بفهرسها، فالفاتورة لا تُنشأ نصفَ نصف. الجملة
        //   هنا عن الكود نفسه — لأن «حاول بعد قليل» توحي بأن الضغط
        //   مرة أخرى سينجح، ولن ينجح.
        //   غياب الموقع لا يُذكر هنا: البوابة أعلاه ترجع قبل النداء،
        //   فالفشل في هذه النقطة من server لا من إحداثيات ناقصة.
        final serverWhy = SupabaseService.instance.lastOrderError ?? '';
        final codeBlocked = serverWhy.contains('كود');
        _showInfoDialog(
          codeBlocked ? 'الكود استُعمل من قبل' : 'تعذر إرسال الطلب',
          codeBlocked
              ? 'هذا الكود خُصم على طلبك السابق، ولا يُستعمل مرة أخرى — '
                    'الكودات مرة واحدة لكل زبون. أرسل طلبك بدون كود أو '
                    'استعمل كوداً آخر.'
              : 'لم نتمكن من إرسال طلبك حالياً، حاول مرة أخرى بعد قليل.',
        );
      }
      return;
    }

    // 4) نجاح: إغلاق ورقة تأكيد الطلب + استبدال القسيمة إن وُجدت.
    if (sheetContext.mounted && Navigator.of(sheetContext).canPop()) {
      Navigator.of(sheetContext).pop();
    }
    // ★ يُقصم الكود الآن: بعد نجاح الطلب فقط، لا عند الضغط على «تطبيق».
    //   وبمجرد تسجيله تُقفل «خصوماتي» **ويبدأ عدّها من الصفر**: تُفتح
    //   بعد ٣ طلبات مكتملة تلي هذا الاستعمال —
    //   وهذا ما يُقال للزبون في نافذة النجاح كي لا يظنّ كوده ضاع.
    final usedCode = _discountApplied ? _discountCode : '';
    unawaited(
      DiscountService.instance
          .commit(orderId: '${order['id'] ?? ''}', phone: phone)
          // ★ لا يُبتلع الفشل هذه المرة: إن لم يُسجَّل الاستعمال يُقال
          //   للزبون، لأن الصمت هو ما كان يُبقي «خصوماتي» على `٣/٣`.
          .then((_) {
            final err = DiscountService.instance.lastCommitError;
            if (err == null || usedCode.isEmpty || !mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'لم يُسجَّل استعمال الكود عندنا — أكوادك تُقفل تلقائياً '
                  'بعد اكتمال الطلب. ($err)',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
                ),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppColors.warning,
              ),
            );
          }),
    );
    _showOrderSuccessDialog(order, finalTotal, usedCode: usedCode);
  }

  void _showOrderSuccessDialog(
    Map<String, dynamic> order,
    double finalTotal, {
    String usedCode = '',
  }) {
    // الرقم التسلسلي الجديد (1, 2, 3...) لا الرقم القديم.
    final orderNumber = OrderDisplay.serial(order);
    final orderId = order['id']?.toString() ?? '';
    CartService.instance.clear();
    // ★ الكود استُهلك مع الطلب: نُفرّغ الحقل والحالة معاً كي لا
    //   يبقى كودٌ قديم معروضاً «مُفعّلاً» ولا يُوسم طلب قادم به.
    setState(() {
      _discountApplied = false;
      _discountCode = '';
      _discountError = '';
      _discountCtrl.clear();
    });
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: AppColors.primary,
                size: 50,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'تم استلام طلبك بنجاح!',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'رقم الطلب: $orderNumber',
              style: GoogleFonts.cairo(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'سيصلك الطلب خلال 25-35 دقيقة تقريباً. سيصلك إشعار '
              'عند قبوله وبدء التوصيل.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            // ★ بعد استعمال كود: تأكيد بسيط بما حدث — «خصوماتي»
            //   (دورة ٣ طلبات) أُزيلت من التطبيق، فلا عدّاد يُقفل ويعود.
            if (usedCode.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'استعملت الكود $usedCode بنجاح — خُصم '
                  'مبلغه من فاتورتك.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (orderId.isNotEmpty) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => OrderTrackingScreen(
                          orderId: orderId,
                          orderNumber: orderNumber,
                        ),
                      ),
                    );
                  }
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  'تتبع توصيل طلبي',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'متابعة التسوق',
                style: GoogleFonts.cairo(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// نافذة تنبيه عامة (منع تكرار الطلب / أخطاء الإرسال).
  void _showInfoDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            color: AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'حسناً',
              style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onRefresh() async {
    // السلة محلية بالكامل (لا شبكة)، فالسحب ينتهي فور انتهاء المؤشر.
    // كان هنا نوم ٦٠٠ ملّي صريح بلا أي عمل خلفه.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('السلة'),
        // ★ السلة لم تعد تبويباً في الشريط السفلي، بل تُفتح من دائرة
        //   الجرس أعلى الرئيسية (ومن صفحة الصيدلية) كصفحة مستقلة: من لها
        //   من يرجع إليها، ومن لا يمكنه الرجوع لا يُرسم له سهم.
        automaticallyImplyLeading: Navigator.of(context).canPop(),
        actions: [
          AnimatedBuilder(
            animation: CartService.instance,
            builder: (context, _) {
              if (CartService.instance.items.isEmpty) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: 'تفريغ السلة',
                icon: const Icon(
                  Icons.delete_sweep_rounded,
                  color: AppColors.danger,
                ),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(
                        'تفريغ السلة',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.w800),
                      ),
                      content: Text(
                        'هل تريد حذف جميع الأصناف من السلة؟',
                        style: GoogleFonts.cairo(),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('إلغاء'),
                        ),
                        FilledButton(
                          onPressed: () {
                            CartService.instance.clear();
                            Navigator.pop(ctx);
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.danger,
                          ),
                          child: const Text('تفريغ'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _onRefresh,
        child: AnimatedBuilder(
          animation: CartService.instance,
          builder: (context, _) {
            final items = CartService.instance.items;
            final subtotal = CartService.instance.subtotal;
            final total = subtotal;

            if (items.isEmpty) {
              return ListView(
                controller: tabScroll,
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.25),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: const BoxDecoration(
                              color: AppColors.primaryLight,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.shopping_cart_outlined,
                              size: 48,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'سلة التسوق فارغة',
                            style: GoogleFonts.cairo(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'تصفح الصيدليات والمنتجات وأضف ما ترغب به إلى سلتك بكل سهولة',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.cairo(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }

            return ListView(
              controller: tabScroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                SectionHeader(
                  title:
                      'الأصناف المختارة (${CartService.instance.totalItemCount})',
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < items.length; i++) ...[
                  _CartItemCard(
                    item: items[i],
                    onIncrement: () => _changeQuantity(
                      context,
                      items[i].product.id,
                      1,
                    ),
                    onDecrement: () => _changeQuantity(
                      context,
                      items[i].product.id,
                      -1,
                    ),
                    onRemove: () =>
                        CartService.instance.removeItem(items[i].product.id),
                  ),
                  if (i != items.length - 1) const SizedBox(height: 12),
                ],
                const SizedBox(height: 20),
                _SummaryCard(total: subtotal),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _showCheckoutBottomSheet(total),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 2,
                  ),
                  child: Text(
                    'إتمام الطلب — ${CurrencyFormatter.format(total)}',
                    style: GoogleFonts.cairo(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CartItemCard extends StatelessWidget {
  const _CartItemCard({
    required this.item,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
  });

  final CartItemModel item;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final product = item.product;
    final color = AppColors.primary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.08), AppColors.surface],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.imageBackground,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: product.logoImage != null
                ? AppImage(
                    product.logoImage!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                      product.logo ?? Icons.fastfood_rounded,
                      color: AppColors.primary,
                      size: 28,
                    ),
                  )
                : Icon(
                    product.logo ?? Icons.fastfood_rounded,
                    color: AppColors.primary,
                    size: 28,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  product.shopName,
                  style: GoogleFonts.cairo(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  CurrencyFormatter.format(item.totalPrice),
                  style: GoogleFonts.cairo(
                    color: AppColors.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _QuantityStepper(
            value: item.quantity,
            onIncrement: onIncrement,
            onDecrement: onDecrement,
          ),
          IconButton(
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.textHint,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.value,
    required this.onIncrement,
    required this.onDecrement,
  });

  final int value;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(icon: Icons.add_rounded, onTap: onIncrement),
        const SizedBox(width: 8),
        Text(
          '$value',
          style: GoogleFonts.cairo(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 8),
        _StepButton(icon: Icons.remove_rounded, onTap: onDecrement),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // `InkWell` لا `GestureDetector`: الأول يعطي تموّجاً (ripple) كإشارة
    // لمسية عند +، والثاني لا يعطي أي شيء.
    //
    // و`AnimatedContainer` هنا كان يحيط بخصائص **ثابتة** ⇒ متحكّم يعمل
    // بلا أي تغيّر، أي عمل بلا فائدة مع كل ضغطة.
    return Material(
      color: AppColors.primary,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.3),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.total});

  final double total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.05),
            AppColors.surface,
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          _summaryRow('المجموع الفرعي', CurrencyFormatter.format(total)),
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(color: AppColors.divider, thickness: 1, height: 1),
          ),
          _summaryRow(
            'الإجمالي',
            CurrencyFormatter.format(total),
            highlighted: true,
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool highlighted = false}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.cairo(
              color: highlighted ? AppColors.primary : AppColors.textSecondary,
              fontSize: highlighted ? 15 : 13,
              fontWeight: highlighted ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.cairo(
            color: highlighted ? AppColors.primary : AppColors.textPrimary,
            fontSize: highlighted ? 17 : 13,
            fontWeight: highlighted ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _PaymentOptionTile extends StatelessWidget {
  const _PaymentOptionTile({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryLight
              : AppColors.surfaceTint.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? AppColors.primary : AppColors.divider,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.cairo(
                  color: isSelected ? AppColors.primary : AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle_rounded,
                color: AppColors.primary,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة عنوان التوصيل التي تحدد الموقع تلقائياً لحظة فتح شاشة الطلب.
class _DeliveryAddressCard extends StatefulWidget {
  const _DeliveryAddressCard();

  @override
  State<_DeliveryAddressCard> createState() => _DeliveryAddressCardState();
}

class _DeliveryAddressCardState extends State<_DeliveryAddressCard> {
  bool _isDetecting = true;
  String _address = 'جاري تحديد موقعك تلقائياً...';
  String? _error;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect({bool manual = false}) async {
    setState(() {
      _isDetecting = true;
      _error = null;
    });
    // ★ [manual] = presses «تحديث» صراحةً ⇒ يتجاوز الدبوس. أما النداء
    //   التلقائي عند فتح الورقة فيحترم ما أكّده الزبون على الخريطة،
    //   وإلا محَا اختيارُه نفسَه بلمحة GPS قبل الإرسال.
    final result = await LocationService.instance.determinePosition(
      overridePin: manual,
    );
    if (!mounted) return;
    setState(() {
      _isDetecting = false;
      _address = result.address;
      if (!result.isAutoDetected) _error = result.errorMessage;
    });
  }

  /// ★ يفتح الخريطة بدبوس التثبيت؛ بعد «تأكيد موقعي» يُعرض العنوان
  ///   الجديد مباشرةً، لأن `LocationService` كتب الإحداثيات للعهدته.
  Future<void> _pickOnMap() async {
    final ok = await LocationMapPicker.open(context);
    if (!ok || !mounted) return;
    final loc = LocationService.instance;
    setState(() {
      _isDetecting = false;
      _error = null;
      _address = loc.currentAddress;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _error == null
            ? AppColors.primaryLight
            : AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _error == null
              ? AppColors.primary.withValues(alpha: 0.25)
              : AppColors.danger.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.my_location_rounded,
                color: _error == null ? AppColors.primary : AppColors.danger,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // «إجباري» مكتوب في البطاقة نفسها: المنع عند
                      // الإرسال وحده مفاجأة، والزبون يرى النقص قبل
                      // أن يضغط «تأكيد».
                      LocationService.instance.manualPinActive
                          ? 'موقعك المثبّت على الخريطة · إجباري'
                          : 'عنوان التوصيل · إجباري',
                      style: GoogleFonts.cairo(
                        color: AppColors.textHint,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (_isDetecting) ...[
                          const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            _address,
                            style: GoogleFonts.cairo(
                              color: _error == null
                                  ? AppColors.textPrimary
                                  : AppColors.danger,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _isDetecting ? null : () => _detect(manual: true),
                child: Text(
                  'تحديث',
                  style: GoogleFonts.cairo(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          // ★ زر الخريطة: دبوس على المكان المضبوط ثم «تأكيد موقعي».
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isDetecting ? null : _pickOnMap,
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
    );
  }

  // ── العناوين المحفوظة ──────────────────────────────────────────────
}

/// ★ بطاقة إرفاق الوصفة الطبية في ورقة الدفع.
///
/// تظهر فقط حين يحوي السلة صنفاً `requiresPrescription`. بلا صورة مرفقة
/// يبقى زر التأكيد ممنوعاً (بوابة `_confirmOrder`). الصورة تُرفع إلى
/// مجلد `prescriptions` وتُخزَّن في الطلب، ويظهر رابطها لصاحب الصيدلية
/// وللأدمن فقط.
class _PrescriptionCard extends StatelessWidget {
  const _PrescriptionCard({
    required this.url,
    required this.uploading,
    required this.onPick,
    required this.onClear,
  });

  final String? url;
  final bool uploading;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final attached = url != null && url!.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.medical_information_rounded,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'الوصفة الطبية (مطلوبة)',
                  style: GoogleFonts.cairo(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (attached)
                IconButton(
                  tooltip: 'إزالة الوصفة',
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppColors.danger,
                  ),
                  onPressed: onClear,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'سلتك تضم دواءً يُصرف بوصفة طبية فقط — ارفع صورة الوصفة '
            'موقّعة من الطبيب، وتظهر لصيدليّتنا وللإدارة فقط.',
            style: GoogleFonts.cairo(
              fontSize: 11,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          if (uploading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else if (attached)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AppImage(
                url!,
                height: 140,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(
                  height: 140,
                  color: AppColors.imageBackground,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    color: AppColors.textHint,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onPick,
                icon: const Icon(Icons.add_photo_alternate_rounded, size: 18),
                label: Text(
                  'ارفاق صورة الوصفة',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.warning,
                  side: BorderSide(
                    color: AppColors.warning.withValues(alpha: 0.5),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ★ حقل كود الخصم في السلة.
///
/// يتحقق على الخادم فقط:pressing «تطبيق» يستدعي
/// `check_discount_code` الذي يتحقق من الصلاحية والمدة والسقف
/// **ويحسب المبلغ**. لا شيء يُحسم في الجهاز.
class _DiscountCodeField extends StatelessWidget {
  const _DiscountCodeField({
    required this.controller,
    required this.busy,
    required this.applied,
    required this.appliedCode,
    required this.error,
    required this.onApply,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool busy;
  final bool applied;
  final String appliedCode;
  final String error;
  final VoidCallback onApply;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (applied) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: AppColors.success,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'الكود $appliedCode مُفعّل',
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  color: AppColors.success,
                ),
              ),
            ),
            IconButton(
              onPressed: onClear,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppColors.textSecondary,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              Icons.local_offer_rounded,
              size: 20,
              color: AppColors.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'كود الخصم',
                style: GoogleFonts.cairo(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          // ★ القفل على الخادم في `check_discount_code` نفسه، فنصٌّ
          //   إرشادي فقط — التطبيق لا يقرّر شيئاً.
          'أدخل كود الخصم الذي أعطاك إياه صاحب الصيدلية — يُقبل '
          'كود واحد فعّال لكل طلب، ولكل زبون استعمال واحد.',
          style: GoogleFonts.cairo(
            fontSize: 11,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                textCapitalization: TextCapitalization.characters,
                // ★ سطر واحد دائماً: في حقل متعدد الأسطر يتحوّل زر
                //   الإرسال إلى «سطر جديد» فلا ينفّذ «تطبيق»، والسطر
                //   الثاني ينزل بالحقل نفسه تحت الكيبورد.
                maxLines: 1,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!busy) onApply();
                },
                // ★ المسافة التي يتركها Flutter للحقل حين يُمرّر فوق
                //   الكيبورد: 24 بكسل الأصلية تُبقيه ملتصقاً بحافة
                //   الكيبورد، وهذا يعطي راحة واضحة فوقه.
                scrollPadding: const EdgeInsets.only(bottom: 130),
                decoration: InputDecoration(
                  hintText: 'أدخل الكود',
                  hintStyle: GoogleFonts.cairo(fontSize: 13),
                  prefixIcon: const Icon(Icons.vpn_key_rounded, size: 19),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                style: GoogleFonts.cairo(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : onApply,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      'تطبيق',
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ],
        ),
        if (error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            error,
            style: GoogleFonts.cairo(
              fontSize: 11.5,
              color: AppColors.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}
