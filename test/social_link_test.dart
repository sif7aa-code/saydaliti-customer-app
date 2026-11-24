import 'package:flutter_test/flutter_test.dart';
import 'package:saydaliti/core/utils/social_link.dart';

void main() {
  test('يكتشف منصة الرابط', () {
    const cases = {
      'https://www.facebook.com/x': SocialPlatform.facebook,
      'fb.com/x': SocialPlatform.facebook,
      'https://instagram.com/x': SocialPlatform.instagram,
      'https://www.tiktok.com/@x': SocialPlatform.tiktok,
      'https://youtu.be/abc': SocialPlatform.youtube,
      'https://youtube.com/watch?v=1': SocialPlatform.youtube,
      'https://t.me/x': SocialPlatform.telegram,
      'tg://resolve?domain=x': SocialPlatform.telegram,
      'viber://chat?number=123': SocialPlatform.viber,
      'viber.me/x': SocialPlatform.viber,
      'https://wa.me/9647812345678': SocialPlatform.whatsapp,
      'https://chat.whatsapp.com/xyz': SocialPlatform.whatsapp,
      'https://play.google.com/store/apps/details?id=x':
          SocialPlatform.googlePlay,
      'https://example.com/page': SocialPlatform.link,
    };
    cases.forEach((url, expected) {
      expect(SocialLink.detect(url), expected, reason: url);
    });
  });
}
