import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../core/theme/app_colors.dart';
import '../services/local_image_store.dart';
import '../services/supabase_service.dart';
import 'app_image.dart';

/// ★ حقيبة الصور التي رُفعت داخل نموذج واحد.
///
/// **لماذا؟** الصورة تُرفع إلى السحابة **قبل** الحفظ في القاعدة (هذا تصميم
/// رافع الصور عندنا). فإذا رفع الأدمن صورة ثم ألغى النافذة، أو فشل الإدراج،
/// بقي الملف في السحابة يتيمًا بلا أي صف يشير إليه — يطلبه الطلب التالي
/// فيتراكم. الحقيبة تسجّل كل ما رُفع، فيُقرر الأهل: `keep()` عند نجاح
/// الحفظ، أو `discard()` عند الإلغاء/الفشل فيحذف الملفات من السحابة.
class AdminUploads {
  final List<String> _urls = <String>[];
  bool _kept = false;

  void add(String url) {
    if (url.isNotEmpty && !_urls.contains(url)) _urls.add(url);
  }

  /// أُلغي من الحقيبة لأنها حُذفت مباشرة (مسح صريح أو استبدال).
  void remove(String url) => _urls.remove(url);

  /// الصورة صارت مرجعًا في صف محفوظ ⇒ لا تمسحها.
  void keep() => _kept = true;

  /// ★ امسح كل ما رُفع ولم يُعتمد. يُستدعى عند إلغاء النموذج أو فشل الإدراج.
  void discard() {
    if (_kept) return;
    for (final u in _urls) {
      unawaited(SupabaseService.instance.deleteImage(u));
    }
    _urls.clear();
  }
}

/// اختيار صورة من المعرض: تعرض الصورة المختارة فوراً على الجهاز، ثم ترفعها
/// إلى سحابة التطبيق (Supabase Storage) وتمرّر رابطها العام عبر [onChanged]
/// عند اكتمال الرفع (أو null عند الفشل). لا تُحفظ أي صورة محلياً لاحقاً.
class AdminImageUploader extends StatefulWidget {
  const AdminImageUploader({
    super.key,
    required this.folder,
    required this.placeholder,
    required this.onChanged,
    this.onFailed,
    this.initialUrl,
    this.height = 130,
    this.icon = Icons.add_photo_alternate_rounded,
    this.uploads,
    this.handleRemovalExternally = false,
    this.onRemovedExisting,
    this.onBusyChanged,
    this.uploadedLabel = 'مرفوعة · ظاهرة للجميع',
  });

  /// مجلد الرفع في السلة (فمثلاً `products` أو `shops`).
  final String folder;

  /// نص يظهر قبل اختيار صورة.
  final String placeholder;

  /// يُستدعى بكل تغيير لرابط الصورة (null عند الحذف الصريح فقط).
  final ValueChanged<String?> onChanged;

  /// ★ يُستدعى عند فشل الرفع — **لا** عند الإلغاء.
  ///
  /// وُجد لسبب مهم: `onChanged(null)` كان يعني «فشل رفع» و«حذف» معاً،
  /// فكانت شاشة الصيدلية تمسح صورة عاملة لمجرّد تعثّر الشبكة. ثم إنّ
  /// فشل الرفع كان يُنشئ صيدليةاً بلا صورة بصمت. هذا يتيح للمنع الصريح.
  final ValueChanged<String>? onFailed;

  /// صورة موجودة مسبقاً تُعرض فوراً عند الفتح.
  ///
  /// بدونها كان الحقل يبدأ فارغاً دائماً، فلا يرى الأدمن الصورة الحالية
  /// وهو يغيّرها، فيظن أنها لم تُحفظ أصلاً.
  final String? initialUrl;

  final double height;
  final IconData icon;

  /// ★ حقيبة تتابع ما رُفع في هذا النموذج، فيمسحه الأهل عند الإلغاء.
  ///   تُمرَّر من شاشات «إضافة» (منتج/صيدلية/بانر/قسم) حيث الحفظ يحدث
  ///   بعد إغلاق النافذة — فبدونها يبقى ملف بلا صاحب في السحابة.
  final AdminUploads? uploads;

  /// ★ true إذا كان الأهل يحذف الصورة من القاعدة **فوراً** (شاشة شعار
  ///   الصيدلية مثلاً: كل تغيير يُكتب في الحين). عندها لا يعجل الرافع
  ///   بحذف ملف كان موجوداً قبل فتح النافذة، بل يُبلّغ الأهل بالـ URL
  ///   القديم عبر [onRemovedExisting] ليحذفه بعد نجاح كتابة القاعدة.
  final bool handleRemovalExternally;

  /// يُستدعى برابط الصورة **الموجودة أصلاً** عندما يمسحها الأدمن، وعلى
  /// الأهل حذفها من السحابة بعد أن تُصفَّر الأعمدة في القاعدة بنجاح.
  final ValueChanged<String>? onRemovedExisting;

  /// ★ يُبلَّغ بحالة الرفع — الشاشة الأهل تُعطّل زر «حفظ» ما دام الرفع
  ///   جارياً. بدونه: يُغلق النموذج أثناء الرفع فيُحفظ الصف بلا صورة
  ///   (وقع فعلاً: طبيب أضافه الأدمن بلا صورته).
  final ValueChanged<bool>? onBusyChanged;

  /// نص شارة «تم الرفع» أسفل الصورة. حقل الإثبات (هوية/شهادة) يمرّر
  /// «مرفوعة» وحدها بلا «ظاهرة للجميع».
  final String uploadedLabel;

  @override
  State<AdminImageUploader> createState() => _AdminImageUploaderState();
}

class _AdminImageUploaderState extends State<AdminImageUploader> {
  String? _path;
  late String? _url = _clean(widget.initialUrl);
  bool _uploading = false;

  /// ★ الصورة التي رفعت **هذه النافذة** نفسها (لا الصورة المعروضة أصلاً).
  ///   التفريق مهم: ما رفعناه الآن نحذفه من السحابة إذا مُسح أو أُلغي،
  ///   أما القديمة فلم تُرفع في هذا النموذج وقد تكون مرتبطة بصفوف أخرى.
  String? _uploadedHere;

  /// ★ حجم الصورة وأبعادها بعد الرفع — ليراها الأدمن (طلب 2026-10-10).
  int _bytes = 0;
  int _width = 0;
  int _height = 0;

  static String? _clean(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  @override
  void didUpdateWidget(covariant AdminImageUploader oldWidget) {
    super.didUpdateWidget(oldWidget);
    // بعد نجاح الحفظ نمرّر الرابط الجديد؛ نحدّث العرض بلا رفع جديد.
    final next = _clean(widget.initialUrl);
    if (next != _clean(oldWidget.initialUrl) && !_uploading && _path == null) {
      setState(() => _url = next);
    }
  }

  Future<void> _pick() async {
    final file = await LocalImageStore.instance.pickImage();
    if (file == null) {
      if (LocalImageStore.instance.lastPickerFailure.isNotEmpty && mounted) {
        _showError(LocalImageStore.instance.lastPickerFailure);
      }
      return;
    }
    await _upload(file);
  }

  Future<void> _shoot() async {
    final file = await LocalImageStore.instance.captureImage();
    if (file == null) {
      if (LocalImageStore.instance.lastPickerFailure.isNotEmpty && mounted) {
        _showError(LocalImageStore.instance.lastPickerFailure);
      }
      return;
    }
    await _upload(file);
  }

  /// ★ سطر الحجم تحت شارة «مرفوعة»: «الحجم 24.5 كيلوبايت · 700×525».
  ///   الأبعاد تُعرض إن عرفناها (تُقرأ من الصورة بعد الضغط)، وإلا
  ///   يُعرض الحجم وحده — لا نختلق رقمًا لا يعرفه النظام.
  String _sizeLine() {
    final size = LocalImageStore.formatBytes(_bytes);
    if (_width > 0 && _height > 0) return 'الحجم $size · $_width×$_height';
    return 'الحجم $size';
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textAlign: TextAlign.center),
        backgroundColor: AppColors.danger,
        duration: const Duration(seconds: 8),
      ),
    );
  }

  Future<void> _upload(XFile file) async {
    final replaced = _uploadedHere;
    setState(() {
      _path = file.path;
      _uploading = true;
      _url = null;
    });
    widget.onBusyChanged?.call(true);
    final url = await LocalImageStore.instance.uploadPicked(
      file,
      folder: widget.folder,
    );
    if (!mounted) return;
    widget.onBusyChanged?.call(false);
    if (url == null) {
      // ★★ فشل الرفع **ليس** «حذفاً للصورة». كان يُطلق `onChanged(null)`
      //   فلمّا افترق معنى `null` بين الفشل والإلغاء الصريح:
      //     · في تغيير صورة صيدلية: `updateShopImage(shopId, null)` كان
      //       يمسح الأعمدة الثلاثة ويطمس شعاراً يعمل.
      //     · في إضافة صيدلية: يُنشأ الصيدلية بلا صورة بينما الأدمن يرى
      //       المعاينة المحلية ⇒ «الصور ما تظهر للكل».
      //   الآن: نُعيد المعروض السابق، ولا نُطلق `onChanged` إطلاقاً،
      //   ونُبلغ الفشل عبر [onFailed] ليستطيع الأدمن منع الحفظ.
      setState(() {
        _uploading = false;
        _path = null;
        _url = _clean(widget.initialUrl);
      });
      final msg = LocalImageStore.instance.lastUploadFailure;
      _showError(msg);
      widget.onFailed?.call(msg);
      return;
    }
    setState(() {
      _url = url;
      _uploading = false;
      _path = null;
      // ★ ما رفعته هذه النافذة بيدها الآن — هو وحده القابل للحذف
      //   عند المسح أو الإلغاء.
      _uploadedHere = url;
      _bytes = LocalImageStore.instance.lastUploadBytes;
      _width = LocalImageStore.instance.lastUploadWidth;
      _height = LocalImageStore.instance.lastUploadHeight;
    });
    widget.uploads?.add(url);
    // ★ صورة سابقة رفعتها هذه النافذة واستُبدلت بأخرى صارت يتيمة.
    //   عند الأهل قرار الحذف إن كان يكتب القاعدة فوراً (شاشة الشعار)،
    //   وإلا نمسحها الآن بلا انتظار.
    if (replaced != null && replaced != url) {
      if (widget.handleRemovalExternally) {
        widget.onRemovedExisting?.call(replaced);
      } else {
        widget.uploads?.remove(replaced);
        unawaited(SupabaseService.instance.deleteImage(replaced));
      }
    }
    widget.onChanged(url);
  }

  void _clear() {
    final removed = _url;
    final mine = removed != null && removed == _uploadedHere;
    setState(() {
      _path = null;
      _url = null;
      _uploadedHere = null;
      _bytes = 0;
      _width = 0;
      _height = 0;
      _uploading = false;
    });
    // ★ المسح الصريح = إزالة من السحابة أيضاً، لا من الشاشة وحدها.
    //   أما الصورة المخزّنة في القاعدة أصلاً فيحذفها الأهل **بعد** أن
    //   تُصفَّر الأعمدة بنجاح — فحذفها قبلها يترك الصف يشير لملف فارق.
    if (removed != null) {
      if (mine && !widget.handleRemovalExternally) {
        widget.uploads?.remove(removed);
        unawaited(SupabaseService.instance.deleteImage(removed));
      } else {
        widget.onRemovedExisting?.call(removed);
      }
    }
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _path != null || _url != null;
    return GestureDetector(
      onTap: _uploading ? null : _pick,
      child: Container(
        height: widget.height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surfaceTint,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: !hasImage
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, color: AppColors.textHint, size: 34),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      widget.placeholder,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // بديل الكاميرا إن لم يفتح المعرض.
                  OutlinedButton.icon(
                    onPressed: _shoot,
                    icon: const Icon(Icons.photo_camera_rounded, size: 16),
                    label: const Text('أو التقط صورة بالكاميرا'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                  ),
                ],
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  // رابط محفوظ (سابق أو مرفوع حديثاً) له الأولوية؛
                  // الملف المحلي يُعرض فقط أثناء وجوده قبل اكتمال الرفع.
                  if (_url != null)
                    AppImage(
                      _url!,
                      fit: BoxFit.contain,
                      cacheWidth: 480,
                      cacheHeight: 480,
                    )
                  else if (_path != null)
                    Image.file(
                      File(_path!),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox(),
                    ),
                  if (_uploading)
                    Container(
                      color: Colors.black.withValues(alpha: 0.45),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'جاري رفع الصورة للسيرفر...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _url == null
                              ? Colors.red.withValues(alpha: 0.85)
                              : Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _url == null
                                  ? 'لم تُرفع للسيرفر'
                                  : widget.uploadedLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            // ★ الحجم والأبعاد بعد الضغط — يراهما الأدمن
                            //   فور رفع الصورة فيعرف ماذا نزل للسيرفر
                            //   دون أن يفتح ملفاً أو يحسب بنفسه.
                            if (_url != null && _bytes > 0)
                              Text(
                                _sizeLine(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: GestureDetector(
                      onTap: _clear,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
