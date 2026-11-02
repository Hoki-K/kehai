# Draws the app icon: a quiet "ear" (three rings) around a small lamp, on night blue.
from PIL import Image, ImageDraw
import sys, os
def icon(size, scale=1.0, bg=(15, 18, 24)):
    S = size * 4
    im = Image.new('RGB', (S, S), bg)
    d = ImageDraw.Draw(im, 'RGBA')
    c = S / 2
    ink = (232, 229, 220)
    for r, a, w in ((0.42, 60, 0.012), (0.34, 120, 0.014), (0.26, 235, 0.018)):
        R = r * S * scale
        d.ellipse((c - R, c - R, c + R, c + R), outline=ink + (a,), width=max(1, int(w * S * scale)))
    R = 0.075 * S * scale
    d.ellipse((c - R, c - R, c + R, c + R), fill=(230, 161, 87, 255))
    return im.resize((size, size), Image.LANCZOS)
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
icon(1024).save(os.path.join(out, 'icon-1024.png'))
icon(512).save(os.path.join(out, 'icon-512.png'))
icon(192).save(os.path.join(out, 'icon-192.png'))
icon(180).save(os.path.join(out, 'apple-touch-icon.png'))
icon(512, scale=0.78).save(os.path.join(out, 'icon-maskable-512.png'))
print('icons written to', out)
