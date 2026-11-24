"""
تقليم خطوط Cairo إلى المحارف المستعملة فعلاً (عربي + لاتيني).

يعمل على نسخ Lines الأصلية:減 lines 538KB ← ~200KB داخل كل APK.

الاستعمال:
    python tools/subset_fonts.py
"""

import os
import sys

try:
    from fontTools import subset
    from fontTools.ttLib import TTFont
except ImportError:
    print("fonttools not installed:  pip install fonttools brotli")
    sys.exit(1)

FONT_DIR = "assets/google_fonts"

# نُبقي المحارف التالية فقط: العربية، اللاتينية الأساسية، الأرقام،
# وعلامات الترقيم. (الأيقونات/الإيموجي يرسمها خط النظام تلقائياً،
#  فلا نحتاج تضمينها هنا.)
UNICODES = [
    # العربية
    (0x0600, 0x06FF),   # Arabic
    (0x0750, 0x077F),   # Arabic Supplement
    (0x200C, 0x200F),   # ZWNJ/ZWJ + LRM/RLM
    (0x2066, 0x2069),   # LRI/RLI/PDI
    (0x061C, 0x061C),
    # اللاتينية والأرقام وعلامات الترقيم
    (0x0020, 0x007E),
    (0x00A0, 0x00FF),
    (0x00D7, 0x00D7),   # ×
    (0x2010, 0x2027),   # علامات ترقيم
    (0x2030, 0x205E),
]


def expand(ranges):
    """نطاقات (بداية, نهاية) ⇒ قائمة محارف مفردة.

    fontTools يقبل محارف مفردة فقط، وتمرير النطاقاتPlanning herni
    يُفشل Subsetter (خطأ في تنسيق رسالة الخطأ عند 4.63).
    """
    out = set()
    for item in ranges:
        if isinstance(item, tuple):
            out.update(range(item[0], item[1] + 1))
        else:
            out.add(item)
    return sorted(out)


def main():
    if not os.path.isdir(FONT_DIR):
        print("not found:", FONT_DIR)
        return 1

    unicodes = expand(UNICODES)
    print(f"keeping {len(unicodes)} code points\n")

    total_before = 0
    total_after = 0
    for name in sorted(os.listdir(FONT_DIR)):
        if not name.lower().endswith(".ttf"):
            continue
        path = os.path.join(FONT_DIR, name)
        before = os.path.getsize(path)
        total_before += before

        font = TTFont(path)
        options = subset.Options()
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.notdef_outline = True
        options.recalc_bounds = True
        options.drop_tables += ["DSIG"]
        # بعض المحارف غير موجودة في الخط ⇒ نتخطاها بصمت.
        options.ignore_missing_unicodes = True
        options.ignore_missing_glyphs = True
        options.name_legacy = True

        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=unicodes)
        subsetter.subset(font)
        font.save(path)
        font.close()

        after = os.path.getsize(path)
        total_after += after
        saved = before - after
        print(
            f"  {name:<28} {before/1024:7.1f} KB -> {after/1024:6.1f} KB "
            f"(save {saved/1024:6.1f} KB)"
        )

    print(
        f"\nTotal: {total_before/1024:.1f} KB -> {total_after/1024:.1f} KB "
        f"(save {(total_before-total_after)/1024:.1f} KB)"
    )
    print("Rebuild the APK to apply:  .\\tools\\build_apk.ps1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
