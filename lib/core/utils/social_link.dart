import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// المنصات المدعومة لزر الرابط في بروفايل الطبيب — الأيقونة واللون
/// يُختاران من نص الرابط نفسه فلا يظهر فيسبوك لرابط Google Play مثلاً.
enum SocialPlatform {
  facebook,
  instagram,
  tiktok,
  youtube,
  telegram,
  viber,
  whatsapp,
  googlePlay,
  link,
}

class SocialLink {
  SocialLink._();

  static SocialPlatform detect(String raw) {
    var u = raw.trim().toLowerCase();
    if (u.isEmpty) return SocialPlatform.link;
    if (u.startsWith('viber://')) return SocialPlatform.viber;
    if (u.startsWith('tg://')) return SocialPlatform.telegram;
    if (u.startsWith('whatsapp://')) return SocialPlatform.whatsapp;
    if (u.startsWith('market://')) return SocialPlatform.googlePlay;
    if (!u.contains('://')) u = 'https://$u';
    String host;
    try {
      host = Uri.parse(u).host;
    } catch (_) {
      return SocialPlatform.link;
    }
    if (host.isEmpty) return SocialPlatform.link;
    bool has(List<String> domains) =>
        domains.any((d) => host == d || host.endsWith('.$d'));
    if (has(['facebook.com', 'fb.com', 'fb.me', 'fb.watch'])) {
      return SocialPlatform.facebook;
    }
    if (has(['instagram.com', 'instagr.am', 'ig.me'])) {
      return SocialPlatform.instagram;
    }
    if (has(['tiktok.com'])) return SocialPlatform.tiktok;
    if (has(['youtube.com', 'youtu.be'])) return SocialPlatform.youtube;
    if (has(['t.me', 'telegram.me', 'telegram.dog'])) {
      return SocialPlatform.telegram;
    }
    if (has(['viber.me', 'viber.com'])) return SocialPlatform.viber;
    if (has(['wa.me', 'whatsapp.com'])) return SocialPlatform.whatsapp;
    if (has(['play.google.com'])) return SocialPlatform.googlePlay;
    return SocialPlatform.link;
  }

  /// أيقونة المنصة جاهزة للعرض — أيقونة رابط عامة لما لا يُعرف.
  static Widget buildIcon(
    SocialPlatform platform, {
    required double size,
    required Color color,
  }) {
    final fa = _faOf(platform);
    if (fa == null) return Icon(Icons.link_rounded, size: size, color: color);
    return FaIcon(fa, size: size, color: color);
  }

  static FaIconData? _faOf(SocialPlatform platform) {
    switch (platform) {
      case SocialPlatform.facebook:
        return FontAwesomeIcons.facebookF;
      case SocialPlatform.instagram:
        return FontAwesomeIcons.instagram;
      case SocialPlatform.tiktok:
        return FontAwesomeIcons.tiktok;
      case SocialPlatform.youtube:
        return FontAwesomeIcons.youtube;
      case SocialPlatform.telegram:
        return FontAwesomeIcons.telegram;
      case SocialPlatform.viber:
        return FontAwesomeIcons.viber;
      case SocialPlatform.whatsapp:
        return FontAwesomeIcons.whatsapp;
      case SocialPlatform.googlePlay:
        return FontAwesomeIcons.googlePlay;
      case SocialPlatform.link:
        return null;
    }
  }

  static Color colorOf(SocialPlatform platform) {
    switch (platform) {
      case SocialPlatform.facebook:
        return const Color(0xFF1877F2);
      case SocialPlatform.instagram:
        return const Color(0xFFE1306C);
      case SocialPlatform.tiktok:
        return const Color(0xFF010101);
      case SocialPlatform.youtube:
        return const Color(0xFFFF0000);
      case SocialPlatform.telegram:
        return const Color(0xFF229ED9);
      case SocialPlatform.viber:
        return const Color(0xFF665CAC);
      case SocialPlatform.whatsapp:
        return const Color(0xFF25D366);
      case SocialPlatform.googlePlay:
        return const Color(0xFF01875F);
      case SocialPlatform.link:
        return const Color(0xFF008000);
    }
  }
}
