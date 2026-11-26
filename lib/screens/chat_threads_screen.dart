import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/doctor_service.dart';
import '../services/tab_refresh.dart';
import '../widgets/app_image.dart';
import '../widgets/app_refresh_indicator.dart';
import 'chat_screen.dart';

/// ★ قائمة محادثات الدردشة — تظهر للزبون من أيقونة الرأس، وللعيادة
///   كمساحة مستقلة في واجهة الطبيب/السكرتير. المحتوى يتبع الحساب:
///   العيادة ترى مراجعيها، والزبون يرى العيادات التي راسلها.
class ChatThreadsScreen extends StatefulWidget {
  const ChatThreadsScreen({super.key});

  @override
  State<ChatThreadsScreen> createState() => _ChatThreadsScreenState();
}

class _ChatThreadsScreenState extends State<ChatThreadsScreen>
    with TabRefreshTarget<ChatThreadsScreen>, WidgetsBindingObserver {
  @override
  String get tabId => 'chat_threads';

  @override
  Future<void> Function()? onTabRefresh() => _load;

  List<ChatThread> _rows = const [];
  bool _loading = true;
  String _failure = '';
  String _clinicName = '';

  @override
  void initState() {
    super.initState();
    ChatService.instance.startPolling();
    ChatService.instance.purgeOnce();
    ChatService.instance.wake.addListener(_onWake);
    WidgetsBinding.instance.addObserver(this);
    // ★ «متصل الآن»/«آخر ظهور» يتغيّران بلا خروج ودخول: تحديث خفيف
    //   كل ٣٠ ثانية (إيقاع نبضة الحضور) — ولحسابات العيادة وحدها، فهي
    //   الوحيدة التي تعرض حضور المراجع.
    if (AuthService.instance.isClinicAccount) {
      _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) _load();
      });
    }
    _load();
    _loadClinicName();
  }

  Timer? _presenceTimer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _load();
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ChatService.instance.wake.removeListener(_onWake);
    super.dispose();
  }

  /// وصلت رسالة الآن ⇒ أعِد جلب القائمة فوراً (المعاينة والشارة).
  void _onWake() {
    if (mounted) _load();
  }

  /// ★ اسم العيادة في عنوان القائمة للممرض/السكرتير (طلب ٢٠٢٦-١١-٢٥).
  ///   لا يُعرض إلا إذا كان الحساب لعيادة واحدة؛ مع عدة عيادات يظهر
  ///   اسم كل عيادة في رأس محادثتها نفسها.
  Future<void> _loadClinicName() async {
    if (!AuthService.instance.isClinicAccount) return;
    final ctx = await DoctorService.instance.myRoles();
    if (!mounted || ctx == null || ctx.doctors.length != 1) return;
    final name = ctx.doctors.first.name.trim();
    if (name.isNotEmpty) setState(() => _clinicName = name);
  }

  Future<void> _load() async {
    final rows = await ChatService.instance.threads();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (rows == null) {
        _rows = const [];
        _failure = ChatService.instance.lastError;
      } else {
        _rows = rows;
        _failure = '';
      }
    });
  }

  void _open(ChatThread t) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(
              doctorId: t.doctorId,
              patientPhone: t.clinicViewer ? t.patientPhone : null,
              title: t.title,
              image: t.image,
              bookingOpen: t.bookingOpen,
            ),
          ),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          _clinicName.isEmpty ? 'الدردشة' : 'الدردشة · $_clinicName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          const _RetentionHint(),
          Expanded(
            child: AppRefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: _body(),
            ),
          ),
        ],
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
            _failure.isNotEmpty ? Icons.wifi_off_rounded : Icons.forum_outlined,
            size: 62,
            color: AppColors.textHint,
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              _failure.isNotEmpty
                  ? 'تعذّر جلب المحادثات'
                  : 'لا توجد محادثات بعد',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _failure.isNotEmpty
                  ? _failure
                  : 'ابدأ الدردشة من صفحة الطبيب في الدليل — رسائل العيادة والمراجع تُحذف نهائياً بعد 24 ساعة.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                height: 1.7,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      controller: tabScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      itemCount: _rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, i) {
        final t = _rows[i];
        return _ThreadCard(t: t, onTap: () => _open(t));
      },
    );
  }
}

class _RetentionHint extends StatelessWidget {
  const _RetentionHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 15, color: AppColors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'تُحذف الرسائل نهائياً من الخادم بعد 24 ساعة',
              style: GoogleFonts.cairo(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadCard extends StatelessWidget {
  const _ThreadCard({required this.t, required this.onTap});

  final ChatThread t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = t.preview;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            children: [
              _Avatar(
                image: t.image,
                clinic: !t.clinicViewer,
                size: 52,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: t.online
                                ? AppColors.success
                                : AppColors.textHint,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            t.statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: t.online
                                  ? AppColors.primaryDark
                                  : AppColors.textHint,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    chatTimeLabel(t.lastAt),
                    style: GoogleFonts.cairo(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textHint,
                    ),
                  ),
                  const SizedBox(height: 7),
                  if (t.unread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      constraints: const BoxConstraints(minWidth: 21),
                      child: Text(
                        t.unread > 99 ? '+99' : '${t.unread}',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.cairo(
                          fontSize: 10,
                          height: 1.2,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    )
                  else
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 13,
                      color: AppColors.textHint,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// صورة الطرف أو بديلها عند غياب الصورة.
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.image,
    required this.clinic,
    required this.size,
  });

  final String image;
  final bool clinic;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = image.trim().isEmpty ? '' : AppImage.resolve(image);
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.imageBackground,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? Container(
              color: AppColors.primaryLight,
              child: Icon(
                clinic
                    ? Icons.medical_services_outlined
                    : Icons.person_outline_rounded,
                size: size * 0.48,
                color: AppColors.primaryDark,
              ),
            )
          : AppImage(
              url,
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (_, _, _) => Container(
                color: AppColors.primaryLight,
                child: Icon(
                  clinic
                      ? Icons.medical_services_outlined
                      : Icons.person_outline_rounded,
                  size: size * 0.48,
                  color: AppColors.primaryDark,
                ),
              ),
            ),
    );
  }
}

/// صياغة وقت الرسالة: اليوم بالدقيقة، أمس، ثم التاريخ.
String chatTimeLabel(DateTime? at) {
  if (at == null) return '';
  final now = DateTime.now();
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (diff == 0) return '$hh:$mm';
  if (diff == 1) return 'أمس';
  if (local.year == now.year) return '${local.day}/${local.month}';
  return '${local.day}/${local.month}/${local.year}';
}

/// تاريخ الرسالة كاملاً: 25/11/2026.
String chatMsgDate(DateTime? at) {
  if (at == null) return '';
  final l = at.toLocal();
  return '${l.day}/${l.month}/${l.year}';
}

/// وقت الرسالة بالساعة والصباح أو المساء: 2:35 مساءً.
String chatMsgTime(DateTime? at) {
  if (at == null) return '';
  final l = at.toLocal();
  final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final mm = l.minute.toString().padLeft(2, '0');
  final period = l.hour < 12 ? 'صباحاً' : 'مساءً';
  return '$h12:$mm $period';
}
