import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'supabase_service.dart';

/// رسالة في دردشة العيادة — محذوفة نهائياً بعد 24 ساعة في القاعدة.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.body,
    required this.image,
    required this.replyTo,
    required this.replyBody,
    required this.replyImage,
    required this.replyRole,
    required this.role,
    required this.mine,
    required this.at,
    required this.readAt,
  });

  final String id;
  final String body;
  final String image;
  final String replyTo;
  final String replyBody;
  final String replyImage;
  final String replyRole;

  /// `patient` أو `clinic`.
  final String role;
  final bool mine;
  final DateTime? at;

  /// لحظة فتح الطرف الآخر للمحادثة وقراءته الرسالة — null = لم تُقرأ بعد.
  final DateTime? readAt;

  bool get isRead => readAt != null;

  bool get hasImage => image.trim().isNotEmpty;
  bool get hasReply => replyTo.isNotEmpty;

  factory ChatMessage.fromJson(Map<String, dynamic> m) {
    String t(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s == 'null' ? '' : s;
    }

    return ChatMessage(
      id: t(m['id']),
      body: t(m['body']),
      image: t(m['image']),
      replyTo: t(m['reply_to']),
      replyBody: t(m['reply_body']),
      replyImage: t(m['reply_image']),
      replyRole: t(m['reply_role']),
      role: t(m['role']),
      mine: m['mine'] == true,
      at: DateTime.tryParse(t(m['at'])),
      readAt: DateTime.tryParse(t(m['read_at'])),
    );
  }
}

/// طرف المحادثة: العيادة أو المراجع.
class ChatPeer {
  const ChatPeer({
    required this.id,
    required this.phone,
    required this.name,
    required this.image,
    required this.bookingOpen,
    required this.online,
    this.lastSeen,
  });

  final String id;
  final String phone;
  final String name;
  final String image;
  final bool bookingOpen;
  final bool online;

  /// آخر نبضة حضور من القاعدة (آخر ظهور) — null = لا صف حضور بعد.
  final DateTime? lastSeen;

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    if (phone.trim().isNotEmpty) return phone.trim();
    return 'عيادة';
  }

  factory ChatPeer.doctor(Map<String, dynamic>? m) {
    if (m == null) return const ChatPeer(id: '', phone: '', name: '', image: '', bookingOpen: false, online: false);
    return ChatPeer(
      id: (m['id'] ?? '').toString(),
      phone: '',
      name: (m['name'] ?? '').toString(),
      image: (m['image'] ?? '').toString(),
      bookingOpen: m['booking_open'] == true,
      online: m['online'] == true,
      lastSeen: DateTime.tryParse('${m['last_seen'] ?? ''}'),
    );
  }

  factory ChatPeer.patient(Map<String, dynamic>? m) {
    if (m == null) return const ChatPeer(id: '', phone: '', name: '', image: '', bookingOpen: false, online: false);
    return ChatPeer(
      id: '',
      phone: (m['phone'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      image: (m['image'] ?? '').toString(),
      bookingOpen: false,
      online: m['online'] == true,
      lastSeen: DateTime.tryParse('${m['last_seen'] ?? ''}'),
    );
  }
}

/// محادثة واحدة كما تعرضها القائمة.
class ChatThread {
  const ChatThread({
    required this.side,
    required this.doctorId,
    required this.doctorName,
    required this.doctorImage,
    required this.patientPhone,
    required this.patientName,
    required this.patientImage,
    required this.lastBody,
    required this.lastImage,
    required this.lastRole,
    required this.lastAt,
    required this.unread,
    required this.bookingOpen,
    required this.patientOnline,
    this.patientLastSeen,
  });

  final String side;
  final String doctorId;
  final String doctorName;
  final String doctorImage;
  final String patientPhone;
  final String patientName;
  final String patientImage;
  final String lastBody;
  final String lastImage;
  final String lastRole;
  final DateTime? lastAt;
  final int unread;
  final bool bookingOpen;
  final bool patientOnline;

  /// آخر نبضة حضور للمراجع من القاعدة — null = لا صف حضور بعد.
  final DateTime? patientLastSeen;

  bool get clinicViewer => side == 'clinic';

  String get title => clinicViewer
      ? (patientName.trim().isNotEmpty ? patientName.trim() : patientPhone)
      : doctorName;

  String get image => clinicViewer ? patientImage : doctorImage;

  /// آخر نشاط معروف للمراجع: حضور القاعدة أولاً (فتح/إغلاق تطبيقه)،
  /// ثم ما رصدناه محلياً من رسائله.
  DateTime? get peerLastSeenAt {
    if (!clinicViewer) return null;
    DateTime? at = patientLastSeen;
    if (lastRole == 'patient' && lastAt != null) {
      if (at == null || lastAt!.isAfter(at)) at = lastAt;
    }
    final cached = ChatPresence.of(doctorId, patientPhone);
    if (cached != null && (at == null || cached.isAfter(at))) at = cached;
    return at;
  }

  /// متصل الآن: إعلان القاعدة (تطبيق مفتوح)، وإلا نشاط رُصد خلال دقيقتين
  /// — والحدّ المحلي للحسابات القديمة التي لا تُرسل نبضة حضور.
  bool get peerActiveNow {
    if (patientOnline) return true;
    if (patientLastSeen != null) return false;
    final at = peerLastSeenAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(minutes: 2);
  }

  /// حالة الطرف الآخر أمام العيادة: نشاط حقيقي لا مجرد توكن جهاز.
  bool get online => clinicViewer ? peerActiveNow : bookingOpen;

  String get statusText {
    if (clinicViewer) {
      if (peerActiveNow) return 'متصل الآن';
      final at = peerLastSeenAt;
      if (at != null) return 'آخر ظهور ${chatLastSeenLabel(at)}';
      return 'غير متصل';
    }
    return bookingOpen ? 'الحجز مفتوح الآن' : 'الحجز مغلق';
  }

  String get preview {
    final text = lastBody.trim();
    final mine = lastRole == side;
    final core = text.isNotEmpty ? text : (lastImage.trim().isNotEmpty ? 'صورة' : '');
    return mine && core.isNotEmpty ? 'أنت: $core' : core;
  }

  factory ChatThread.fromJson(Map<String, dynamic> m, String side) {
    String t(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s == 'null' ? '' : s;
    }

    return ChatThread(
      side: side,
      doctorId: t(m['doctor_id']),
      doctorName: t(m['doctor_name']),
      doctorImage: t(m['doctor_image']),
      patientPhone: t(m['patient_phone']),
      patientName: t(m['patient_name']),
      patientImage: t(m['patient_image']),
      lastBody: t(m['last_body']),
      lastImage: t(m['last_image']),
      lastRole: t(m['last_role']),
      lastAt: DateTime.tryParse(t(m['last_at'])),
      unread: (m['unread'] is num) ? (m['unread'] as num).toInt() : 0,
      bookingOpen: m['booking_open'] == true,
      patientOnline: m['patient_online'] == true,
      patientLastSeen: DateTime.tryParse('${m['patient_last_seen'] ?? ''}'),
    );
  }
}

/// محتوى شاشة المحادثة: الطرفان والرسائل.
class ChatSession {
  const ChatSession({
    required this.side,
    required this.doctor,
    required this.patient,
    required this.messages,
    this.secretaryName = '',
    this.secretaryPhone = '',
    this.staffDoctorName = '',
    this.staffDoctorPhone = '',
  });

  final String side;
  final ChatPeer doctor;
  final ChatPeer patient;
  final List<ChatMessage> messages;

  /// اسم سكرتير/ممرض العيادة — يصل للطبيب وحده (من القاعدة).
  final String secretaryName;
  final String secretaryPhone;

  /// ★ أسماء حسابَي العيادة كما هي في `users` — لحساب طرف آخر موحّد
  ///   (٢٠٢٦-١١-٢٥): قد يكون الدكتور مسجّلاً في `secretary_phone`
  ///   والممرضة في `phone`، فلا يصحّ الحكم بأسماء الحقول؛ نقارن رقمي
  ///   الحسابين برقمي وأعرض اسم الآخر. تصل لحسابات العيادة وحدها.
  final String staffDoctorName;
  final String staffDoctorPhone;

  bool get clinicViewer => side == 'clinic';

  String get title => clinicViewer ? patient.displayName : doctor.displayName;
  String get image => clinicViewer ? patient.image : doctor.image;

  /// آخر نشاط معروف للمراجع: حضور القاعدة (فتح/إغلاق تطبيقه) أولاً،
  /// ثم وقت رسالته أو لحظة قراءته رسائلي — لا طلب شبكة إضافي.
  DateTime? get peerLastSeenAt {
    if (!clinicViewer) return null;
    DateTime? at = patient.lastSeen;
    for (final m in messages) {
      final t = m.mine ? m.readAt : m.at;
      if (t == null) continue;
      if (at == null || t.isAfter(at)) at = t;
    }
    return at;
  }

  /// متصل الآن: إعلان القاعدة، وإلا نشاط رُصد خلال دقيقتين (للحسابات
  /// القديمة التي لا تُرسل نبضة حضور).
  bool get peerActiveNow {
    if (patient.online) return true;
    if (patient.lastSeen != null) return false;
    final at = peerLastSeenAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(minutes: 2);
  }

  bool get online => clinicViewer ? peerActiveNow : doctor.bookingOpen;
  String get statusText {
    if (clinicViewer) {
      if (peerActiveNow) return 'متصل الآن';
      final at = peerLastSeenAt;
      if (at != null) return 'آخر ظهور ${chatLastSeenLabel(at)}';
      return 'غير متصل';
    }
    return doctor.bookingOpen ? 'الحجز مفتوح الآن' : 'الحجز مغلق';
  }
}

class ChatSendResult {
  const ChatSendResult({required this.ok, this.error = ''});
  final bool ok;
  final String error;
}

/// آخر نشاط حقيقي للطرف الآخر — محفوظ على **الجهاز وحده**.
///
/// لماذا محلياً: «آخر ظهور» يُستخرج من بيانات المحادثة التي نجلبها
/// أصلاً (وقت رسالة الطرف الآخر، أو وقت قراءته رسائلي) فلا كتابة
/// ولا استعلاماً إضافياً على السيرفر أو القاعدة. والكاش يحفظ ما
/// رصدناه لتبقى قائمة المحادثات صحيحة حين تكون آخر رسالة منّي —
/// فآخر رسالة في القائمة لا تحمل وقت نشاطه.
class ChatPresence {
  ChatPresence._();

  static const String _prefsKey = 'chat_last_seen_v1';
  static final Map<String, DateTime> _seen = <String, DateTime>{};
  static bool _loaded = false;
  static bool _dirty = false;
  static DateTime _lastSaveAt = DateTime.fromMillisecondsSinceEpoch(0);

  static String _key(String doctorId, String patientPhone) =>
      '${doctorId.trim()}|${patientPhone.trim()}';

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      m.forEach((k, v) {
        final at = DateTime.tryParse('$v');
        if (at != null) _seen['$k'] = at;
      });
    } catch (_) {}
  }

  static DateTime? of(String doctorId, String patientPhone) {
    if (doctorId.isEmpty || patientPhone.isEmpty) return null;
    return _seen[_key(doctorId, patientPhone)];
  }

  /// يسجّل نشاطاً أحدث للطرف الآخر — ذاكرة + ملف محلي، بلا أي طلب شبكة.
  ///
  /// لا يتغيّر شيء ولا يُحفظ ملف عند دخول التطبيق: الحفظ يقع فقط حين
  /// يصل نشاط أحدث، ومخفوضاً مرة كل ~20 ثانية.
  static Future<void> observe(
    String doctorId,
    String patientPhone,
    DateTime? at,
  ) async {
    if (doctorId.isEmpty || patientPhone.isEmpty || at == null) return;
    await load();
    final k = _key(doctorId, patientPhone);
    final old = _seen[k];
    if (old == null || at.isAfter(old)) {
      _seen[k] = at;
      _dirty = true;
    }
    if (!_dirty) return;
    if (DateTime.now().difference(_lastSaveAt) < const Duration(seconds: 20)) {
      return;
    }
    _dirty = false;
    _lastSaveAt = DateTime.now();
    try {
      // سقف الذاكرة: أقدم المدخلات تُطرح.
      if (_seen.length > 400) {
        final sorted = _seen.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final e in sorted.take(_seen.length - 400)) {
          _seen.remove(e.key);
        }
      }
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _prefsKey,
        jsonEncode(
          _seen.map((k, v) => MapEntry(k, v.toUtc().toIso8601String())),
        ),
      );
    } catch (_) {
      _dirty = true;
    }
  }
}

/// صياغة «آخر ظهور»: اليوم/أمس بالساعة، ثم تاريخ قصير.
String chatLastSeenLabel(DateTime? at) {
  if (at == null) return '';
  final local = at.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  final h12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final mm = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'صباحاً' : 'مساءً';
  final hm = '$h12:$mm $period';
  if (diff <= 0) return 'اليوم $hm';
  if (diff == 1) return 'أمس $hm';
  if (local.year == now.year) return '${local.day}/${local.month}';
  return '${local.day}/${local.month}/${local.year}';
}

/// خدمة الدردشة: قوائم المحادثات والرسائل والإرسال والحذف وضغط الصور.
///
/// كل النداءات تمرّ بدوال القاعدة المحمية (`SQL_DOCTOR_CHAT.sql`)؛
/// لا قراءة مباشرة لجدول الرسائل.
class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  /// عمر الرسالة: ٢٤ ساعة ثم لا تظهر ولا تبقى — حتى قبل أن تصل دورة
  /// الحذف الخادمية، فلا يعرض الجهاز رسالة منتهية أبداً.
  static const Duration retention = Duration(hours: 24);

  /// مجموع غير المقروء — شارة أيقونة الدردشة.
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  /// نبضة «وصلت رسالة الآن» — يطلقها مركز الإشعارات حين يستهلك صفّ
  /// دردشة جديداً، فتشحن شاشة المحادثة وقائمتها فوراً بدل انتظار
  /// الاستطلاع الدوري (4/20 ثانية).
  final ValueNotifier<int> wake = ValueNotifier<int>(0);

  void noteIncoming() {
    wake.value++;
    unawaited(refreshUnread());
  }

  /// `clinic` أو `patient` حسب آخر قراءة.
  String role = '';

  String lastError = '';

  Timer? _poll;
  bool _purgeSent = false;

  /// يبدأ استطلاع شارة غير المقروء مرة واحدة طوال عمر التطبيق.
  void startPolling() {
    if (_poll != null) return;
    unawaited(refreshUnread());
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(refreshUnread());
    });
  }

  /// حذف الرسائل المنتهية (24 ساعة) — مرة واحدة عند أول استخدام.
  Future<void> purgeOnce() async {
    if (_purgeSent) return;
    _purgeSent = true;
    await SupabaseService.instance.rpcCall('doctor_chat_purge', const {'p_hours': 24});
  }

  Future<void> refreshUnread() async {
    if (!AuthService.instance.isLoggedIn) {
      unread.value = 0;
      return;
    }
    unawaited(purgeOnce());
    final raw = await SupabaseService.instance.rpcCall('doctor_chat_unread', const {});
    if (raw is! Map) {
      unread.value = 0;
      return;
    }
    final m = Map<String, dynamic>.from(raw);
    if (m['ok'] != true) {
      unread.value = 0;
      return;
    }
    role = (m['role'] ?? role).toString();
    final count = m['count'];
    unread.value = count is num ? count.toInt() : 0;
  }

  Future<List<ChatThread>?> threads() async {
    lastError = '';
    // آخر ظهور المحفوظ على الجهاز (لا طلب شبكة: ملف محلي فقط).
    await ChatPresence.load();
    final raw = await SupabaseService.instance.rpcCall('doctor_chat_threads', const {});
    if (raw is! Map) {
      lastError = SupabaseService.instance.lastRpcError ?? 'تعذّر جلب المحادثات';
      return null;
    }
    final m = Map<String, dynamic>.from(raw);
    if (m['ok'] != true) {
      lastError = (m['error'] ?? 'تعذّر جلب المحادثات').toString();
      return null;
    }
    role = (m['role'] ?? 'patient').toString();
    final cutoff = DateTime.now().subtract(retention);
    final list = (m['threads'] as List?) ?? const [];
    final threads = list
        .whereType<Map>()
        .map((e) => ChatThread.fromJson(Map<String, dynamic>.from(e), role))
        .where((t) => t.lastAt == null || t.lastAt!.isAfter(cutoff))
        .toList();
    unread.value = threads.fold<int>(0, (sum, t) => sum + t.unread);
    return threads;
  }

  Future<ChatSession?> session({
    required String doctorId,
    String? patientPhone,
  }) async {
    lastError = '';
    final raw = await SupabaseService.instance.rpcCall(
      'doctor_chat_messages',
      {
        'p_doctor_id': doctorId,
        'p_patient_phone': patientPhone,
      },
    );
    if (raw is! Map) {
      lastError = SupabaseService.instance.lastRpcError ?? 'تعذّر جلب الرسائل';
      return null;
    }
    final m = Map<String, dynamic>.from(raw);
    if (m['ok'] != true) {
      lastError = (m['error'] ?? 'تعذّر جلب الرسائل').toString();
      return null;
    }
    role = (m['side'] ?? role).toString();
    final list = (m['messages'] as List?) ?? const [];
    final sec = m['secretary'] is Map
        ? Map<String, dynamic>.from(m['secretary'] as Map)
        : const <String, dynamic>{};
    final staff = m['staff'] is Map
        ? Map<String, dynamic>.from(m['staff'] as Map)
        : const <String, dynamic>{};
    final session = ChatSession(
      side: role,
      doctor: ChatPeer.doctor(
        m['doctor'] is Map ? Map<String, dynamic>.from(m['doctor'] as Map) : null,
      ),
      patient: ChatPeer.patient(
        m['patient'] is Map ? Map<String, dynamic>.from(m['patient'] as Map) : null,
      ),
      secretaryName: (sec['name'] ?? '').toString().trim(),
      secretaryPhone: (sec['phone'] ?? '').toString().trim(),
      staffDoctorName: (staff['doctor_name'] ?? '').toString().trim(),
      staffDoctorPhone: (staff['doctor_phone'] ?? '').toString().trim(),
      messages: list
          .whereType<Map>()
          .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
          .where(
            (msg) =>
                msg.at == null ||
                msg.at!.isAfter(DateTime.now().subtract(retention)),
          )
          .toList(),
    );
    // ★ آخر ظهور حقيقي للمراجع: يُرصد من رسائله ولحظات قراءته داخل
    //   نفس الردّ — يُحفظ محلياً فقط لتظهر به قائمة المحادثات لاحقاً.
    if (session.clinicViewer) {
      unawaited(
        ChatPresence.observe(
          session.doctor.id,
          session.patient.phone,
          session.peerLastSeenAt,
        ),
      );
    }
    return session;
  }

  Future<ChatSendResult> send({
    required String doctorId,
    String? patientPhone,
    String body = '',
    String imageUrl = '',
    String? replyTo,
  }) async {
    final raw = await SupabaseService.instance.rpcCall(
      'doctor_chat_send',
      {
        'p_doctor_id': doctorId,
        'p_patient_phone': patientPhone,
        'p_body': body,
        'p_image_url': imageUrl,
        'p_reply_to': replyTo,
      },
    );
    if (raw is! Map) {
      return ChatSendResult(
        ok: false,
        error: SupabaseService.instance.lastRpcError ?? 'تعذّر إرسال الرسالة',
      );
    }
    final m = Map<String, dynamic>.from(raw);
    if (m['ok'] == true) {
      unawaited(refreshUnread());
      return const ChatSendResult(ok: true);
    }
    return ChatSendResult(
      ok: false,
      error: (m['error'] ?? 'تعذّر إرسال الرسالة').toString(),
    );
  }

  /// [all] = حذف من الطرفين (لصاحب الرسالة)، وإلا حذف من عندي فقط.
  Future<ChatSendResult> delete(String messageId, {bool all = false}) async {
    final raw = await SupabaseService.instance.rpcCall(
      'doctor_chat_delete',
      {'p_message_id': messageId, 'p_scope': all ? 'all' : 'me'},
    );
    if (raw is! Map) {
      return ChatSendResult(
        ok: false,
        error: SupabaseService.instance.lastRpcError ?? 'تعذّر حذف الرسالة',
      );
    }
    final m = Map<String, dynamic>.from(raw);
    if (m['ok'] == true) {
      unawaited(refreshUnread());
      return const ChatSendResult(ok: true);
    }
    return ChatSendResult(
      ok: false,
      error: (m['error'] ?? 'تعذّر حذف الرسالة').toString(),
    );
  }

  /// ضغط الصورة قبل الرفع: فكّ اتجاه التصوير، تصغير أكبر ضلع إلى 1280،
  /// ثم JPEG بجودة 72 — يقلّل الحجم كثيراً مع بقاء الصورة واضحة.
  static Uint8List compress(Uint8List raw) {
    try {
      var decoded = img.decodeImage(raw);
      if (decoded == null) return raw;
      decoded = img.bakeOrientation(decoded);
      const maxSide = 1280;
      if (decoded.width > maxSide || decoded.height > maxSide) {
        decoded = decoded.width >= decoded.height
            ? img.copyResize(
                decoded,
                width: maxSide,
                interpolation: img.Interpolation.linear,
              )
            : img.copyResize(
                decoded,
                height: maxSide,
                interpolation: img.Interpolation.linear,
              );
      }
      return Uint8List.fromList(img.encodeJpg(decoded, quality: 72));
    } catch (_) {
      return raw;
    }
  }

  /// يضغط الصورة ويرفعها ويعيد رابطها العام (أو null مع سبب في [lastError]).
  Future<String?> uploadPhoto(Uint8List raw) async {
    lastError = '';
    final compressed = compress(raw);
    final url = await SupabaseService.instance.uploadImage(
      compressed,
      folder: 'chat',
      mimeType: 'image/jpeg',
      extension: 'jpg',
    );
    if (url == null || url.isEmpty) {
      lastError = SupabaseService.instance.lastUploadError ?? 'تعذّر رفع الصورة';
      return null;
    }
    return url;
  }
}
