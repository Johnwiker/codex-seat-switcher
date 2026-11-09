"""Seat Picker app icon: a white chair on a blue rounded-square tile.
Run: python make_icon.py  -> seat-icon.png (512 px) and seat-icon.ico (16..256 px)."""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024
TOP, BOTTOM = (79, 145, 255), (29, 78, 216)
WHITE = (255, 255, 255)
SHADE = (214, 228, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def icon(small=False):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    grad = Image.new("RGB", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(TOP, BOTTOM, y / S))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((40, 40, S - 40, S - 40), radius=228, fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((40, 40, S - 40, S - 40), radius=228, outline=(140, 186, 255), width=6)

    w = 1.12 if small else 1.0                 # chunkier strokes for tiny sizes
    # backrest
    d.rounded_rectangle((330, 210, 694, 560), radius=int(70 * w), fill=WHITE)
    if not small:
        d.rounded_rectangle((380, 262, 644, 300), radius=19, fill=SHADE)   # stitch line
    # armrests
    d.rounded_rectangle((250, 470, int(250 + 92 * w), 700), radius=46, fill=WHITE)
    d.rounded_rectangle((int(774 - 92 * w), 470, 774, 700), radius=46, fill=WHITE)
    # seat cushion
    d.rounded_rectangle((280, 590, 744, 712), radius=int(56 * w), fill=WHITE)
    # legs
    lw = int(54 * w)
    d.rounded_rectangle((330, 700, 330 + lw, 830), radius=lw // 2, fill=WHITE)
    d.rounded_rectangle((694 - lw, 700, 694, 830), radius=lw // 2, fill=WHITE)
    return img


icon().resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, "seat-icon.png"))
imgs = [icon().resize((s, s), Image.LANCZOS) for s in (256, 128, 64, 48)] + \
       [icon(small=True).resize((s, s), Image.LANCZOS) for s in (32, 24, 16)]
imgs[0].save(os.path.join(HERE, "seat-icon.ico"), format="ICO", sizes=[i.size for i in imgs], append_images=imgs[1:])
print("written seat-icon.png and seat-icon.ico")
