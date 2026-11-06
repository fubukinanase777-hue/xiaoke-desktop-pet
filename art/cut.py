"""Cut the two 4x2 sprite sheets into transparent, bottom-aligned frames.
python -X utf8 cut.py   (run from this folder)  -> frames/*.png + frames/contact.png
"""
import numpy as np
from PIL import Image, ImageFilter
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "frames")
os.makedirs(OUT, exist_ok=True)
NAMES = {
    "sheet-work.png": ["work1", "work2", "work3", "work4", "idle1", "idle2", "idle3", "idle4"],
    "sheet-done.png": ["cheer1", "cheer2", "cheer3", "cheer4", "need1", "need2", "wait1", "wait2"],
    # 2026-11-05: poke reactions (row 1 at the desk, row 2 standing) and dozing / woken up (sitting by the books)
    "sheet-poke.png": ["poke1", "poke2", "poke3", "poke4", "poke5", "poke6", "poke7", "poke8"],
    "sheet-doze.png": ["doze1", "doze2", "doze3", "doze4", "wake1", "wake2", "wake3", "wake4"],
    # 2026-11-06: idle variants, in-between frames: turning a page (idle5-8), a cup of tea (idle9-12)
    "sheet-work2.png": ["work5", "work6", "work7", "work8", "work9", "work10", "work11", "work12"],
    "sheet-cheer2.png": ["cheer5", "cheer6", "cheer7", "cheer8", "cheer9", "cheer10", "cheer11", "cheer12"],
    "sheet-poke2.png": ["poke9", "poke10", "poke11", "poke12", "poke13", "poke14", "poke15", "poke16"],
    "sheet-doze2.png": ["doze5", "doze6", "doze7", "doze8", "wake5", "wake6", "wake7", "wake8"],
    "sheet-wait2.png": ["wait3", "wait4", "wait5", "wait6", None, None, None, None],
    "sheet-bell2.png": ["need3", "need4", "need5", "need6", "need7", "need8", "need9", "need10"],
    "sheet-spoke1.png": ["poke17", "poke18", "poke19", "poke20", "poke21", "poke22", "poke23", "poke24"],
    "sheet-spoke2.png": ["poke25", "poke26", "poke27", "poke28", "poke29", "poke30", "poke31", "poke32"],
    "sheet-idle3.png": [None, "idle14", "idle15", "idle16", "idle17", "idle18", "idle19", "idle20"],
    "sheet-doze3.png": ["doze9", "doze10", "doze11", "doze12", "doze13", "doze14", "doze15", "doze16"],
    "sheet-idle2.png": ["idle5", "idle6", "idle7", "idle8", "idle9", "idle10", "idle11", "idle12"],
}
NAMES = {k: v for k, v in NAMES.items() if os.path.exists(os.path.join(HERE, k))}
# per-row size correction so a later sheet matches the first two (measured against work / wait / idle)
ROWSCALE = {"sheet-poke.png": (1.0, 0.975), "sheet-doze.png": (0.967, 0.967), "sheet-idle2.png": (0.95, 0.95), "sheet-work2.png": (0.97, 0.97), "sheet-doze2.png": (0.975, 0.975), "sheet-spoke1.png": (0.95, 0.95), "sheet-spoke2.png": (0.95, 0.95), "sheet-idle3.png": (0.95, 0.95), "sheet-doze3.png": (0.975, 0.975)}
TARGET_H = 420
PINK_STEAM = {"idle9"}
FLOOR_ROWS = [("sheet-cheer2.png", 0)]
LIFT = {"cheer3": 85}  # source px; the jump frame keeps its height above the floor  # stored height (display is ~150-200 px, 2x for HiDPI)


def key(rgb):
    r, g, b = [rgb[..., i].astype(np.float32) for i in range(3)]
    # magenta: r and b high, g low. "m" = how much the pixel is magenta-ish
    mn = np.minimum(r, b)
    m = (mn - g) / np.maximum(mn, 1)
    bg = (m > 0.45) & (mn > 110)
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    a = Image.fromarray(alpha)
    # drop isolated specks, then soften the edge by one pixel
    a = a.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
    edge = np.array(a.filter(ImageFilter.MaxFilter(5))) > np.array(a.filter(ImageFilter.MinFilter(5)))
    out = rgb.copy().astype(np.float32)
    # despill on the edge ring: pull magenta tint out (blue/red down towards green)
    sp = edge & (m > 0.12)
    for c in (0, 2):
        ch = out[..., c]
        ch[sp] = np.minimum(ch[sp], g[sp] + (ch[sp] - g[sp]) * 0.35 + 25)
    return out.clip(0, 255).astype(np.uint8), np.array(a)



def drop_specks(img):
    """tiny scraps from the neighbouring cell that float away from her (2026-11-06: dots above work9/11/12).
    Small symbols (z, hearts, sparks) are bigger than this and stay."""
    from scipy import ndimage
    arr = np.array(img); a = arr[..., 3] > 20
    lab, n = ndimage.label(a)
    if n < 2: return img
    sz = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
    main = lab == (int(np.argmax(sz)) + 1)
    far = ndimage.distance_transform_edt(~main)
    for i, s_ in enumerate(sz, 1):
        if s_ < 40 and far[lab == i].min() > 12:
            arr[lab == i, 3] = 0
    return Image.fromarray(arr, "RGBA")

cells = {}
row_of = {}
for sheet, names in NAMES.items():
    im = np.array(Image.open(os.path.join(HERE, sheet)).convert("RGB"))
    H, W = im.shape[:2]
    cw, ch = W // 4, H // 2
    for idx, name in enumerate(names):
        if name is None: continue  # cell not used (redrawn on another sheet)
        r, c = divmod(idx, 4)
        cell = im[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw]
        k = ROWSCALE.get(sheet, (1.0, 1.0))[r]
        if k != 1.0:  # shrink/grow around the bottom centre, pad with magenta
            src = Image.fromarray(cell).resize((round(cw * k), round(ch * k)), Image.NEAREST)
            pad = Image.new("RGB", (cw, ch), (255, 0, 255))
            pad.paste(src, ((cw - src.width) // 2, ch - src.height))
            cell = np.array(pad)
        rgb, a = key(cell)
        if name in PINK_STEAM:  # light steam drawn close to the magenta key comes out pink: make it white
            f = rgb.astype(np.float32); r_, g_, b_ = f[..., 0], f[..., 1], f[..., 2]
            pink = (a > 0) & (r_ > g_ + 25) & (b_ > g_ + 25) & (np.minimum(r_, b_) > 150)
            rgb[pink] = (236, 236, 242)
        # remove blobs that touch the cell border (bits of the neighbouring cell)
        from scipy import ndimage
        lab, n = ndimage.label(a > 0)
        border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
        sizes = ndimage.sum(np.ones_like(lab), lab, index=list(border)) if border else []
        for k, sz in zip(border, sizes):
            if sz < 0.01 * a.size:  # only small scraps; never the character itself
                a[lab == k] = 0
        ys, xs = np.nonzero(a)
        bottom = ys.max()
        top = ys.min()
        low = a[bottom - (bottom - top) // 4: bottom + 1]
        lx = np.nonzero(low)[1].mean()  # x anchor = centre of the lowest quarter (feet / desk)
        bottom += LIFT.get(name, 0)  # frames that should float above the floor (jump)
        cells[name] = (rgb, a, lx, bottom, xs.min(), xs.max(), top)
        row_of[name] = (sheet, r)

# rows drawn on one shared (invisible) floor, e.g. a jump: anchor every cell of the row on the row's lowest
# point instead of its own feet, so the airborne frames keep their height
for (sh, rr) in FLOOR_ROWS:
    ns = [n for n, v in row_of.items() if v == (sh, rr)]
    if not ns: continue
    floor = max(cells[n][3] for n in ns)
    for n in ns:
        v = list(cells[n]); v[3] = floor; cells[n] = tuple(v)

# common canvas so every frame shares the same anchor
left = max(v[2] - v[4] for v in cells.values()) + 20
right = max(v[5] - v[2] for v in cells.values()) + 20
up = max(v[3] - v[6] for v in cells.values()) + 20
CW, CH = int(left + right), int(up + 12)
scale = TARGET_H / CH
print("canvas", CW, CH, "scale", round(scale, 3))
thumbs = []
for name, (rgb, a, lx, bottom, *_ ) in cells.items():
    rgba = np.dstack([rgb, a])
    canvas = np.zeros((CH, CW, 4), np.uint8)
    ox, oy = int(round(left - lx)), int(up - bottom)
    h, w = rgba.shape[:2]
    x0, y0 = max(0, ox), max(0, oy)
    x1, y1 = min(CW, ox + w), min(CH, oy + h)
    canvas[y0:y1, x0:x1] = rgba[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
    img = Image.fromarray(canvas, "RGBA").resize((round(CW * scale), TARGET_H), Image.LANCZOS)
    img = drop_specks(img)
    img.save(os.path.join(OUT, name + ".png"))
    thumbs.append((name, img))

# contact sheet on a light and a dark strip to check edges
tw, th = thumbs[0][1].size
rows = (len(thumbs) + 7) // 8
sheet = Image.new("RGBA", (tw * 8, th * 2 * rows), (0, 0, 0, 255))
for i, (n, t) in enumerate(thumbs):
    r, c = divmod(i, 8)
    for band, colr in ((0, (245, 240, 232, 255)), (rows, (30, 30, 34, 255))):
        bgc = Image.new("RGBA", (tw, th), colr)
        bgc.alpha_composite(t)
        sheet.paste(bgc, (c * tw, (r + band) * th))
sheet.save(os.path.join(OUT, "contact.png"))
print("frames:", len(thumbs), "size", tw, th)
