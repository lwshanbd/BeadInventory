"""开屏指导截图用的原创立体图纸「立体小屋」。8 个零件 + 顶部色号表 + 底部成品示意。

用法：python3 tools/draw_onboarding_pattern.py BeadInventory/allcolors.json out.png
格子颜色取自 allcolors.json 的 MARD 色值，识别和多零件判色才对得上。
需要先装 Pillow（pip install pillow）。字体写死了 macOS 系统字体路径，只能在 Mac 上跑。
"""
import json, sys
from collections import Counter
from PIL import Image, ImageDraw, ImageFont

COLORS_JSON, OUT = sys.argv[1], sys.argv[2]
hexmap = {x['mardCode']: x['colorHex'] for x in json.load(open(COLORS_JSON)) if x.get('mardCode')}
def rgb(code):
    h = hexmap[code]; return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

WALL, TRIM, DOOR, GLASS = 'A11', 'G13', 'G8', 'C3'
ROOF, ROOF2, CHIM, CHIM2 = 'F2', 'F6', 'H4', 'H5'
GRASS, PATH, FLOWER, LEAF = 'B3', 'G4', 'E4', 'B8'

def gable(win_door):
    w, h = 12, 13
    g = [[None]*w for _ in range(h)]
    for r in range(h):
        if r < 6:
            lo, hi = 5 - r, 6 + r
        else:
            lo, hi = 0, 11
        for c in range(lo, hi+1):
            edge = (c == lo or c == hi or r == h-1)
            g[r][c] = TRIM if edge else WALL
    for c in (5, 6): g[3][c] = GLASS
    if win_door:
        for r in range(9, 12):
            for c in (5, 6): g[r][c] = DOOR
        g[10][6] = 'A5'  # 门把手
        for (r0, c0) in ((7, 2), (7, 8)):
            for r in (r0, r0+1):
                for c in (c0, c0+1): g[r][c] = GLASS
    else:
        for r in (8, 9):
            for c in range(4, 8): g[r][c] = GLASS
    return g

def side():
    w, h = 10, 7
    g = [[WALL]*w for _ in range(h)]
    for c in range(w): g[h-1][c] = TRIM
    for r in range(h): g[r][0] = g[r][w-1] = TRIM
    for r in (2, 3):
        for c in range(3, 7): g[r][c] = GLASS
    return g

def roof():
    w, h = 12, 9
    return [[ROOF2 if r % 3 == 2 else ROOF for c in range(w)] for r in range(h)]

def chimney():
    g = [[CHIM]*3 for _ in range(5)]
    g[0] = [CHIM2]*3
    return g

def base():
    w, h = 16, 14
    g = [[GRASS]*w for _ in range(h)]
    for r in range(10, h):
        for c in (7, 8): g[r][c] = PATH
    for (r, c) in ((11, 2), (12, 4), (10, 13), (12, 12), (2, 1), (1, 14)):
        g[r][c] = FLOWER
        if r + 1 < h: g[r+1][c] = LEAF
    return g

# 拼图阅读顺序：第一行 正面/背面/烟囱，第二行 侧墙×2 + 底板，第三行 屋顶×2
rows = [[gable(True), gable(False), chimney()],
        [side(), side(), base()],
        [roof(), roof()]]

W, H = 1400, 2300
CELL = 26
img = Image.new('RGB', (W, H), (255, 255, 255))
d = ImageDraw.Draw(img)
font_cn = lambda s: ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', s)
font_en = lambda s: ImageFont.truetype('/System/Library/Fonts/HelveticaNeue.ttc', s)

counts = Counter()
for row in rows:
    for g in row:
        for line in g:
            for v in line:
                if v: counts[v] += 1

# 顶部：标题 + 色号表（第一行色号、第二行数量）
d.text((60, 40), '立体小屋', font=font_cn(56), fill=(60, 50, 45))
d.text((60, 112), '8 片零件 · 拼好后按示意图组装', font=font_cn(26), fill=(120, 110, 105))
codes = sorted(counts, key=lambda k: (k[0], int(k[1:])))
colw = (W - 120 - 110) / len(codes)
tx, ty, rh = 60, 190, 70
d.rectangle([tx, ty, W-60, ty+2*rh], outline=(90, 90, 90), width=2)
d.line([tx, ty+rh, W-60, ty+rh], fill=(90, 90, 90), width=2)
d.text((tx+18, ty+20), '色号', font=font_cn(28), fill=(40, 40, 40))
d.text((tx+18, ty+rh+20), '数量', font=font_cn(28), fill=(40, 40, 40))
for i, k in enumerate(codes):
    x0 = tx + 110 + i*colw
    d.line([x0, ty, x0, ty+2*rh], fill=(90, 90, 90), width=2)
    d.rectangle([x0+2, ty+2, x0+colw-1, ty+rh-1], fill=rgb(k))
    lum = sum(rgb(k)) / 3
    f = font_en(28)
    tw = d.textlength(k, font=f)
    d.text((x0+(colw-tw)/2, ty+20), k, font=f, fill=(255, 255, 255) if lum < 120 else (30, 30, 30))
    s = str(counts[k]); tw = d.textlength(s, font=f)
    d.text((x0+(colw-tw)/2, ty+rh+20), s, font=f, fill=(30, 30, 30))

def draw_grid(g, ox, oy):
    f = font_en(10)
    for r, line in enumerate(g):
        for c, v in enumerate(line):
            if not v: continue
            x, y = ox + c*CELL, oy + r*CELL
            d.rectangle([x, y, x+CELL, y+CELL], fill=rgb(v), outline=(85, 85, 85), width=1)
            lum = sum(rgb(v)) / 3
            tw = d.textlength(v, font=f)
            d.text((x+(CELL-tw)/2, y+8), v, font=f, fill=(255, 255, 255) if lum < 120 else (70, 70, 70))

# 中部：零件
y = 470
for row in rows:
    widths = [len(g[0])*CELL for g in row]
    gap = (W - 120 - sum(widths)) / (len(row) + 1)
    x = 60 + gap
    hmax = max(len(g)*CELL for g in row)
    for g in row:
        draw_grid(g, int(x), int(y + (hmax - len(g)*CELL)/2))
        x += len(g[0])*CELL + gap
    y += hmax + 70
print('parts bottom', y)

# 底部：成品示意（等轴小屋）
top = 1660
d.line([60, top-30, W-60, top-30], fill=(220, 220, 220), width=2)
d.text((60, top), '成品示意', font=font_cn(30), fill=(120, 110, 105))
cx, cy, s = W//2, top + 380, 22
def iso(x, y, z):  # x 向右下, y 向左下, z 向上
    return (cx + (x - y)*s*0.87, cy + (x + y)*s*0.5 - z*s)
def poly(pts, code, outline=(80, 70, 65)):
    d.polygon([iso(*p) for p in pts], fill=rgb(code), outline=outline)
poly([(-8, -7, 0), (8, -7, 0), (8, 7, 0), (-8, 7, 0)], GRASS)
L, D_, Hh = 6, 5, 7
poly([(-L, D_, 0), (L, D_, 0), (L, D_, Hh), (-L, D_, Hh)], WALL)       # 正面
poly([(L, -D_, 0), (L, D_, 0), (L, D_, Hh), (L, -D_, Hh)], 'A21')       # 侧面（稍浅示意）
poly([(-L, D_, Hh), (L, D_, Hh), (L, 0, Hh+5), (-L, 0, Hh+5)], ROOF)   # 前坡
poly([(L, -D_, Hh), (L, D_, Hh), (L, 0, Hh+5)], WALL)                  # 山墙
poly([(-1, D_, 0), (1, D_, 0), (1, D_, 3.5), (-1, D_, 3.5)], DOOR)
poly([(-4.5, D_, 3.5), (-2.5, D_, 3.5), (-2.5, D_, 5.5), (-4.5, D_, 5.5)], GLASS)
poly([(2.5, D_, 3.5), (4.5, D_, 3.5), (4.5, D_, 5.5), (2.5, D_, 5.5)], GLASS)
poly([(L, -2, 2.5), (L, 2, 2.5), (L, 2, 4.5), (L, -2, 4.5)], GLASS)
poly([(-3, 1.5, Hh+4), (-1.5, 1.5, Hh+4), (-1.5, 1.5, Hh+8), (-3, 1.5, Hh+8)], CHIM)
poly([(-1.5, 1.5, Hh+4.2), (-1.5, 0, Hh+4.9), (-1.5, 0, Hh+8), (-1.5, 1.5, Hh+8)], CHIM2)

img.save(OUT)
print(dict(counts))
