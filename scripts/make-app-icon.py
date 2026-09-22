# Usage: python3 scripts/make-app-icon.py Mixtape/Assets.xcassets/AppIcon.appiconset  (needs Pillow)
# Mixtape app icon: orange waveform bars on black. Original drawing (SF Symbols can't be app icons).
import sys
from PIL import Image, ImageDraw, ImageFilter
X = 4                                   # supersample
HEIGHTS = [0.20, 0.38, 0.58, 0.42, 0.66, 0.46, 0.30, 0.18]  # of body size
BAR_W, GAP = 0.058, 0.040
TOP, BOT = (255, 140, 40), (255, 88, 0)   # around mixPrimary #FF6B00

def bars(s, tint=None):
    """RGBA layer of the waveform for a body of size s (already supersampled)."""
    mask = Image.new("L", (s, s), 0); d = ImageDraw.Draw(mask)
    w, g = BAR_W * s, GAP * s
    x = (s - (len(HEIGHTS) * w + (len(HEIGHTS) - 1) * g)) / 2
    for h in HEIGHTS:
        h *= s; y = (s - h) / 2
        d.rounded_rectangle([x, y, x + w, y + h], radius=w / 2, fill=255); x += w + g
    if tint: fill = Image.new("RGBA", (s, s), tint)
    else:
        grad = Image.linear_gradient("L").resize((s, s))
        fill = Image.merge("RGB", [Image.eval(grad, lambda v, a=a, b=b: int(a + (b - a) * v / 255)) for a, b in zip(TOP, BOT)]).convert("RGBA")
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0)); out.paste(fill, (0, 0), mask); return out

def ios(bg, tint=None):
    s = 1024 * X
    img = Image.new("RGBA", (s, s), bg); img.alpha_composite(bars(s, tint))
    img = img.resize((1024, 1024), Image.LANCZOS)
    return img.convert("RGB") if bg[3] == 255 else img

def mac():
    # Apple's macOS grid: 824pt body at 100pt inset, ~185pt corners, soft drop shadow.
    s, b, o = 1024 * X, 824 * X, 100 * X
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sh = Image.new("L", (s, s), 0)
    ImageDraw.Draw(sh).rounded_rectangle([o, o + 12 * X, o + b, o + b + 12 * X], radius=185 * X, fill=110)
    img.putalpha(sh.filter(ImageFilter.GaussianBlur(14 * X)))
    body = Image.new("L", (s, s), 0)
    ImageDraw.Draw(body).rounded_rectangle([o, o, o + b, o + b], radius=185 * X, fill=255)
    img.paste((12, 12, 12, 255), (0, 0), body)
    img.alpha_composite(bars(b), (o, o))
    return img.resize((1024, 1024), Image.LANCZOS)

out = sys.argv[1]
ios((0, 0, 0, 255)).save(f"{out}/ios-light.png")
ios((0, 0, 0, 0)).save(f"{out}/ios-dark.png")
ios((0, 0, 0, 0), tint=(235, 235, 235, 255)).save(f"{out}/ios-tinted.png")
m = mac()
for px in (16, 32, 64, 128, 256, 512, 1024):
    m.resize((px, px), Image.LANCZOS).save(f"{out}/mac-{px}.png")
