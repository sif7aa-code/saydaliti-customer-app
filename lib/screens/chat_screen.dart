import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../core/theme/app_colors.dart';
import '../app.dart' show appNavigatorKey;
import '../models/doctor_profile.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/chat_sound.dart';
import '../services/chat_theme.dart';
import '../services/doctor_directory_service.dart';
import '../widgets/app_image.dart';
import 'chat_threads_screen.dart' show chatMsgDate, chatMsgTime;
import 'doctor_profile_screen.dart';

/// يفتح المحادثة من رابط إشعار `chat:<doctorId>:<patientPhone>`.
///
/// حساب العيادة يفتحها مع المراجع صاحب الرقم، والمراجع يفتحها مع
/// العيادة (رقمه من جلسته). يُستدعى من إشعار FCM ومن بطاقة الإشعار
/// داخل التطبيق، فلا يفتح «chat:…» في المتصفح أبداً.
void openChatFromLink(String link) {
  final parts = link.split(':');
  if (parts.length < 2) return;
  final doctorId = parts[1].trim();
  if (doctorId.isEmpty) return;
  final phone = parts.length > 2 ? parts[2].trim() : '';
  final clinic = AuthService.instance.isClinicAccount && phone.isNotEmpty;
  try {
    appNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          doctorId: doctorId,
          patientPhone: clinic ? phone : null,
        ),
      ),
    );
  } catch (_) {
    // تعذّر التنقّل — لا نكسر التطبيق.
  }
}

/// ★ شاشة المحادثة بين المراجع والعيادة (الطبيب/السكرتير/الممرض).
///
///  - الحالة أعلى الشاشة من زر تشغيل/إطفاء الحجز عند العيادة.
///  - زر ردّ على كل رسالة، وإرسال صور من الاستوديو بعد ضغطها.
///  - حذف من عندي أو من الطرفين (لصاحب الرسالة).
///  - كل الرسائل تُحذف نهائياً من القاعدة بعد 24 ساعة.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.doctorId,
    this.patientPhone,
    this.title = '',
    this.image = '',
    this.bookingOpen = false,
  });

  final String doctorId;

  /// يمرّرها حساب العيادة فقط؛ الزبون رقمه من جلسته.
  final String? patientPhone;
  final String title;
  final String image;
  final bool bookingOpen;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _text = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  ChatSession? _session;
  bool _loading = true;
  bool _busy = false;
  bool _sending = false;
  bool _uploading = false;
  String _failure = '';
  ChatMessage? _replyTo;
  Timer? _poll;
  ChatTheme _theme = ChatTheme.fallback;

  String get _doctorId => widget.doctorId;
  String? get _patientPhone {
    final s = _session;
    if (s != null && s.clinicViewer) return s.patient.phone;
    return widget.patientPhone;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatService.instance.startPolling();
    ChatService.instance.purgeOnce();
    ChatService.instance.wake.addListener(_onWake);
    _theme = ChatThemeStore.current.value;
    ChatThemeStore.current.addListener(_onTheme);
    ChatThemeStore.load();
    _load(first: true);
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    ChatService.instance.wake.removeListener(_onWake);
    ChatThemeStore.current.removeListener(_onTheme);
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    super.dispose();
  }

  /// وصلت رسالة الآن ⇒ اسحب المحادثة فوراً بلا انتظار المؤقّت.
  void _onWake() {
    if (!mounted) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _load(silent: true);
    }
  }

  void _onTheme() {
    final t = ChatThemeStore.current.value;
    if (mounted && t.key != _theme.key) {
      setState(() => _theme = t);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(silent: true);
  }

  Future<void> _load({bool first = false, bool silent = false}) async {
    if (_busy) return;
    _busy = true;
    try {
      final session = await ChatService.instance.session(
        doctorId: _doctorId,
        patientPhone: _patientPhone,
      );
      if (!mounted) return;
      setState(() {
        if (session != null) {
          _session = session;
          _failure = '';
        } else if (_session == null) {
          _failure = ChatService.instance.lastError;
        }
        _loading = false;
      });
      if (session != null && (first || !silent)) {
        unawaited(ChatService.instance.refreshUnread());
      }
    } finally {
      _busy = false;
    }
  }

  void _snack(String message) {
    if (!mounted || message.trim().isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.cairo(fontWeight: FontWeight.w700),
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending || _uploading) return;
    await _send(body: text);
  }

  Future<void> _send({
    String body = '',
    String imageUrl = '',
  }) async {
    if (_sending) return;
    setState(() => _sending = true);
    final result = await ChatService.instance.send(
      doctorId: _doctorId,
      patientPhone: _patientPhone,
      body: body,
      imageUrl: imageUrl,
      replyTo: _replyTo?.id,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (!result.ok) {
      _snack(result.error);
      return;
    }
    unawaited(ChatSound.sent());
    _text.clear();
    setState(() => _replyTo = null);
    await _load(silent: true);
  }

  Future<void> _pickImage() async {
    if (_sending || _uploading) return;
    XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2560,
        imageQuality: 100,
      );
    } catch (e) {
      _snack('تعذّر فتح الاستوديو');
      return;
    }
    if (file == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final raw = await file.readAsBytes();
      final url = await ChatService.instance.uploadPhoto(raw);
      if (!mounted) return;
      if (url == null) {
        setState(() => _uploading = false);
        _snack(ChatService.instance.lastError);
        return;
      }
      final caption = _text.text.trim();
      await _send(body: caption, imageUrl: url);
    } catch (_) {
      if (!mounted) return;
      _snack('تعذّر إرسال الصورة');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete(ChatMessage m, {required bool all}) async {
    if (all) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            'حذف من الطرفين؟',
            style: GoogleFonts.cairo(fontWeight: FontWeight.w900),
          ),
          content: Text(
            'ستُحذف الرسالة نهائياً من عندك وعند الطرف الآخر ولا يمكن التراجع.',
            style: GoogleFonts.cairo(height: 1.7),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('إلغاء', style: GoogleFonts.cairo()),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'حذف',
                style: GoogleFonts.cairo(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final result = await ChatService.instance.delete(m.id, all: all);
    if (!mounted) return;
    if (!result.ok) {
      _snack(result.error);
      return;
    }
    await _load(silent: true);
  }

  void _showActions(ChatMessage m) {
    /// المراجع لا يحذف رسائل العيادة إطلاقاً — والقاعدة ترفض ذلك أيضاً؛
    /// فلا يُعرض له إلا الرد على رسائل العيادة.
    final clinic = _session?.clinicViewer ?? false;
    final mayDelete = m.mine || clinic;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.reply_rounded, color: AppColors.primary),
                title: Text('رد على الرسالة', style: GoogleFonts.cairo()),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() => _replyTo = m);
                },
              ),
              if (mayDelete)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.textSecondary,
                  ),
                  title: Text('حذف من عندي', style: GoogleFonts.cairo()),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _delete(m, all: false);
                  },
                ),
              if (m.mine)
                ListTile(
                  leading: const Icon(
                    Icons.delete_forever_rounded,
                    color: AppColors.danger,
                  ),
                  title: Text(
                    'حذف من الطرفين',
                    style: GoogleFonts.cairo(
                      color: AppColors.danger,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _delete(m, all: true);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showImage(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(10),
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: AppImage(url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  /// النقر على الاسم أو الصورة: المراجع يرى بروفايل الطبيب، والعيادة
  /// ترى بطاقة المراجع (اسمه ورقمه وحالته).
  Future<void> _openPeerProfile() async {
    final s = _session;
    if (s == null) return;
    if (s.clinicViewer) {
      _showPatientProfile(
        s.patient,
        online: s.peerActiveNow,
        lastSeen: s.peerLastSeenAt,
      );
      return;
    }
    final doctor = await _findDoctor(s.doctor.id);
    if (!mounted) return;
    if (doctor == null) {
      _snack('تعذّر فتح بروفايل الطبيب');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DoctorProfileScreen(doctor: doctor),
      ),
    );
  }

  Future<DoctorProfile?> _findDoctor(String id) async {
    final svc = DoctorDirectoryService.instance;
    for (final d in svc.memory ?? const <DoctorProfile>[]) {
      if (d.id == id) return d;
    }
    for (final d in await svc.fetch()) {
      if (d.id == id) return d;
    }
    for (final d in await svc.fetch(force: true)) {
      if (d.id == id) return d;
    }
    return null;
  }

  void _showPatientProfile(
    ChatPeer p, {
    required bool online,
    DateTime? lastSeen,
  }) {
    final status = online
        ? 'متصل الآن'
        : (lastSeen != null
            ? 'آخر ظهور ${chatLastSeenLabel(lastSeen)}'
            : 'غير متصل');
    final url = p.image.trim().isEmpty ? '' : AppImage.resolve(p.image);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: 72,
                height: 72,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  color: AppColors.primaryLight,
                  shape: BoxShape.circle,
                ),
                child: url.isEmpty
                    ? const Icon(
                        Icons.person_outline_rounded,
                        size: 36,
                        color: AppColors.primaryDark,
                      )
                    : AppImage(url, fit: BoxFit.cover),
              ),
              const SizedBox(height: 10),
              Text(
                p.displayName,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (p.phone.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  p.phone,
                  textDirection: TextDirection.ltr,
                  style: GoogleFonts.cairo(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: online ? AppColors.success : AppColors.textHint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status,
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: online ? AppColors.primaryDark : AppColors.textHint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// سمات الدردشة: تُطبَّق فوراً وتُحفظ للفتحات القادمة.
  void _pickTheme() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        final active = ChatThemeStore.current.value.key;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    const Icon(Icons.palette_outlined, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'سمة الدردشة',
                      style: GoogleFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'تُحفظ تلقائياً',
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              ...ChatTheme.all.map(
                (t) => ListTile(
                  leading: _ThemeSwatch(theme: t),
                  title: Text(
                    t.name,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  trailing: t.key == active
                      ? const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.primary,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    ChatThemeStore.save(t);
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// ★ اسم الطرف الآخر داخل العيادة (تصحيح ٢٠٢٦-١١-٢٥): الطبيب يرى اسم
  ///   حساب الممرضة، والممرضة ترى اسم حساب الطبيب.
  ///
  ///   لا نحكم من أسماء الحقول: البيانات الحيّة فيها الدكتور مسجّلاً في
  ///   `secretary_phone` والممرضة في `phone`، فكان الوسم ينقلب. نقارن
  ///   رقمي الحسابين (آخر ١٠ أرقام، كما تفعل القاعدة) برقمي، ونعرض اسم
  ///   الآخر كما هو في حسابه.
  String _clinicIdentity(ChatSession? s) {
    if (s == null || !s.clinicViewer) return '';
    String last10(String v) {
      final d = v.replaceAll(RegExp(r'[^0-9]'), '');
      return d.length <= 10 ? d : d.substring(d.length - 10);
    }

    final me = last10(AuthService.instance.phone ?? '');
    if (me.isEmpty) return '';
    final secKey = last10(s.secretaryPhone);
    final docKey = last10(s.staffDoctorPhone);
    var other = '';
    if (secKey.isNotEmpty && me == secKey) {
      other = s.staffDoctorName;
    } else if (docKey.isNotEmpty && me == docKey) {
      other = s.secretaryName;
    }
    return other.trim();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final title = (s?.title ?? widget.title).trim().isEmpty
        ? 'الدردشة'
        : (s?.title ?? widget.title);
    final image = (s?.image ?? widget.image);
    final online = s?.online ?? widget.bookingOpen;
    final status = s?.statusText ??
        (widget.bookingOpen ? 'الحجز مفتوح الآن' : 'الحجز مغلق');
    final identity = _clinicIdentity(s);
    final statusLine = identity.isEmpty ? status : '$identity · $status';

    return Scaffold(
      backgroundColor: _theme.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        titleSpacing: 4,
        title: InkWell(
          onTap: _openPeerProfile,
          borderRadius: BorderRadius.circular(10),
          child: Row(
            children: [
              _HeaderAvatar(
                image: image,
                clinic: s == null || !s.clinicViewer,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: online
                                ? const Color(0xFF9CF5A8)
                                : Colors.white54,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            statusLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              height: 1,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'سمة الدردشة',
            onPressed: _pickTheme,
            icon: const Icon(Icons.palette_outlined, color: Colors.white),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Row(
              children: [
                Icon(
                  Icons.lock_clock_outlined,
                  size: 14,
                  color: _theme.mineBubble,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'تُحذف الرسائل والصور نهائياً بعد 24 ساعة',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _theme.otherSub,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _messagesArea()),
          if (_session != null) _composer(),
        ],
      ),
    );
  }

  Widget _messagesArea() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_session == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 70),
          Icon(Icons.wifi_off_rounded, size: 58, color: _theme.otherSub),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _failure.isEmpty ? 'تعذّر فتح المحادثة' : _failure,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 13.5,
                height: 1.7,
                color: _theme.otherSub,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton.icon(
              onPressed: () {
                setState(() => _loading = true);
                _load(first: true);
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text('إعادة المحاولة', style: GoogleFonts.cairo()),
            ),
          ),
        ],
      );
    }

    final messages = _session!.messages;
    if (messages.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(26),
        children: [
          const SizedBox(height: 60),
          Icon(Icons.forum_outlined, size: 58, color: _theme.otherSub),
          const SizedBox(height: 14),
          Center(
            child: Text(
              'ابدأ المحادثة',
              style: GoogleFonts.cairo(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: _theme.otherText,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'اكتب رسالتك أو أرسل صورة من الاستوديو.\nالرسائل تُحذف تلقائياً بعد 24 ساعة.',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(
                fontSize: 12.5,
                height: 1.7,
                color: _theme.otherSub,
              ),
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () => _load(),
      child: ListView.builder(
        reverse: true,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        itemCount: messages.length,
        itemBuilder: (context, i) {
          final m = messages[messages.length - 1 - i];
          return _MessageBubble(
            message: m,
            theme: _theme,
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            onReply: () => setState(() => _replyTo = m),
            onLongPress: () => _showActions(m),
            onImageTap: m.hasImage ? () => _showImage(m.image) : null,
          );
        },
      ),
    );
  }

  Widget _composer() {
    final s = _session!;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTo != null)
              Container(
                margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(10),
                  border: const Border(
                    right: BorderSide(color: AppColors.primary, width: 3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.reply_rounded, size: 17, color: AppColors.primaryDark),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'رد على ${_replyTo!.role == 'clinic' ? 'العيادة' : 'المراجع'}',
                            style: GoogleFonts.cairo(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primaryDark,
                            ),
                          ),
                          Text(
                            _replyTo!.body.trim().isNotEmpty
                                ? _replyTo!.body.trim()
                                : 'صورة',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 11.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _replyTo = null),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  InkWell(
                    onTap: (_sending || _uploading) ? null : _pickImage,
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: AppColors.primaryLight,
                        shape: BoxShape.circle,
                      ),
                      child: _uploading
                          ? const Padding(
                              padding: EdgeInsets.all(11),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.primary,
                              ),
                            )
                          : const Icon(
                              Icons.add_photo_alternate_outlined,
                              color: AppColors.primaryDark,
                              size: 23,
                            ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      enabled: !_sending && !_uploading,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      style: GoogleFonts.cairo(fontSize: 14),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.background,
                        hintText: s.clinicViewer
                            ? 'اكتب ردّك للمراجع…'
                            : 'اكتب رسالتك للعيادة…',
                        hintStyle: GoogleFonts.cairo(
                          fontSize: 13,
                          color: AppColors.textHint,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(color: AppColors.divider),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(
                            color: AppColors.primary,
                            width: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  InkWell(
                    onTap: (_sending || _uploading || _text.text.trim().isEmpty)
                        ? null
                        : _sendText,
                    borderRadius: BorderRadius.circular(23),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color:
                            (_sending ||
                                _uploading ||
                                _text.text.trim().isEmpty)
                            ? AppColors.textHint
                            : AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: _sending
                          ? const Padding(
                              padding: EdgeInsets.all(13),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({required this.image, required this.clinic});

  final String image;
  final bool clinic;

  @override
  Widget build(BuildContext context) {
    final url = image.trim().isEmpty ? '' : AppImage.resolve(image);
    final fallback = Icon(
      clinic
          ? Icons.medical_services_outlined
          : Icons.person_outline_rounded,
      color: AppColors.primaryDark,
      size: 20,
    );
    return Container(
      width: 36,
      height: 36,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: url.isEmpty
          ? fallback
          : AppImage(
              url,
              fit: BoxFit.cover,
              width: 36,
              height: 36,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.theme,
    required this.maxWidth,
    required this.onReply,
    required this.onLongPress,
    this.onImageTap,
  });

  final ChatMessage message;
  final ChatTheme theme;
  final double maxWidth;
  final VoidCallback onReply;
  final VoidCallback onLongPress;
  final VoidCallback? onImageTap;

  @override
  Widget build(BuildContext context) {
    final mine = message.mine;
    final fg = mine ? Colors.white : theme.otherText;
    final sub = mine ? Colors.white.withValues(alpha: 0.75) : theme.otherSub;

    return Align(
      alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          constraints: BoxConstraints(maxWidth: maxWidth),
          decoration: BoxDecoration(
            color: mine ? theme.mineBubble : theme.otherBubble,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 4 : 16),
              bottomRight: Radius.circular(mine ? 16 : 4),
            ),
            border: mine ? null : Border.all(color: theme.otherBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.hasReply) _replyStrip(mine),
              if (message.hasImage)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    message.hasReply ? 6 : 4,
                    message.hasReply ? 4 : 4,
                    message.hasReply ? 6 : 4,
                    message.body.trim().isEmpty ? 4 : 2,
                  ),
                  child: GestureDetector(
                    onTap: onImageTap,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AppImage(
                        AppImage.resolve(message.image),
                        width: 230,
                        height: 230,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 210,
                          height: 150,
                          color: mine ? Colors.white24 : AppColors.primaryLight,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: fg,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (message.body.trim().isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(11, 8, 11, 4),
                  child: Text(
                    message.body,
                    style: GoogleFonts.cairo(
                      fontSize: 13.5,
                      height: 1.55,
                      color: fg,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 0, 4, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${chatMsgDate(message.at)} · ${chatMsgTime(message.at)}',
                      style: GoogleFonts.cairo(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: sub,
                      ),
                    ),
                    if (mine) ...[
                      const SizedBox(width: 4),
                      Icon(
                        message.isRead
                            ? Icons.done_all_rounded
                            : Icons.check_rounded,
                        size: 14,
                        color: message.isRead
                            ? const Color(0xFF64B5F6)
                            : sub,
                      ),
                    ],
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: onReply,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.reply_rounded, size: 15, color: sub),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _replyStrip(bool mine) {
    final body = message.replyBody.trim();
    final hasImage = message.replyImage.trim().isNotEmpty;
    final label = body.isNotEmpty ? body : (hasImage ? 'صورة' : 'رسالة محذوفة');
    final who = message.replyRole == 'clinic' ? 'العيادة' : 'المراجع';
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: mine ? Colors.white.withValues(alpha: 0.18) : theme.tint,
        borderRadius: BorderRadius.circular(9),
        border: Border(
          right: BorderSide(
            color: mine ? Colors.white70 : theme.mineBubble,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            who,
            style: GoogleFonts.cairo(
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              color: mine ? Colors.white : theme.mineBubble,
            ),
          ),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.cairo(
              fontSize: 10.5,
              color: mine
                  ? Colors.white.withValues(alpha: 0.9)
                  : theme.otherText.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// مصغّر سمة: خلفية المحادثة ولونا الفقاعتين.
class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.theme});

  final ChatTheme theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 32,
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: theme.otherBorder),
      ),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: theme.mineBubble,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: theme.otherBubble,
                shape: BoxShape.circle,
                border: Border.all(color: theme.otherBorder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
