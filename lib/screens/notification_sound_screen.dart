import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/theme/app_colors.dart';
import '../services/device_sound.dart';
import '../services/notification_sound.dart';
import '../services/push_service.dart';

/// «أصوات الإشعارات» — المستخدم يختار نغمة إشعارات التطبيق من
/// أصوات هاتفه نفسها.
///
/// ★ الحفظ على هذا الهاتف وحده: يُنشأ على الجهاز قناة إشعار جديدة
///   بصوت الاختيار وتُحذف قناة الاختيار السابق ⇒ لا يرنّ القديم مع
///   الجديد. الصوت نفسه لا يغادر الهاتف؛ يُبلَّغ السيرفر بمعرّف القناة
///   وحده (مرة عند التغيير) كي يرنّ إشعار التطبيق المغلق بالصوت نفسه.
class NotificationSoundScreen extends StatefulWidget {
  const NotificationSoundScreen({super.key});

  @override
  State<NotificationSoundScreen> createState() =>
      _NotificationSoundScreenState();
}

class _NotificationSoundScreenState extends State<NotificationSoundScreen> {
  List<Map<String, String>> _sounds = const [];
  bool _loading = true;
  bool _android = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    DeviceSound.stopPreview();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final android =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    await DeviceSound.load();
    final list =
        android ? await DeviceSound.list() : const <Map<String, String>>[];
    if (!mounted) return;
    setState(() {
      _android = android;
      _sounds = list;
      _loading = false;
    });
  }

  Future<void> _useAppSound() async {
    await DeviceSound.reset();
    // السيرفر يعرف الآن أن الجهاز عاد لنغمة التطبيق — كي يرنّ الإشعار
    // بنغمة صيدليتي والتطبيق مغلق (رسالة واحدة فقط).
    unawaited(PushService.instance.syncSoundChannel(DeviceSound.channelId));
    if (!mounted) return;
    setState(() {});
    await NotificationSound.instance.preview(NotifySound.alert);
  }

  Future<void> _use(String uri, String title) async {
    final ok = await DeviceSound.apply(uri, title);
    if (!mounted) return;
    setState(() {});
    if (!ok) {
      _toast('تعذّر حفظ النغمة على هذا الهاتف');
      return;
    }
    // ★ يُبلَّغ السيرفر بقناة النغمة الجديدة مرة واحدة، فيوجّه الإشعارات
    //   القادمة إلى قناة صوتها حتى والتطبيق مغلق.
    unawaited(PushService.instance.syncSoundChannel(DeviceSound.channelId));
    await DeviceSound.preview(uri);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: GoogleFonts.cairo()),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('أصوات الإشعارات'),
        centerTitle: true,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
              children: [
                _intro(),
                const SizedBox(height: 12),
                _tile(
                  title: 'نغمة التطبيق (الافتراضية)',
                  subtitle: 'جرس صيدليتي — يُستخدم عندما لا تختار نغمة.',
                  selected: !DeviceSound.hasCustom,
                  onTap: _useAppSound,
                  onPreview: () =>
                      NotificationSound.instance.preview(NotifySound.alert),
                  icon: Icons.verified_rounded,
                ),
                if (!_android)
                  _unsupportedCard()
                else ...[
                  for (final s in _sounds)
                    _tile(
                      title: s['title'] ?? 'نغمة',
                      subtitle: (s['uri'] == DeviceSound.silentUri)
                          ? 'بلا صوت — يبقى الإشعار ظاهراً بلا رنين.'
                          : 'من أصوات هاتفك',
                      selected: DeviceSound.hasCustom &&
                          DeviceSound.selectedUri == s['uri'],
                      onTap: () => _use(s['uri']!, s['title'] ?? 'نغمة'),
                      onPreview: (s['uri'] == DeviceSound.silentUri)
                          ? null
                          : () => DeviceSound.preview(s['uri']!),
                      icon: (s['uri'] == DeviceSound.silentUri)
                          ? Icons.volume_off_rounded
                          : Icons.music_note_rounded,
                    ),
                ],
              ],
            ),
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.notifications_active_rounded,
              color: AppColors.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'اختر نغمة الإشعارات من أصوات هذا الهاتف. الاختيار يُحفظ '
              'على هذا الجهاز فقط، ويُكتم صوت النغمة السابقة فوراً.',
              style: GoogleFonts.cairo(
                fontSize: 12,
                height: 1.7,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unsupportedCard() {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Text(
        'تغيير نغمة إشعارات التطبيق متاح على هواتف أندرويد. على الآيفون '
        'يُضبط الصوت من إعدادات الهاتف > الإشعارات > صيدليتي.',
        style: GoogleFonts.cairo(
          fontSize: 12,
          height: 1.7,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _tile({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onPreview,
    required IconData icon,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected ? AppColors.mintPill : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.divider,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? AppColors.primary : AppColors.textHint,
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.cairo(
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (onPreview != null)
                IconButton(
                  onPressed: onPreview,
                  tooltip: 'معاينة',
                  icon: const Icon(Icons.play_circle_outline_rounded),
                  color: AppColors.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
