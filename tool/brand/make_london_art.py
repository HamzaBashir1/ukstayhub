"""Generates the bundled London illustrations (hero, area cards, banners).

Original flat-style artwork – no third-party photos – so the app ships with
London imagery out of the box. Swap any file for a real photo with the same
name and size later if you like.

Run from the project root (needs Pillow):
    python3 tool/brand/make_london_art.py
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

SS = 2  # supersampling factor

# Palette
FOREST = (26, 58, 46)
NEAR = (38, 76, 64)
MID = (92, 139, 124)
FAR = (168, 196, 186)
FAINT = (205, 222, 214)
RIVER = (118, 172, 186)
RIVER_HI = (176, 214, 222)
RED = (200, 38, 44)
RED_D = (150, 24, 30)
CREAM = (255, 251, 240)
GOLD = (233, 182, 92)
WIN = (255, 226, 150)

SKIES = {
    "golden": [(246, 196, 140), (250, 222, 180), (253, 241, 218)],
    "day": [(140, 196, 232), (188, 224, 244), (232, 245, 250)],
    "dusk": [(122, 110, 170), (236, 150, 128), (250, 210, 170)],
    "soft": [(196, 222, 232), (226, 238, 240), (246, 248, 244)],
}


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w * SS, h * SS
        self.img = Image.new("RGB", (self.w, self.h))
        self.d = ImageDraw.Draw(self.img)

    # coordinates are given in output pixels; scaled here
    def s(self, v):
        return v * SS

    def poly(self, pts, fill):
        self.d.polygon([(x * SS, y * SS) for x, y in pts], fill=fill)

    def rect(self, x0, y0, x1, y1, fill, r=0):
        box = [min(x0, x1) * SS, min(y0, y1) * SS, max(x0, x1) * SS, max(y0, y1) * SS]
        if r:
            self.d.rounded_rectangle(box, radius=r * SS, fill=fill)
        else:
            self.d.rectangle(box, fill=fill)

    def ellipse(self, cx, cy, rx, ry, fill=None, outline=None, width=0):
        self.d.ellipse([(cx - rx) * SS, (cy - ry) * SS, (cx + rx) * SS, (cy + ry) * SS], fill=fill, outline=outline, width=int(width * SS))

    def line(self, pts, fill, width):
        self.d.line([(x * SS, y * SS) for x, y in pts], fill=fill, width=max(1, int(width * SS)), joint="curve")

    def save(self, path, quality=86):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        out = self.img.resize((self.w // SS, self.h // SS), Image.LANCZOS)
        out.save(path, "WEBP", quality=quality, method=6)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def sky(c, mood, horizon):
    stops = SKIES[mood]
    for y in range(c.h):
        t = min(1, y / (horizon * SS))
        col = lerp(stops[0], stops[1], t * 2) if t < 0.5 else lerp(stops[1], stops[2], (t - 0.5) * 2)
        c.d.line([(0, y), (c.w, y)], fill=col)


def sun(c, x, y, r, col=(255, 236, 196)):
    glow = Image.new("RGBA", c.img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i in range(6, 0, -1):
        rr = r * SS * (1 + i * 0.5)
        gd.ellipse([x * SS - rr, y * SS - rr, x * SS + rr, y * SS + rr], fill=col + (int(18 * (7 - i) / 6),))
    glow = glow.filter(ImageFilter.GaussianBlur(r * SS * 0.4))
    c.img.paste(glow, (0, 0), glow)
    c.ellipse(x, y, r, r, fill=col)


def clouds(c, rng, n, y0, y1, col=(255, 255, 255)):
    for _ in range(n):
        x = rng.uniform(0, c.w / SS)
        y = rng.uniform(y0, y1)
        w = rng.uniform(60, 160)
        for k in range(4):
            c.ellipse(x + (k - 1.5) * w * 0.28, y - (k % 2) * w * 0.08, w * 0.26, w * 0.13, fill=col)


def river(c, top, bottom, rng):
    c.rect(0, top, c.w / SS, bottom, RIVER)
    for _ in range(int((bottom - top) * c.w / SS / 900)):
        x = rng.uniform(0, c.w / SS)
        y = rng.uniform(top + 4, bottom - 2)
        L = rng.uniform(14, 60)
        c.rect(x, y, x + L, y + 1.6, RIVER_HI)


def city_band(c, rng, base, hmin, hmax, col, step=(18, 46), windows=False):
    x = -10
    W = c.w / SS
    while x < W + 10:
        w = rng.uniform(*step)
        h = rng.uniform(hmin, hmax)
        c.rect(x, base - h, x + w, base, col)
        if rng.random() < 0.25:
            c.poly([(x, base - h), (x + w / 2, base - h - w * 0.35), (x + w, base - h)], col)
        if windows:
            for yy in range(int(base - h + 6), int(base - 6), 9):
                for xx in range(int(x + 4), int(x + w - 4), 7):
                    if rng.random() < 0.35:
                        c.rect(xx, yy, xx + 3, yy + 4, WIN)
        x += w + rng.uniform(-2, 3)


def trees(c, rng, base, x0, x1, col, size=(14, 26)):
    x = x0
    while x < x1:
        r = rng.uniform(*size)
        c.ellipse(x, base - r * 0.8, r, r, fill=col)
        x += r * rng.uniform(0.9, 1.4)


# ───────────────────────── landmarks ─────────────────────────
def big_ben(c, x, base, h, col, face=CREAM):
    w = h * 0.13
    c.rect(x - w / 2, base - h * 0.78, x + w / 2, base, col)
    c.rect(x - w * 0.62, base - h * 0.8, x + w * 0.62, base - h * 0.62, col)
    c.ellipse(x, base - h * 0.71, w * 0.42, w * 0.42, fill=face)
    c.line([(x, base - h * 0.71), (x, base - h * 0.71 - w * 0.3)], col, max(1, w * 0.06))
    c.line([(x, base - h * 0.71), (x + w * 0.22, base - h * 0.71)], col, max(1, w * 0.06))
    c.rect(x - w * 0.5, base - h * 0.86, x + w * 0.5, base - h * 0.8, col)
    c.poly([(x - w * 0.55, base - h * 0.86), (x + w * 0.55, base - h * 0.86), (x, base - h)], col)
    for k in (-1, 1):
        c.poly([(x + k * w * 0.62, base - h * 0.8), (x + k * w * 0.48, base - h * 0.8), (x + k * w * 0.55, base - h * 0.88)], col)


def parliament(c, x0, x1, base, h, col):
    c.rect(x0, base - h, x1, base, col)
    n = int((x1 - x0) / (h * 0.45))
    for i in range(n + 1):
        xx = x0 + i * (x1 - x0) / max(1, n)
        c.poly([(xx - h * 0.06, base - h), (xx + h * 0.06, base - h), (xx, base - h * 1.35)], col)
    c.rect(x1 - h * 0.6, base - h * 2.1, x1 - h * 0.1, base, col)  # Victoria Tower
    for k in range(3):
        xx = x1 - h * 0.6 + k * h * 0.25
        c.poly([(xx - h * 0.04, base - h * 2.1), (xx + h * 0.04, base - h * 2.1), (xx, base - h * 2.3)], col)


def london_eye(c, cx, base, r, col, pod=None):
    cy = base - r * 1.12
    c.ellipse(cx, cy, r, r, outline=col, width=max(1.5, r * 0.035))
    c.ellipse(cx, cy, r * 0.94, r * 0.94, outline=col, width=max(1, r * 0.012))
    for i in range(16):
        a = i * math.pi / 8
        c.line([(cx, cy), (cx + r * math.cos(a), cy + r * math.sin(a))], col, max(0.8, r * 0.01))
        c.ellipse(cx + r * 1.03 * math.cos(a), cy + r * 1.03 * math.sin(a), r * 0.045, r * 0.035, fill=pod or col)
    c.ellipse(cx, cy, r * 0.07, r * 0.07, fill=col)
    c.line([(cx, cy), (cx - r * 0.45, base)], col, max(1.5, r * 0.04))
    c.line([(cx, cy), (cx - r * 0.2, base)], col, max(1.5, r * 0.04))


def shard(c, x, base, h, col, hi=None):
    w = h * 0.22
    c.poly([(x - w / 2, base), (x + w / 2, base), (x + w * 0.05, base - h), (x - w * 0.03, base - h * 0.97)], col)
    if hi:
        c.poly([(x, base), (x + w / 2, base), (x + w * 0.05, base - h)], hi)


def gherkin(c, x, base, h, col, stripe=None):
    w = h * 0.36
    pts = []
    for i in range(41):
        t = i / 40
        y = base - h * t
        half = w / 2 * math.sin(math.pi * (0.18 + 0.82 * t)) ** 0.8 * (1 - t * 0.15)
        pts.append((x + half, y))
    pts = pts + [(2 * x - px, py) for px, py in reversed(pts)]
    c.poly(pts, col)
    if stripe:
        for k in range(5):
            y0 = base - h * (0.1 + k * 0.18)
            c.line([(x - w * 0.42, y0), (x + w * 0.42, y0 - h * 0.12)], stripe, max(1, h * 0.012))


def st_pauls(c, x, base, h, col):
    w = h * 0.9
    c.rect(x - w / 2, base - h * 0.32, x + w / 2, base, col)
    c.poly([(x - w * 0.2, base - h * 0.32), (x + w * 0.2, base - h * 0.32), (x, base - h * 0.42)], col)
    c.rect(x - w * 0.17, base - h * 0.55, x + w * 0.17, base - h * 0.32, col)
    c.d.pieslice([(x - w * 0.19) * SS, (base - h * 0.78) * SS, (x + w * 0.19) * SS, (base - h * 0.32) * SS], 180, 360, fill=col)
    c.rect(x - w * 0.03, base - h * 0.88, x + w * 0.03, base - h * 0.7, col)
    c.poly([(x - w * 0.03, base - h * 0.88), (x + w * 0.03, base - h * 0.88), (x, base - h)], col)
    for k in (-1, 1):
        c.rect(x + k * w * 0.42 - w * 0.06, base - h * 0.55, x + k * w * 0.42 + w * 0.06, base - h * 0.3, col)
        c.poly([(x + k * w * 0.42 - w * 0.06, base - h * 0.55), (x + k * w * 0.42 + w * 0.06, base - h * 0.55), (x + k * w * 0.42, base - h * 0.64)], col)


def tower_bridge(c, x0, x1, base, h, col, deck=None, walk=None):
    tw = h * 0.2
    xs = [x0 + (x1 - x0) * 0.3, x0 + (x1 - x0) * 0.7]
    deck_y = base - h * 0.22
    c.rect(x0, deck_y, x1, deck_y + h * 0.05, deck or col)
    for tx in xs:
        c.rect(tx - tw / 2, base - h * 0.85, tx + tw / 2, base + h * 0.05, col)
        c.d.pieslice([(tx - tw * 0.32) * SS, (deck_y - tw * 0.6) * SS, (tx + tw * 0.32) * SS, (deck_y + tw * 0.2) * SS], 180, 360, fill=RIVER)
        c.poly([(tx - tw * 0.55, base - h * 0.85), (tx + tw * 0.55, base - h * 0.85), (tx, base - h)], col)
        for k in (-1, 1):
            c.poly([(tx + k * tw * 0.5 - tw * 0.1, base - h * 0.85), (tx + k * tw * 0.5 + tw * 0.1, base - h * 0.85), (tx + k * tw * 0.5, base - h * 0.97)], col)
        for wy in (0.7, 0.55, 0.4):
            c.rect(tx - tw * 0.12, base - h * wy, tx + tw * 0.12, base - h * wy + h * 0.06, WIN)
    for wy in (0.78, 0.71):
        c.rect(xs[0], base - h * wy, xs[1], base - h * wy + h * 0.035, walk or col)
    # suspension chains
    for a, b in ((x0, xs[0]), (xs[1], x1)):
        pts = []
        for i in range(21):
            t = i / 20
            xx = a + (b - a) * t
            sag = math.sin(math.pi * t) * h * 0.12
            y_a = deck_y if a == x0 else base - h * 0.62
            y_b = base - h * 0.62 if a == x0 else deck_y
            pts.append((xx, y_a + (y_b - y_a) * t + sag * 0.3))
        c.line(pts, walk or col, max(1.5, h * 0.025))


def terrace(c, rng, x0, x1, base, h, colours, roof=(70, 70, 82), door_cols=None, stucco=False):
    x = x0
    while x < x1:
        w = h * rng.uniform(0.55, 0.7)
        col = rng.choice(colours)
        c.rect(x, base - h, x + w, base, col)
        c.rect(x - 1, base - h - h * 0.05, x + w + 1, base - h, roof if not stucco else (236, 232, 224))
        if rng.random() < 0.5:
            c.rect(x + w * 0.7, base - h * 1.18, x + w * 0.85, base - h, (150, 90, 70))
        for row in range(3):
            yy = base - h * (0.88 - row * 0.27)
            for k in (0.18, 0.58):
                c.rect(x + w * k, yy, x + w * (k + 0.24), yy + h * 0.16, (245, 248, 250))
                c.rect(x + w * k + 1.5, yy + 1.5, x + w * (k + 0.24) - 1.5, yy + h * 0.16 - 1.5, (120, 160, 190))
        dc = rng.choice(door_cols or [FOREST, RED, (30, 60, 120), (20, 20, 24)])
        c.rect(x + w * 0.2, base - h * 0.27, x + w * 0.42, base, dc, r=2)
        c.rect(x, base - h * 0.03, x + w, base, (200, 196, 188))
        x += w


def bus(c, x, base, L, col=RED):
    h = L * 0.42
    c.rect(x, base - h, x + L, base - L * 0.05, col, r=L * 0.05)
    for row in (0.82, 0.42):
        c.rect(x + L * 0.05, base - h * row, x + L * 0.95, base - h * row + h * 0.22, (210, 230, 238), r=2)
        for k in range(1, 6):
            xx = x + L * 0.05 + k * L * 0.15
            c.rect(xx, base - h * row, xx + L * 0.012, base - h * row + h * 0.22, col)
    c.rect(x, base - h * 0.55, x + L, base - h * 0.5, CREAM)
    for wx in (0.18, 0.8):
        c.ellipse(x + L * wx, base - L * 0.05, L * 0.07, L * 0.07, fill=(30, 30, 34))
        c.ellipse(x + L * wx, base - L * 0.05, L * 0.03, L * 0.03, fill=(150, 150, 150))


def phone_box(c, x, base, h):
    w = h * 0.38
    c.rect(x, base - h, x + w, base, RED, r=w * 0.08)
    c.d.pieslice([x * SS, (base - h - w * 0.25) * SS, (x + w) * SS, (base - h + w * 0.25) * SS], 180, 360, fill=RED)
    c.rect(x + w * 0.12, base - h * 0.92, x + w * 0.88, base - h * 0.84, (30, 30, 34))
    for r in range(4):
        for k in range(3):
            xx = x + w * (0.16 + k * 0.24)
            yy = base - h * (0.76 - r * 0.14)
            c.rect(xx, yy, xx + w * 0.18, yy + h * 0.11, (230, 240, 244))
    c.rect(x - w * 0.04, base - h * 0.04, x + w * 1.04, base, RED_D)


def narrowboat(c, x, base, L, hull=(30, 70, 60), cabin=(196, 50, 60)):
    c.poly([(x, base - L * 0.06), (x + L, base - L * 0.06), (x + L * 0.96, base), (x + L * 0.04, base)], hull)
    c.rect(x + L * 0.12, base - L * 0.14, x + L * 0.88, base - L * 0.06, cabin)
    for k in range(6):
        xx = x + L * (0.17 + k * 0.12)
        c.rect(xx, base - L * 0.125, xx + L * 0.05, base - L * 0.085, WIN)
    c.rect(x + L * 0.12, base - L * 0.155, x + L * 0.88, base - L * 0.14, (40, 40, 40))


def observatory(c, x, base, h, col, dome=(120, 120, 128)):
    w = h * 1.4
    c.rect(x - w / 2, base - h * 0.55, x + w / 2, base, col)
    for k in range(5):
        xx = x - w / 2 + w * (0.1 + k * 0.2)
        c.rect(xx - w * 0.03, base - h * 0.45, xx + w * 0.03, base - h * 0.2, WIN)
    c.rect(x - w * 0.18, base - h * 0.75, x + w * 0.18, base - h * 0.55, col)
    c.d.pieslice([(x - w * 0.2) * SS, (base - h * 1.05) * SS, (x + w * 0.2) * SS, (base - h * 0.45) * SS], 180, 360, fill=dome)
    c.rect(x - 1, base - h * 1.15, x + 1, base - h * 0.75, dome)
    c.ellipse(x, base - h * 1.15, h * 0.04, h * 0.04, fill=RED)


def hills(c, base, amp, col, rng, phase=0.0):
    W = c.w / SS
    pts = [(0, c.h / SS)]
    for i in range(61):
        x = W * i / 60
        y = base - amp * (0.5 + 0.5 * math.sin(i / 7 + phase)) - amp * 0.3 * math.sin(i / 3.1 + phase * 2)
        pts.append((x, y))
    pts.append((W, c.h / SS))
    c.poly(pts, col)


# ───────────────────────── scenes ─────────────────────────
def skyline_scene(w, h, mood="golden", seed=1, focus=0.5):
    rng = random.Random(seed)
    c = Canvas(w, h)
    horizon = h * 0.7
    sky(c, mood, horizon)
    sun(c, w * 0.78, h * 0.25, min(w, h) * 0.06)
    clouds(c, rng, 6, h * 0.08, h * 0.35)
    base = h * 0.72
    city_band(c, rng, base, h * 0.05, h * 0.16, FAINT)
    city_band(c, rng, base, h * 0.03, h * 0.1, FAR, windows=False)
    u = min(w * 0.7, h * 1.2)
    st_pauls(c, w * 0.36 * focus * 2, base, u * 0.3, MID)
    gherkin(c, w * 0.47, base, u * 0.32, MID, stripe=FAR)
    shard(c, w * 0.63, base, u * 0.62, NEAR, hi=MID)
    london_eye(c, w * 0.235, base, u * 0.19, NEAR, pod=CREAM)
    parliament(c, w * 0.01, w * 0.1, base, u * 0.07, NEAR)
    big_ben(c, w * 0.085, base, u * 0.45, FOREST)
    river(c, base, h, rng)
    tower_bridge(c, w * 0.62, w * 1.02, base + h * 0.02, u * 0.36, FOREST, deck=NEAR, walk=(64, 120, 150))
    c.rect(0, base, w * 0.6, base + h * 0.012, NEAR)
    return c


def area_scene(kind, w=1200, h=800, seed=7):
    rng = random.Random(seed)
    c = Canvas(w, h)
    if kind == "westminster":
        sky(c, "golden", h * 0.7)
        sun(c, w * 0.75, h * 0.3, 60)
        clouds(c, rng, 5, h * 0.06, h * 0.3)
        base = h * 0.7
        city_band(c, rng, base, 30, 90, FAINT)
        london_eye(c, w * 0.78, base, h * 0.25, MID, pod=CREAM)
        parliament(c, w * 0.08, w * 0.55, base, h * 0.12, NEAR)
        big_ben(c, w * 0.6, base, h * 0.62, FOREST)
        river(c, base, h, rng)
        c.rect(0, base, w, base + 10, FOREST)
        bus(c, w * 0.04, base, w * 0.17)
    elif kind == "kensington":
        sky(c, "day", h * 0.6)
        clouds(c, rng, 6, h * 0.05, h * 0.3)
        base = h * 0.92
        trees(c, rng, h * 0.5, -20, w + 20, MID, (40, 70))
        terrace(c, rng, -20, w + 40, base, h * 0.55, [(244, 240, 232), (250, 222, 222), (222, 236, 246), (232, 244, 226), (252, 238, 210)], stucco=True)
        c.rect(0, base, w, h, (180, 176, 170))
        c.rect(0, base + 12, w, base + 16, (240, 240, 240))
    elif kind == "camden":
        sky(c, "soft", h * 0.6)
        clouds(c, rng, 4, h * 0.05, h * 0.25)
        base = h * 0.62
        terrace(c, rng, -20, w + 40, base, h * 0.36, [(220, 64, 70), (70, 130, 190), (250, 200, 70), (60, 160, 120), (150, 80, 160), (240, 130, 60)], roof=(40, 40, 50), door_cols=[(30, 30, 30), CREAM])
        c.rect(0, base, w, base + 18, (120, 110, 100))
        # canal
        c.rect(0, base + 18, w, h, (88, 128, 118))
        for _ in range(60):
            x = rng.uniform(0, w); y = rng.uniform(base + 30, h)
            c.rect(x, y, x + rng.uniform(15, 50), y + 2, (128, 168, 156))
        narrowboat(c, w * 0.12, h * 0.86, w * 0.5)
        narrowboat(c, w * 0.58, h * 0.95, w * 0.42, hull=(20, 40, 90), cabin=(60, 150, 90))
        # lock gates
        for gx in (w * 0.05, w * 0.95):
            c.rect(gx - 6, base + 10, gx + 6, h, (60, 50, 40))
    elif kind == "city":
        sky(c, "dusk", h * 0.7)
        sun(c, w * 0.2, h * 0.5, 50, col=(255, 214, 170))
        base = h * 0.78
        city_band(c, rng, base, 60, 160, FAR, windows=True)
        gherkin(c, w * 0.32, base, h * 0.5, NEAR, stripe=MID)
        c.poly([(w * 0.5, base), (w * 0.62, base), (w * 0.62, base - h * 0.58), (w * 0.5, base - h * 0.4)], FOREST)  # cheesegrater
        c.poly([(w * 0.68, base), (w * 0.8, base), (w * 0.83, base - h * 0.45), (w * 0.66, base - h * 0.42)], NEAR)  # walkie-talkie
        st_pauls(c, w * 0.12, base, h * 0.36, MID)
        city_band(c, rng, base, 30, 80, FOREST, step=(30, 60), windows=True)
        c.rect(0, base, w, h, (40, 44, 52))
        for k in range(12):
            c.rect(k * w / 11, h * 0.9, k * w / 11 + 40, h * 0.9 + 6, (220, 220, 200))
        bus(c, w * 0.55, h * 0.97, w * 0.24)
    elif kind == "southbank":
        sky(c, "golden", h * 0.6)
        sun(c, w * 0.5, h * 0.36, 70)
        clouds(c, rng, 4, h * 0.05, h * 0.25)
        base = h * 0.62
        city_band(c, rng, base, 30, 100, FAINT)
        shard(c, w * 0.84, base, h * 0.6, MID, hi=FAR)
        river(c, base, h, rng)
        tower_bridge(c, -w * 0.02, w * 1.02, base + h * 0.06, h * 0.52, FOREST, deck=NEAR, walk=(64, 120, 150))
    elif kind == "greenwich":
        sky(c, "day", h * 0.6)
        clouds(c, rng, 5, h * 0.05, h * 0.25)
        hills(c, h * 0.62, 70, (122, 176, 110), rng)
        c.ellipse(w * 0.5, h * 0.66, w * 0.34, h * 0.11, fill=(122, 176, 110))
        observatory(c, w * 0.5, h * 0.565, h * 0.16, (176, 96, 80))
        hills(c, h * 0.8, 40, (96, 156, 92), rng, phase=2)
        trees(c, rng, h * 0.78, -20, w * 0.3, (60, 120, 70), (25, 45))
        trees(c, rng, h * 0.8, w * 0.7, w + 20, (60, 120, 70), (25, 45))
        city_band(c, rng, h * 0.95, 40, 140, FAR, step=(30, 60))
        c.rect(0, h * 0.95, w, h, (96, 156, 92))
    elif kind == "richmond":
        sky(c, "soft", h * 0.55)
        clouds(c, rng, 5, h * 0.05, h * 0.25)
        hills(c, h * 0.55, 60, (140, 182, 130), rng)
        trees(c, rng, h * 0.56, -20, w + 20, (90, 140, 90), (35, 60))
        river(c, h * 0.6, h, rng)
        trees(c, rng, h * 0.62, -20, w * 0.25, (50, 100, 60), (40, 70))
        # rowing boat
        c.poly([(w * 0.45, h * 0.8), (w * 0.65, h * 0.8), (w * 0.62, h * 0.83), (w * 0.48, h * 0.83)], (150, 80, 50))
        c.line([(w * 0.5, h * 0.79), (w * 0.44, h * 0.86)], (90, 60, 40), 4)
        c.line([(w * 0.6, h * 0.79), (w * 0.66, h * 0.86)], (90, 60, 40), 4)
    return c


def postcard(w=800, h=800, seed=3):
    """Square card: Big Ben, a phone box and a red bus – the 'London' snapshot."""
    rng = random.Random(seed)
    c = Canvas(w, h)
    sky(c, "day", h * 0.7)
    clouds(c, rng, 4, h * 0.05, h * 0.3)
    base = h * 0.78
    city_band(c, rng, base, 40, 140, FAINT, step=(30, 60))
    parliament(c, w * 0.05, w * 0.5, base, h * 0.1, MID)
    big_ben(c, w * 0.56, base, h * 0.68, NEAR)
    trees(c, rng, base, w * 0.7, w + 20, MID, (30, 50))
    c.rect(0, base, w, h, (190, 186, 178))
    c.rect(0, base + 6, w, base + 10, (230, 230, 226))
    phone_box(c, w * 0.08, h * 0.97, h * 0.42)
    bus(c, w * 0.36, h * 0.98, w * 0.58)
    return c


def main():
    out = os.path.join(os.getcwd(), "assets", "images")
    skyline_scene(1584, 672, seed=11).save(os.path.join(out, "london-hero-wide.webp"))
    skyline_scene(600, 894, seed=12, focus=0.4).save(os.path.join(out, "london-hero-portrait.webp"))
    postcard().save(os.path.join(out, "london-postcard.webp"))
    area_scene("kensington", 1280, 960, seed=21).save(os.path.join(out, "about-hero.webp"))
    for kind in ("westminster", "kensington", "camden", "city", "southbank", "greenwich", "richmond"):
        area_scene(kind).save(os.path.join(out, "destinations", f"{kind}.webp"))
    print("london art written")


if __name__ == "__main__":
    main()
