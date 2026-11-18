# LiriWriter 圖示:跟 LiriChat 同一家族(同款五瓣花＋白色主體),換成暖色漸層＋打開的書
import math, sys, os
from PIL import Image, ImageDraw, ImageChops
OUT = sys.argv[1]
S = 4                      # 超取樣
N = 1024 * S

def grad(top, bot, size=N):
    g = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(g)
    for y in range(size):
        t = y / (size - 1)
        # 跟 Chat 一樣稍微斜一點:右上偏 top 色
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=c)
    return g.rotate(-12, resample=Image.BICUBIC, expand=False, fillcolor=bot) if False else g

def P(v): return int(v * S)

def glyph(page, accent, ink):
    """打開的書:兩頁的上下緣往書脊彎,外角圓角;左頁幾行字,右頁 LiriChat 的五瓣花。"""
    im = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    cx, top, bot, half, sag, gap = 512, 296, 712, 318, 44, 10
    for side in (-1, 1):
        layer = Image.new("L", (N, N), 0)
        pts = []
        for i in range(61):                       # 上緣:外側高,往書脊彎下去
            t = i / 60                            # 0 = 書脊, 1 = 外緣
            pts.append((cx + side * (gap + (half - gap) * t), top + sag * (1 - t) ** 2))
        for i in range(60, -1, -1):               # 下緣:往書脊彎下去
            t = i / 60
            pts.append((cx + side * (gap + (half - gap) * t), bot + sag * (1 - t) ** 2))
        ImageDraw.Draw(layer).polygon([(P(x), P(y)) for x, y in pts], fill=255)
        # 外側兩個角圓角:跟一個只在外側圓角的矩形取交集
        rm = Image.new("L", (N, N), 0)
        x0, x1 = (cx - half, cx + 60) if side < 0 else (cx - 60, cx + half)
        ImageDraw.Draw(rm).rounded_rectangle([P(x0), P(top - 10), P(x1), P(bot + sag + 10)], radius=P(40), fill=255)
        ImageDraw.Draw(rm).rectangle([P(cx - 30), P(top - 10), P(cx + 30), P(bot + sag + 10)], fill=255)
        layer = ImageChops.multiply(layer, rm)
        fill = Image.new("RGBA", (N, N), page)
        im.paste(fill, (0, 0), layer)
    d = ImageDraw.Draw(im)
    # 左頁:靠左對齊的字行,跟著頁面的彎度稍微往下
    xl = cx - half + 58
    for i, w in enumerate([196, 222, 168, 214, 132]):
        y = top + 92 + i * 60
        d.rounded_rectangle([P(xl), P(y), P(xl + w), P(y + 24)], radius=P(12), fill=ink)
    # 右頁:五瓣花
    fx, fy, pr, dist = cx + 164, 516, 56, 66
    for k in range(5):
        ang = -math.pi / 2 + k * 2 * math.pi / 5
        x, y = fx + dist * math.cos(ang), fy + dist * math.sin(ang)
        d.ellipse([P(x - pr), P(y - pr), P(x + pr), P(y + pr)], fill=accent)
    d.ellipse([P(fx - 32), P(fy - 32), P(fx + 32), P(fy + 32)], fill=page)
    return im

def compose(bg_top, bg_bot, page, accent, ink, mac=False):
    bg = grad(bg_top, bg_bot).convert("RGBA")
    g = glyph(page, accent, ink)
    if mac:
        # macOS:跟 Chat 一樣,824 的圓角方塊置中,glyph 縮到 0.82
        canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        box = 824 * S; off = (N - box) // 2
        mask = Image.new("L", (N, N), 0)
        ImageDraw.Draw(mask).rounded_rectangle([off, off, off + box, off + box], radius=P(185), fill=255)
        canvas.paste(bg, (0, 0), mask)
        gs = g.resize((int(N * 0.82), int(N * 0.82)), Image.LANCZOS)
        o = (N - gs.width) // 2
        canvas.alpha_composite(gs, (o, o))
        return canvas.resize((1024, 1024), Image.LANCZOS)
    bg.alpha_composite(g)
    return bg.convert("RGB").resize((1024, 1024), Image.LANCZOS)

warm_top, warm_bot = (255, 170, 92), (243, 92, 120)      # 琥珀 → 珊瑚
accent = (240, 104, 112, 255)
ink = (250, 196, 170, 255)
white = (255, 255, 255, 255)

os.makedirs(OUT, exist_ok=True)
compose(warm_top, warm_bot, white, accent, ink).save(f"{OUT}/icon-1024.png")
# 深色:黑底,書用暖色
dark = compose((28, 24, 30), (14, 12, 16), (255, 168, 120, 255), (255, 240, 235, 255), (150, 80, 70, 255))
dark.save(f"{OUT}/icon-1024-dark.png")
# 染色:灰階 glyph 在黑底
tint = compose((0, 0, 0), (0, 0, 0), (235, 235, 235, 255), (120, 120, 120, 255), (150, 150, 150, 255))
tint.convert("L").convert("RGB").save(f"{OUT}/icon-1024-tinted.png")
mac = compose(warm_top, warm_bot, white, accent, ink, mac=True)
for s in (16, 32, 64, 128, 256, 512, 1024):
    mac.resize((s, s), Image.LANCZOS).save(f"{OUT}/icon-mac-{s}.png")
print("ok")
