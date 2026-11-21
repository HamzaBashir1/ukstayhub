"""Generates the UK Stay Hub logo mark and every platform icon.

The mark: a map pin with a house cut out of it and a door, two-tone teal.
Geometry lives in a 500x500 design box and matches lib/widgets/brand_logo_mark.dart.

Run from the project root (needs Pillow):
    python3 tool/brand/make_icons.py
"""
import json
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFont

TEAL = (1, 164, 143)
DEEP = (7, 123, 104)
FOREST = (17, 42, 34)
BG_TOP = (16, 150, 124)
BG_BOTTOM = (6, 94, 79)
WHITE = (255, 255, 255)
MINT = (214, 242, 233)

# Design-box geometry (keep in sync with brand_logo_mark.dart).
CX, CY, R = 250, 190, 175
TIP = (250, 485)
_d = TIP[1] - CY
_th = math.acos(R / _d)
TAN_L = (CX - R * math.sin(_th), CY + R * math.cos(_th))
TAN_R = (CX + R * math.sin(_th), CY + R * math.cos(_th))
ROOF = [(250, 92), (362, 196), (138, 196)]
BODY = (168, 196, 332, 290)
DOOR = (228, 232, 272, 290)


def _mask(size, draw_fn):
    m = Image.new("L", (size, size), 0)
    draw_fn(ImageDraw.Draw(m), size / 500)
    return m


def mark_masks(size):
    """(full, dark) alpha masks of the mark at `size` px, antialiased via 4x supersampling."""
    big = size * 4

    def pin(d, s):
        d.ellipse([(CX - R) * s, (CY - R) * s, (CX + R) * s, (CY + R) * s], fill=255)
        d.polygon([(TAN_L[0] * s, TAN_L[1] * s), (TAN_R[0] * s, TAN_R[1] * s), (TIP[0] * s, TIP[1] * s)], fill=255)

    def house(d, s):
        d.polygon([(x * s, y * s) for x, y in ROOF], fill=255)
        d.rectangle([v * s for v in BODY], fill=255)

    def door(d, s):
        d.rectangle([v * s for v in DOOR], fill=255)

    def left(d, s):
        d.rectangle([0, 0, 250 * s, 500 * s], fill=255)

    full = ImageChops.subtract(_mask(big, pin), _mask(big, house))
    full = ImageChops.lighter(full, _mask(big, door))
    dark = ImageChops.multiply(full, _mask(big, left))
    return full.resize((size, size), Image.LANCZOS), dark.resize((size, size), Image.LANCZOS)


def mark_image(size, light=TEAL, dark=DEEP):
    full, darkm = mark_masks(size)
    img = Image.new("RGBA", (size, size), light + (0,))
    img.putalpha(full)
    shade = Image.new("RGBA", (size, size), dark + (255,))
    img.paste(shade, (0, 0), darkm)
    return img


def gradient(size):
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = min(1, max(0, (x * 0.35 + y) / (size * 1.35)))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
    return g


def app_icon(size, inset=0.17, rounded=False):
    """Full-bleed app icon: white/mint mark on a green gradient."""
    icon = gradient(size).convert("RGBA")
    m = round(size * (1 - 2 * inset))
    mk = mark_image(m, light=WHITE, dark=MINT)
    icon.alpha_composite(mk, ((size - m) // 2, (size - m) // 2 + round(size * 0.01)))
    if rounded:
        r = Image.new("L", (size * 4, size * 4), 0)
        ImageDraw.Draw(r).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=size * 4 * 0.2237, fill=255)
        icon.putalpha(r.resize((size, size), Image.LANCZOS))
    return icon


def save(img, path, rgb=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    (img.convert("RGB") if rgb else img).save(path)


def wordmark(height, colour_uk=DEEP, colour_rest=TEAL, text_colour=None):
    """Mark + 'UK Stay Hub' logotype, transparent background."""
    font_path = "/System/Library/Fonts/Avenir Next.ttc"
    scale = 4
    h = height * scale
    mark = mark_image(h)
    f_bold = ImageFont.truetype(font_path, round(h * 0.62), index=8)  # Avenir Next Heavy/Bold face
    parts = [("UK ", text_colour or colour_uk), ("Stay Hub", text_colour or colour_rest)]
    widths = [ImageDraw.Draw(Image.new("L", (1, 1))).textlength(t, font=f_bold) for t, _ in parts]
    gap = round(h * 0.16)
    w = h + gap + round(sum(widths)) + round(h * 0.05)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    img.alpha_composite(mark, (0, 0))
    d = ImageDraw.Draw(img)
    x = h + gap
    for (t, c), tw in zip(parts, widths):
        d.text((x, h * 0.47), t, font=f_bold, fill=c + (255,), anchor="lm")
        x += tw
    return img.resize((w // scale, height), Image.LANCZOS)


def main():
    root = os.getcwd()
    a = lambda *p: os.path.join(root, *p)

    # In-app images
    save(mark_image(500), a("assets/images/brand-mark.png"))
    save(app_icon(1024, rounded=True), a("assets/images/logo.png"))
    save(wordmark(160), a("assets/images/brand-wordmark.png"))
    save(wordmark(160, text_colour=WHITE), a("assets/images/brand-wordmark-white.png"))

    # Android: legacy + adaptive foreground
    for dpi, s in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save(app_icon(s, rounded=True), a(f"android/app/src/main/res/mipmap-{dpi}/ic_launcher.png"))
        fg = round(s * 108 / 48)
        canvas = Image.new("RGBA", (fg, fg), (0, 0, 0, 0))
        m = round(fg * 0.50)
        canvas.alpha_composite(mark_image(m, light=WHITE, dark=MINT), ((fg - m) // 2, (fg - m) // 2))
        save(canvas, a(f"android/app/src/main/res/mipmap-{dpi}/ic_launcher_foreground.png"))

    # iOS (opaque, square; iOS applies the mask)
    ios = a("ios/Runner/Assets.xcassets/AppIcon.appiconset")
    for img in json.load(open(os.path.join(ios, "Contents.json")))["images"]:
        if "filename" not in img:
            continue
        pt = float(img["size"].split("x")[0])
        px = round(pt * int(img["scale"][0]))
        save(app_icon(px), os.path.join(ios, img["filename"]), rgb=True)

    # macOS (rounded, transparent corners)
    mac = a("macos/Runner/Assets.xcassets/AppIcon.appiconset")
    for s in (16, 32, 64, 128, 256, 512, 1024):
        icon = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        inner = round(s * 0.805)
        icon.alpha_composite(app_icon(inner, rounded=True), ((s - inner) // 2, (s - inner) // 2))
        save(icon, os.path.join(mac, f"app_icon_{s}.png"))

    # Web
    save(app_icon(64, rounded=True), a("web/favicon.png"))
    for s in (192, 512):
        save(app_icon(s, rounded=True), a(f"web/icons/Icon-{s}.png"))
        save(app_icon(s, inset=0.27), a(f"web/icons/Icon-maskable-{s}.png"), rgb=True)
    print("icons written")


if __name__ == "__main__":
    main()
