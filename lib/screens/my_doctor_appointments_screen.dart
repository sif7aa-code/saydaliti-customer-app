import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/doctor_service.dart';
import '../services/supabase_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_refresh_indicator.dart';
import '../widgets/doctor_appointment_card.dart';
import '../widgets/doctor_appointment_details.dart';
import 'doctor_appointment_screen.dart';

/// ★ «حجوزاتي عند دكتور/ة» — ما يراه صاحب الحجز بعد أن يضغط «تثبيت الحجز».
///
///   الأدمن (10-31): «لا تظهر تفاصيل الحجز بعد الحجز للزبون». الشاشة
///   تقرأ `my_doctor_appointments` التي تعزل بالرقم من داخل القاعدة،
///   فليست قائمة يرسل الوسيط رقمها: من بلا جلسة يصفّ صفراً.
///
///   لا مندوب في دورة حجز الطبيب: الموافقة برقم يكتبه السكرتير هي نهاية
///   الدورة، ورقم الحجز لا يظهر هنا قبل الموافقة. نقر البطاقة يفتح شيت
///   التفاصيل والمراقبة.
class MyDoctorAppointmentsScreen extends StatefulWidget {
  const MyDoctorAppointmentsScreen({super.key});

  @override
  State<MyDoctorAppointmentsScreen> createState() =>
      _MyDoctorAppointmentsScreenState();
}

class _MyDoctorAppointmentsScreenState
    extends State<MyDoctorAppointmentsScreen>
    with TabRefreshTarget<MyDoctorAppointmentsScreen> {
  /// ★ تبويب «حجوزاتي» في الشريط السفلي (2026-11-24): النقرة عليه
  ///   تصعد للقائمة وتعيد القراءة، مثل بقية التبويبات.
  @override
  String get tabId => 'bookings';

  @override
  Future<void> Function()? onTabRefresh() => _load;

  List<DoctorAppointment> _rows = const [];
  bool _loading = true;

  /// القراءة سقطت (شبكة أو دالة غير مثبّتة): الشاشة تقول ذلك ولا تكذب
  /// بـ«لا توجد حجوزات»، وإلا انتظر الزبون حجزاً هو أصلاً لم يُقرأ.
  bool _readFailed = false;
  String _failure = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ★ تبويب خلف الهيكل للزائر: لا نداء بلا جلسة، والباب أصلاً
    //   مغلق بالدخول من الشريط السفلي.
    if (!AuthService.instance.isLoggedIn) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rows = const [];
        _readFailed = false;
      });
      return;
    }
    final list = await DoctorService.instance.mine();
    if (!mounted) return;
    // الفراغ الحقيقي ردّ 2xx بلا صفوف، و`lastRpcError` فيه null. أي سبب
    // آخر (شبكة أو دالة غير مثبّتة) يقول نفسه — ولا يُكتب «لا حجوزات».
    final why = (SupabaseService.instance.lastRpcError ?? '').trim();
    setState(() {
      _loading = false;
      _rows = list;
      _readFailed = list.isEmpty && why.isNotEmpty;
      _failure = _readFailed ? why : '';
    });
  }

  void _openDetails(DoctorAppointment a) {
    DoctorAppointmentDetails.show(context, appointment: a);
  }

  void _openBooking() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (_) => const DoctorAppointmentScreen()),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('حجوزاتي عند دكتور/ة'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _openBooking,
            tooltip: 'حجز جديد',
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      floatingActionButton: _rows.isEmpty && !_loading
          ? FloatingActionButton.extended(
              onPressed: _openBooking,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.medical_services_outlined),
              label: Text(
                'حجز جديد',
                style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
              ),
            )
          : null,
      body: AppRefreshIndicator(
        color: AppColors.primary,
        onRefresh: _load,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rows.isEmpty) {
      return ListView(
        controller: tabScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 90),
          Icon(
            _readFailed ? Icons.wifi_off_rounded : Icons.event_busy_rounded,
            size: 60,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              _readFailed
                  ? (_failure.isEmpty
                        ? 'تعذّر جلب الحجوزات — تحقّق من الاتصال'
                        : _failure)
                  : 'لا لديك حجوزات دكتور/ة بعد',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (!_readFailed)
            Center(
              child: Text(
                'ثبّت حجزك الأول من «حجز جديد»، ويبقى هنا برقمه وحالته.',
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 12.5,
                  height: 1.6,
                  color: AppColors.textHint,
                ),
              ),
            ),
        ],
      );
    }
    return ListView.builder(
      controller: tabScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _rows.length,
      itemBuilder: (context, i) {
        final a = _rows[i];
        return DoctorAppointmentCard(
          key: ValueKey<String>('my-appt:${a.id}'),
          appointment: a,
          onDetails: () => _openDetails(a),
        );
      },
    );
  }
}
