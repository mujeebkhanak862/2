"""Control Hub logo (brand/control_hub_logo.jpg) se saare app icons banata hai.
Chalane ka tareeqa (repo root se):  python3 brand/make_icons_from_logo.py
Sirf emblem use hota hai (neeche ka "CONTROL HUB" text nahi) — chhote icon
sizes par text padhne layak nahi rehta."""
from PIL import Image, ImageDraw
import numpy as np, os

SRC = "brand/control_hub_logo.jpg"
APP = "shared_app"
BG = (255, 255, 255)
BORDER = (214, 219, 232)

def load_emblem():
    im = Image.open(SRC).convert("RGB")
    a = np.array(im).astype(int)
    # JPEG noise saaf: lagbhag-safed => pure safed
    near_white = a.min(axis=2) > 238
    a[near_white] = 255
    im = Image.fromarray(a.astype("uint8"))
    # Emblem hissa (text se upar); rows 111..770 original logo mein
    nonwhite = a.min(axis=2) < 235
    rows = np.where(nonwhite[:790].any(axis=1))[0]
    cols = np.where(nonwhite[:790].any(axis=0))[0]
    box = (cols.min(), rows.min(), cols.max() + 1, rows.max() + 1)
    em = im.crop(box)
    s = max(em.size)
    sq = Image.new("RGB", (s, s), BG)
    sq.paste(em, ((s - em.width) // 2, (s - em.height) // 2))
    return sq

EMBLEM = load_emblem()
os.makedirs("brand", exist_ok=True)
EMBLEM.save("brand/emblem.png")

def emblem_at(px, fill=0.80, size=None):
    """Safed canvas par emblem (canvas ka `fill` hissa)."""
    size = size or px
    e = EMBLEM.resize((int(size * fill), int(size * fill)), Image.LANCZOS)
    c = Image.new("RGB", (size, size), BG)
    c.paste(e, ((size - e.width) // 2, (size - e.height) // 2))
    return c

def tile(px, shape="square"):
    """Launcher/desktop icon: safed tile + halka border (safed background par bhi dikhe)."""
    S = 1024
    base = emblem_at(S, 0.78).convert("RGBA")
    if shape == "round":
        mask = Image.new("L", (S, S), 0); ImageDraw.Draw(mask).ellipse([0, 0, S - 1, S - 1], fill=255)
    else:
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0)); out.paste(base, (0, 0), mask)
    border = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(border)
    w = max(6, S // 80)
    if shape == "round":
        d.ellipse([w // 2, w // 2, S - 1 - w // 2, S - 1 - w // 2], outline=BORDER + (255,), width=w)
    else:
        d.rounded_rectangle([w // 2, w // 2, S - 1 - w // 2, S - 1 - w // 2], radius=int(S * 0.22), outline=BORDER + (255,), width=w)
    out.alpha_composite(border)
    return out.resize((px, px), Image.LANCZOS)

def adaptive_fg(px):
    """108dp canvas; emblem safe zone (66dp = 61%) ke andar. Background safed."""
    return emblem_at(px, 0.56).convert("RGBA")

def monochrome(px):
    """Android 13 themed icon: koi bhi non-safed pixel => opaque (system rang dega)."""
    e = emblem_at(px * 4, 0.56)
    a = np.array(e).astype(int)
    alpha = np.clip((255 - a.min(axis=2)) * 3, 0, 255).astype("uint8")
    out = np.zeros((a.shape[0], a.shape[1], 4), dtype="uint8")
    out[..., 3] = alpha
    return Image.fromarray(out, "RGBA").resize((px, px), Image.LANCZOS)

R = f"{APP}/android/app/src/main/res"
for name, f in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}.items():
    d = f"{R}/mipmap-{name}"; os.makedirs(d, exist_ok=True)
    tile(int(48 * f)).save(f"{d}/ic_launcher.png")
    tile(int(48 * f), "round").save(f"{d}/ic_launcher_round.png")
    adaptive_fg(int(108 * f)).save(f"{d}/ic_launcher_foreground.png")
    monochrome(int(108 * f)).save(f"{d}/ic_launcher_monochrome.png")

os.makedirs(f"{R}/drawable-xxhdpi", exist_ok=True)
emblem_at(576, 0.60).convert("RGBA").save(f"{R}/drawable-xxhdpi/splash_logo.png")

master = tile(1024)
master.save("brand/app_icon_1024.png")
master.save(f"{APP}/windows/runner/resources/app_icon.ico",
            sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
for s in (16, 32, 48, 64, 128, 256, 512):
    d = f"{APP}/linux/packaging/icons/hicolor/{s}x{s}/apps"; os.makedirs(d, exist_ok=True)
    tile(s).save(f"{d}/com.deviceagent.app.png")
os.makedirs(f"{APP}/assets/brand", exist_ok=True)
tile(512).save(f"{APP}/assets/brand/logo.png")
print("ok")
