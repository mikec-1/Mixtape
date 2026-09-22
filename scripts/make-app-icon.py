# Usage: python3 scripts/make-app-icon.py Mixtape/Assets.xcassets/AppIcon.appiconset  (needs Pillow)
# Mixtape app icon: the launch mark (black waveform knocked out of orange), redrawn by hand.
# Bar proportions measured off waveform.circle.fill so the icon matches the launch screen.
import sys
from PIL import Image, ImageDraw, ImageFilter
X = 4                                               # supersample
HEIGHTS = [0.149, 0.320, 0.558, 0.229, 0.418, 0.190]  # of body size
BAR_W, PITCH = 0.061, 0.1025
ORANGE, INK = (255, 107, 0, 255), (18, 18, 18, 255)   # mixPrimary, mixBackground (dark)

def bars(s, color):
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0)); d = ImageDraw.Draw(out)
    w = BAR_W * s
    for i, h in enumerate(HEIGHTS):
        cx = s / 2 + (i - (len(HEIGHTS) - 1) / 2) * PITCH * s
        d.rounded_rectangle([cx - w / 2, (s - h * s) / 2, cx + w / 2, (s + h * s) / 2], radius=w / 2, fill=color)
    return out

def ios(bg, fg):
    s = 1024 * X
    img = Image.new("RGBA", (s, s), bg); img.alpha_composite(bars(s, fg))
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
    img.paste(ORANGE, (0, 0), body)
    img.alpha_composite(bars(b, INK), (o, o))
    return img.resize((1024, 1024), Image.LANCZOS)

out = sys.argv[1]
ios(ORANGE, INK).save(f"{out}/ios-light.png")
ios((0, 0, 0, 0), ORANGE).save(f"{out}/ios-dark.png")           # system supplies the dark backdrop
ios((0, 0, 0, 0), (235, 235, 235, 255)).save(f"{out}/ios-tinted.png")
m = mac()
for px in (16, 32, 64, 128, 256, 512, 1024):
    m.resize((px, px), Image.LANCZOS).save(f"{out}/mac-{px}.png")
