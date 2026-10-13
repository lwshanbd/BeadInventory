"""开屏指导里「两种识别方式」那页的两张示例：
表格（每列一种颜色，几行品牌色号 + 一行数量）、色号统计（一块块色卡写「色号 (数量)」）。

用法：python3 tools/draw_recognition_examples.py BeadInventory/allcolors.json table.png stats.png
颜色和数量取自「立体小屋」图纸（见 draw_onboarding_pattern.py）里用量最多的 6 种，
放在手机上字才看得清。需要 Pillow，字体写死了 macOS 系统字体路径，只能在 Mac 上跑。
"""
import json, sys
from PIL import Image, ImageDraw, ImageFont

COLORS_JSON, OUT_TABLE, OUT_STATS = sys.argv[1:4]
rows = {x['mardCode']: x for x in json.load(open(COLORS_JSON)) if x.get('mardCode')}
USAGE = [('A11', 234), ('B3', 204), ('F2', 144), ('G13', 116), ('F6', 72), ('C3', 36)]

def rgb(code):
    h = rows[code]['colorHex']; return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
def lum(c): return 0.299*c[0] + 0.587*c[1] + 0.114*c[2]
cn = lambda s: ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', s)
en = lambda s: ImageFont.truetype('/System/Library/Fonts/HelveticaNeue.ttc', s)
LINE, TEXT = (120, 120, 120), (35, 35, 35)

def centered(d, box, text, font, fill):
    x0, y0, x1, y1 = box
    w = d.textlength(text, font=font)
    asc, desc = font.getmetrics()
    d.text(((x0 + x1 - w) / 2, (y0 + y1 - asc - desc) / 2 + 2), text, font=font, fill=fill)

# ---------- 表格：每列一种颜色，多行品牌色号，最后一行数量 ----------
brand_rows = [('MARD', 'mardCode'), ('漫漫', 'manmanCode'), ('卡卡', 'kakaCode')]
label_w, col_w, row_h, pad, fs = 130, 124, 72, 24, 32
W = pad*2 + label_w + col_w*len(USAGE)
H = pad*2 + row_h*(len(brand_rows) + 2)
img = Image.new('RGB', (W, H), 'white'); d = ImageDraw.Draw(img)
x0, y0 = pad, pad
# 表头：色块行
d.rectangle([x0, y0, x0+label_w, y0+row_h], outline=LINE, width=2)
centered(d, (x0, y0, x0+label_w, y0+row_h), '颜色', cn(fs), TEXT)
for i, (code, _) in enumerate(USAGE):
    cx = x0 + label_w + i*col_w
    d.rectangle([cx, y0, cx+col_w, y0+row_h], fill=rgb(code), outline=LINE, width=2)
for r, (name, key) in enumerate(brand_rows + [('数量', None)]):
    ry = y0 + row_h*(r+1)
    is_qty = key is None
    d.rectangle([x0, ry, x0+label_w, ry+row_h], fill=(255, 241, 214) if is_qty else 'white', outline=LINE, width=2)
    centered(d, (x0, ry, x0+label_w, ry+row_h), name, cn(fs) if not name.isascii() else en(fs), (190, 60, 40) if is_qty else TEXT)
    for i, (code, qty) in enumerate(USAGE):
        cx = x0 + label_w + i*col_w
        d.rectangle([cx, ry, cx+col_w, ry+row_h], fill=(255, 241, 214) if is_qty else 'white', outline=LINE, width=2)
        text = str(qty) if is_qty else (rows[code].get(key) or '—')
        centered(d, (cx, ry, cx+col_w, ry+row_h), text, en(fs), TEXT)
img.save(OUT_TABLE)

# ---------- 色号统计：一块块色卡，写「色号 (数量)」 ----------
cols, chip_w, chip_h, gap = 3, 282, 76, 16
nrows = -(-len(USAGE) // cols)
W = pad*2 + cols*chip_w + (cols-1)*gap
H = pad*2 + nrows*chip_h + (nrows-1)*gap
img = Image.new('RGB', (W, H), 'white'); d = ImageDraw.Draw(img)
for i, (code, qty) in enumerate(USAGE):
    r, c = divmod(i, cols)
    x = pad + c*(chip_w+gap); y = pad + r*(chip_h+gap)
    col = rgb(code)
    d.rounded_rectangle([x, y, x+chip_w, y+chip_h], radius=8, fill=col)
    fg = (255, 255, 255) if lum(col) < 140 else (30, 30, 30)
    f = en(fs)
    asc, desc = f.getmetrics()
    d.text((x+18, y + (chip_h-asc-desc)/2 + 2), f'{code}  ({qty})', font=f, fill=fg)
img.save(OUT_STATS)

