import '../widgets/app_image.dart';

/// طبيب/مجمع/مختبر كما في جدول `doctors` — صفّ عرض عام للدليل.
///
/// القراءة عامة، والكتابة من لوحة الأدمن وحدها عبر سياسات
/// `(select public.admin_gate())` في tmp/doctors_table.sql.
class DoctorProfile {
  const DoctorProfile({
    required this.id,
    required this.name,
    required this.title,
    required this.specialty,
    required this.info,
    required this.phone,
    required this.imagePath,
    required this.area,
    this.city = '',
    required this.category,
    required this.isFeatured,
    required this.isHero,
    this.verified = false,
    this.localAsset,
    this.bio = '',
    this.workingHours = '',
    this.notes = '',
    this.clinicAddress = '',
    this.facebookUrl = '',
    this.coverUrl = '',
  });

  factory DoctorProfile.fromJson(Map<String, dynamic> json) {
    String t(Object? v) {
      final s = v?.toString().trim() ?? '';
      return s.isEmpty || s == 'null' ? '' : s;
    }

    final image = t(json['image_path']);
    final isBundled = image.startsWith('asset:');
    // ★ مفتاح القسم كما في `doctor_categories` حرفياً — كان يُقصَر على
    //   complexes/labs وكل ما سواهما يعود «doctors»، فطبيب يضيفه الأدمن
    //   في «تجهيزات طبية» أو «مكملات غذائية» لا يظهر في شريحته أبداً
    //   ويظهر خطأً في «الأطباء» (بلاغ 2026-11-20). الفراغ وحده يعني
    //   الصفوف القديمة بلا قسم ⇒ «الأطباء».
    final category = t(json['category']);

    return DoctorProfile(
      id: t(json['id']),
      name: t(json['name']),
      title: t(json['title']),
      specialty: t(json['specialty']),
      info: t(json['info']),
      phone: t(json['phone']),
      imagePath: isBundled ? '' : image,
      area: t(json['area']),
      city: t(json['city']),
      category: category.isEmpty ? 'doctors' : category,
      isFeatured: json['is_featured'] == true,
      isHero: json['is_hero'] == true,
      verified: json['is_verified'] == true,
      localAsset: isBundled ? image.substring(6) : null,
      bio: t(json['bio']),
      workingHours: t(json['working_hours']),
      notes: t(json['notes']),
      clinicAddress: t(json['clinic_address']),
      facebookUrl: t(json['facebook_url']),
      coverUrl: t(json['cover_url']),
    );
  }

  /// نسخة بحقول الملف المهني الجديدة — يستعملها تعديل صاحب الحساب/الأدمن
  /// من داخل البروفايل، فيتحدّث العرض فوراً بلا إعادة جلب كل الدليل.
  DoctorProfile copyWith({
    String? imagePath,
    String? bio,
    String? workingHours,
    String? notes,
    String? clinicAddress,
  }) {
    return DoctorProfile(
      id: id,
      name: name,
      title: title,
      specialty: specialty,
      info: info,
      phone: phone,
      imagePath: imagePath ?? this.imagePath,
      area: area,
      city: city,
      category: category,
      isFeatured: isFeatured,
      isHero: isHero,
      verified: verified,
      localAsset: localAsset,
      bio: bio ?? this.bio,
      workingHours: workingHours ?? this.workingHours,
      notes: notes ?? this.notes,
      clinicAddress: clinicAddress ?? this.clinicAddress,
      facebookUrl: facebookUrl,
      coverUrl: coverUrl,
    );
  }

  final String id;
  final String name;

  /// اللقب/البورد — السطر الثاني تحت الاسم في البطاقة.
  final String title;
  final String specialty;

  /// سطر تعريفي إضافي (مثل «مجمع بوابة الطب»).
  final String info;

  /// رقم الاتصال المباشر — زر الاتصال يظهر فقط حين يوجد.
  final String phone;
  final String imagePath;
  final String area;

  /// المدينة التي يظهر الطبيب تحتها في فلتر الدليل: «الشطرة» أو «الناصرية».
  /// فارغة = غير محدَّد بعد (يظهر في المدينتين حتى يضبطه الأدمن).
  final String city;

  /// `doctors` | `complexes` | `labs` — فئات شريط الدليل الثلاث.
  final String category;
  final bool isFeatured;
  final bool isHero;

  /// الشارة الزرقاء بجانب الاسم (حساب موثّق) — كما في المرجع.
  final bool verified;

  /// صورة داخلية للحزمة (الدليل المرجعي المدمج قبل تشغيل SQL).
  final String? localAsset;

  /// نبذة مهنية ووقت دوام رسمي وملاحظات — أعمدة بروفايل الطبيب.
  final String bio;
  final String workingHours;
  final String notes;

  /// عنوان العيادة كما يكتبه الأدمن.
  final String clinicAddress;

  /// رابط صفحة الطبيب على فيسبوك (اختياري).
  final String facebookUrl;

  /// غلاف البروفايل — يضعه الأدمن وحده من «إدارة الأطباء»
  /// (tmp/doctors_cover.sql). فارغ = بلا غلاف.
  final String coverUrl;

  /// العنوان المعروض: عنوان العيادة، وإلا السطر التعريفي، وإلا المنطقة.
  String get displayAddress {
    if (clinicAddress.isNotEmpty) return clinicAddress;
    if (info.isNotEmpty) return info;
    return area;
  }

  /// رابط التواصل كاملاً — أي مخطط (viber:// أو tg://...) يُترك كما هو،
  /// وما كُتب بلا مخطط يُكمَّل بـ https.
  String get facebookHref {
    final u = facebookUrl.trim();
    if (u.isEmpty) return '';
    return u.contains('://') ? u : 'https://$u';
  }

  /// رابط الصورة الكامل عبر كاش التطبيق الموحّد، أو null بلا صورة.
  String? get imageUrl {
    final p = imagePath;
    if (p.isEmpty) return null;
    return AppImage.resolve(p);
  }

  /// رابط الغلاف الكامل، أو null بلا غلاف.
  String? get coverImageUrl {
    final c = coverUrl.trim();
    if (c.isEmpty) return null;
    return AppImage.resolve(c);
  }

  /// تسمية السطر التعريفي: التخصص إن وُجد، وإلا اسم الفئة نفسها بدل
  /// وصف مجمع طبي أو مختبر بأنه «طبيب».
  String get specialtyLabel {
    if (specialty.isNotEmpty) return specialty;
    switch (category) {
      case 'complexes':
        return 'مجمع طبي';
      case 'labs':
        return 'مختبر طبي';
      default:
        return 'طبيب';
    }
  }
}
