"""Render frames recorded by scripts/demo/record.lua into a GIF (or PNG snapshots).

    python render.py frames.jsonl out.gif [--speed 1.0] [--png-every N]

Needs Pillow. Fonts: DEMO_FONT (regular, ideally a Nerd Font for statusline icons),
DEMO_FONT_BOLD, DEMO_FONT_FALLBACK (a monospace font with box drawing), DEMO_FONT_SIZE.
Box-drawing and powerline glyphs are drawn as vectors so lines connect across cells.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SIZE = int(os.environ.get("DEMO_FONT_SIZE", "15"))
WIN_FONTS = os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\Windows\Fonts")
REG = os.environ.get("DEMO_FONT", os.path.join(WIN_FONTS, "AdwaitaMonoNerdFont-Regular.ttf"))
BOLD = os.environ.get("DEMO_FONT_BOLD", os.path.join(WIN_FONTS, "AdwaitaMonoNerdFontMono-Bold.ttf"))
FALLBACK = os.environ.get("DEMO_FONT_FALLBACK", r"C:\Windows\Fonts\CascadiaMono.ttf")


def load(path, size=SIZE):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.truetype(FALLBACK, size)


font, bold, fb = load(REG), load(BOLD), ImageFont.truetype(FALLBACK, SIZE)
asc, desc = font.getmetrics()
CW = round(font.getlength("M"))
CH = asc + desc + 3
UI = ImageFont.truetype(FALLBACK, 17)
UI_SMALL = ImageFont.truetype(FALLBACK, 15)


def rgb(n):
    return ((n >> 16) & 255, (n >> 8) & 255, n & 255)


def has_glyph(f, ch):
    try:
        return f.getmask(ch).getbbox() is not None
    except Exception:
        return False


BOX = {
    "│": "UD", "─": "LR", "╭": "DR", "╮": "DL", "╰": "UR", "╯": "UL", "┌": "DR", "┐": "DL",
    "└": "UR", "┘": "UL", "├": "UDR", "┤": "UDL", "┬": "LRD", "┴": "LRU", "┼": "UDLR",
    "╴": "L", "╶": "R", "╵": "U", "╷": "D",
}


def special(d, ch, x0, y0, fg):
    x1, y1 = x0 + CW - 1, y0 + CH - 1
    cx, cy = x0 + CW // 2, y0 + CH // 2
    if ch in BOX:
        for s in BOX[ch]:
            if s == "U":
                d.line([cx, y0, cx, cy], fill=fg, width=2)
            elif s == "D":
                d.line([cx, cy, cx, y1], fill=fg, width=2)
            elif s == "L":
                d.line([x0, cy, cx, cy], fill=fg, width=2)
            elif s == "R":
                d.line([cx, cy, x1, cy], fill=fg, width=2)
        return True
    if ch == "╱":
        d.line([x1, y0, x0, y1], fill=fg, width=2)
        return True
    if ch == "╲":
        d.line([x0, y0, x1, y1], fill=fg, width=2)
        return True
    o = ord(ch)
    if 0xE0B0 <= o <= 0xE0BF:
        polys = {
            0xE0B0: [(x0, y0), (x1, cy), (x0, y1)], 0xE0B2: [(x1, y0), (x0, cy), (x1, y1)],
            0xE0B8: [(x0, y0), (x1, y1), (x0, y1)], 0xE0BA: [(x1, y0), (x1, y1), (x0, y1)],
            0xE0BC: [(x0, y0), (x1, y0), (x0, y1)], 0xE0BE: [(x0, y0), (x1, y0), (x1, y1)],
        }
        if o in polys:
            d.polygon(polys[o], fill=fg)
        elif o == 0xE0B4:
            d.pieslice([x0 - CW, y0, x1, y1], -90, 90, fill=fg)
        elif o == 0xE0B6:
            d.pieslice([x0, y0, x1 + CW, y1], 90, 270, fill=fg)
        elif o in (0xE0B1, 0xE0B5, 0xE0B9, 0xE0BD):
            d.line([x0, y0, x1, cy, x0, y1], fill=fg, width=1)
        else:
            d.line([x1, y0, x0, cy, x1, y1], fill=fg, width=1)
        return True
    return False


def draw(frame):
    rows = frame["rows"]
    cols = sum(len(run[0]) for run in rows[0])
    img = Image.new("RGB", (cols * CW, len(rows) * CH), rgb(frame["bg"]))
    d = ImageDraw.Draw(img)
    for y, runs in enumerate(rows):
        x = 0
        for text, fg, bg, attr in runs:
            n = len(text)
            d.rectangle([x * CW, y * CH, (x + n) * CW - 1, (y + 1) * CH - 1], fill=rgb(bg))
            f = bold if attr & 1 else font
            for i, ch in enumerate(text):
                if ch in (" ", ""):
                    continue
                px = (x + i) * CW
                if special(d, ch, px, y * CH, rgb(fg)):
                    continue
                d.text((px, y * CH + 1), ch, font=f if has_glyph(f, ch) else fb, fill=rgb(fg))
            if attr & 4:
                d.line([x * CW, (y + 1) * CH - 2, (x + n) * CW, (y + 1) * CH - 2], fill=rgb(fg))
            x += n
    return img


def overlay(img, cap):
    """Key-cast box, bottom right above the status line: key chips and what they do."""
    if not cap or not cap[0]:
        return img
    keys, label = cap
    img = img.convert("RGBA")
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    chips = keys.split(" ")
    pad, gap = 10, 6
    widths = [d.textlength(k, font=UI) + 16 for k in chips]
    lw = d.textlength(label, font=UI_SMALL) if label else 0
    w = int(sum(widths) + gap * (len(chips) - 1) + (lw + 18 if label else 0) + pad * 2)
    h = 44
    x0 = img.width - w - 16
    y0 = img.height - h - CH * 2 - 6
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=10, fill=(22, 24, 34, 235),
                        outline=(122, 162, 247, 255), width=2)
    x = x0 + pad
    for k, kw in zip(chips, widths):
        d.rounded_rectangle([x, y0 + 8, x + kw, y0 + h - 8], radius=6, fill=(122, 162, 247, 255))
        d.text((x + 8, y0 + 11), k, font=UI, fill=(22, 24, 34, 255))
        x += kw + gap
    if label:
        d.text((x + 10, y0 + 13), label, font=UI_SMALL, fill=(220, 225, 240, 255))
    return Image.alpha_composite(img, layer).convert("RGB")


CAP_MS = 2600


def cap_at(caps, now):
    cur = None
    for t0, c in caps:
        if t0 <= now:
            cur = (t0, c)
    return cur[1] if cur and now - cur[0] < CAP_MS else None


def main():
    src, out = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    speed = float(args[args.index("--speed") + 1]) if "--speed" in args else 1.0
    png_every = int(args[args.index("--png-every") + 1]) if "--png-every" in args else 0
    frames, durs, caps = [], [], []
    with open(src, encoding="utf-8") as fh:
        for line in fh:
            ev = json.loads(line)
            if "mark" in ev:
                frames, durs, caps = [], [], []
            elif "cap" in ev:
                caps.append((sum(durs), (ev["cap"], ev["label"])))
            elif "extend" in ev:
                if durs:
                    durs[-1] += ev["extend"]
            elif "frame" in ev:
                frames.append(ev["frame"])
                durs.append(ev["ms"])
    print(f"{len(frames)} frames, {sum(durs) / 1000:.1f} s, {len(caps)} captions")
    starts, t = [], 0
    for dur in durs:
        starts.append(t)
        t += dur
    if png_every:
        base = os.path.splitext(out)[0]
        for i in range(0, len(frames), png_every):
            overlay(draw(frames[i]), cap_at(caps, starts[i] + durs[i] - 1)).save(f"{base}_{i:04d}.png")
        overlay(draw(frames[-1]), cap_at(caps, t - 1)).save(f"{base}_last.png")
        return
    imgs, out_durs = [], []
    for f, t0, dur in zip(frames, starts, durs):
        base_img = draw(f)
        cuts = {t0, t0 + dur}
        for c0, _ in caps:
            for edge in (c0, c0 + CAP_MS):
                if t0 < edge < t0 + dur:
                    cuts.add(edge)
        cuts = sorted(cuts)
        for a, b in zip(cuts, cuts[1:]):
            imgs.append(overlay(base_img, cap_at(caps, a)))
            out_durs.append(b - a)
    pal = [im.convert("P", palette=Image.ADAPTIVE, colors=160) for im in imgs]
    out_durs = [max(20, int(d / speed)) for d in out_durs]
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=out_durs, loop=0,
                optimize=True, disposal=1)
    print(out, os.path.getsize(out) // 1024, "KB")


main()
