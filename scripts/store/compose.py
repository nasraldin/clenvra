"""Lays out store screenshots: a caption over each app screenshot, 2880x1800 (the Mac App Store and web size).

Usage: python3 -I scripts/store/compose.py <folder of raw captures> <output folder>
Raw captures are named store-NN-<page>-<en|ar>.png (from StoreScreenshotUITests).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

WIDTH, HEIGHT = 2880, 1800
TOP, BOTTOM = (14, 22, 38), (22, 52, 70)
ACCENT = (94, 212, 196)

CAPTIONS = {
    "overview": (
        ("Your Mac at a glance", "Scan everything in one click. Nothing is removed until you review it."),
        ("جهازك في لمحة", "افحص كل شيء بنقرة واحدة، ولن يُحذف شيء قبل أن تراجعه."),
    ),
    "cleanup": (
        ("Clean junk safely", "Caches, logs and leftovers go to the Trash first, so you can put them back."),
        ("تخلّص من الملفات غير الضرورية بأمان", "تنتقل ذاكرة التخزين المؤقت والسجلات والبقايا إلى سلة المهملات أولًا، لتستعيدها متى شئت."),
    ),
    "storage": (
        ("See what fills your disk", "Explore every folder with honest sizes that count clones and hard links once."),
        ("اعرف ما يشغل مساحة قرصك", "تصفّح كل مجلد بحجمه الحقيقي، فلا تُحتسب النسخ المتكررة إلا مرة واحدة."),
    ),
    "applications": (
        ("Uninstall apps completely", "Remove an app with all its files, or back it up first and restore it later."),
        ("أزل التطبيقات إزالة كاملة", "احذف التطبيق مع جميع ملفاته، أو احتفظ بنسخة احتياطية منه لاستعادته لاحقًا."),
    ),
    "startup": (
        ("Take control of startup", "Disable, enable or remove what starts with your Mac, and see who signed it."),
        ("تحكّم فيما يعمل عند بدء التشغيل", "عطّل العناصر أو فعّلها أو أزلها، واعرف الجهة التي وقّعت كلًّا منها."),
    ),
    "recentItems": (
        ("Clear your recent history", "Recent apps, documents, servers and folders, and each app’s Open Recent list."),
        ("امسح سجل العناصر الأخيرة", "التطبيقات والمستندات والخوادم والمجلدات الأخيرة، وقائمة «فتح الأخير» في كل تطبيق."),
    ),
    "developer": (
        ("Built for developers", "Xcode data, simulators, package caches and build folders, each tool cleaned its way."),
        ("مصمَّم للمطوّرين", "بيانات Xcode والمحاكيات وذاكرة الحزم ومجلدات البناء، وتُنظَّف كل أداة بطريقتها."),
    ),
    "largeFiles": (
        ("Find large and old files", "Grouped by kind, so you decide what to keep."),
        ("اعثر على الملفات الكبيرة والقديمة", "مصنّفة حسب النوع، لتقرر بنفسك ما تحتفظ به."),
    ),
}


def font(language, size, bold):
    path = "/System/Library/Fonts/SFArabic.ttf" if language == "ar" else "/System/Library/Fonts/SFNS.ttf"
    face = ImageFont.truetype(path, size, layout_engine=ImageFont.Layout.RAQM)
    try:
        face.set_variation_by_name("Bold" if bold else "Regular")
    except (OSError, ValueError):
        pass
    return face


def background():
    image = Image.new("RGB", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    for y in range(HEIGHT):
        t = y / HEIGHT
        draw.line([(0, y), (WIDTH, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return image


def text(draw, language, y, string, size, bold, fill):
    face = font(language, size, bold)
    direction = "rtl" if language == "ar" else "ltr"
    width = draw.textlength(string, font=face, direction=direction)
    draw.text(((WIDTH - width) / 2, y), string, font=face, fill=fill, direction=direction)


def compose(raw_path, page, language, out_path):
    canvas = background()
    draw = ImageDraw.Draw(canvas)
    title, subtitle = CAPTIONS[page][1 if language == "ar" else 0]
    text(draw, language, 120, title, 124, True, (255, 255, 255))
    text(draw, language, 300, subtitle, 54, False, ACCENT)

    shot = Image.open(raw_path).convert("RGBA")
    area_w, area_h = WIDTH - 360, HEIGHT - 520
    scale = min(area_w / shot.width, area_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width, shot.height], radius=36, fill=255)
    x, y = (WIDTH - shot.width) // 2, 460
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 30, x + shot.width, y + shot.height + 30], 36, fill=(0, 0, 0, 150))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(40)))
    canvas.paste(shot, (x, y), mask)
    canvas.convert("RGB").save(out_path, optimize=True)


def main(raw_folder, out_folder):
    for name in sorted(os.listdir(raw_folder)):
        if not (name.startswith("store-") and name.endswith(".png")):
            continue
        _, number, page, language = name[:-4].split("-")
        folder = os.path.join(out_folder, language)
        os.makedirs(folder, exist_ok=True)
        compose(os.path.join(raw_folder, name), page, language, os.path.join(folder, f"{number}-{page}.png"))
        print("✔", language, number, page)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
