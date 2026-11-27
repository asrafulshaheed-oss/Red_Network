#!/usr/bin/env python3
"""
Locked by BossDefender - scary black & red skull (16:9)
---------------------------------------------------------
Needs ONLY Pillow:   pip install pillow
(tkinter comes with Python itself.)

* No image / font / other files are used. The skull's outline is stored
  inside this script as vector shape data (SHAPE_DATA at the bottom of the
  settings), and everything is drawn by code.
* NOTHING is saved to disk - it just opens on your screen.

Run:      python locked_skull_v3.py
Close:    press  Esc  or  Q   (F11 = fullscreen on/off, double-click = close)
"""

import base64
import zlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops, ImageOps

# ------------------------------------------------------------------ settings
WIDTH, HEIGHT = 1920, 1080          # picture size (16:9)
TEXT = "Locked by BossDefender"
SKULL_SIZE = 0.86                   # skull height as a fraction of the picture height
SKULL_Y = 0.45                      # vertical centre of the skull (0 = top, 1 = bottom)
SS = 2                              # quality (2 = nicer, 1 = faster)
# ---------------------------------------------------------------------------

RAD_DATA = 501.378                      # radius of the traced circle, in data units
LEVEL_W = [8, 14, 16, 16, 16, 16, 16, 16, 16, 34]       # brightness added by each traced level

SHAPE_DATA = (
    "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"
    "q8H6vDulsqn8e7Zju/ppTH2lpG52aKufaqbSSNF3GIKl29SoXontVxzp49bxlBFdMp1sPpx8WvHuUsSXfalr/dookOQzDaOe"
    "sFWlij9pkvEk8yLrxTsBHv/h74O9JuYH4aV2n1gS4+n74v/Hv3wdfn9uPlJbgKHHl17WS6YmK7rax+guP+DFfRIfLqRG2T3g"
    "OwmdWd40qD6XFv2q39T7OdY0UPNDBy9qA5Ady/74jlE/+yyXt+C6oiym6lgEME5C3ys4fF70PQgZhuy/qb/ZQJiVygw7SYFs"
    "HNLZ1u/kLHq52kFdXPEXdU9xEJop+/ePI//i4LpkjblUVbZX7Cp7LxffCCFgp9ZkDASOYXJPphzcySx5vSSKpkKlnpauqJWi"
    "ujXMu2E7aii/s7KXCm6uZtkE4N9Y5TULXg0udFdvv0+KidOF+67B1isYuqbOAo9LPaG+NDWvLkXbGSfyHeC+2R6kqL+VnLUF"
    "BL5W0WGnMjDRG2owydDYI6OkxHmRYkOR9kUDyP5mvXUXRgTGrXkGs6nI7FL0zD6gKU3kmcUmQSTMSiUUL6vxB2XTo6vw+moy"
    "1rNrdnCQhjrUQ2oca/SNRPib4mIWu7PWKjCb7GdTQkAaph4UnT7JqezWBTdYU0YQLht7811sbruLtg3AXsnmWgaW5CGxHLl0"
    "9TsBB8vQzGGA8OIk1X17zYtNq3jSpiwh2xvYPgWPS0Za7qDzWk5T+jHhizHfpEQrpNw9OzpG9sRDa2PiiwO9dUzcgZ6rmehQ"
    "nDgFbM9XlOCMxQJtcmT8u1x9IhcbJM6UZk4lWJ2hgzumFkLBynGr9HpIp2pcigTryqzPHz4xq7ljENs5bRpQ0XpZn/jA6Wev"
    "DjRdCRiBHGFl+7hiyJnAdskuIzayPhcB9RLAP38Vc5QlgKhLYztZEUmXfAW6Vuy/fMkzVVHT2HihDyGf0ssOWGRmXWG7OmBD"
    "9sCDA9FD2dFiYUiKNLpRRBG493uhc+xsVqmY0iWlGZrYptKuAVJnZavbj5BJJAStUn0DaiABH9wqMWpp29pPlUhFUpe42fnc"
    "ieGnjoZow1nT5ZwpudQS/y5ZXeWZE2+/Z0lmDQzXfpW9TC0yiQIbmjBsrPEqTmu91aW6+knZ3QWR9YM9iKpOf0RbT6qWoNCI"
    "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"
    "6sB9Ub8aLrkc9JtJA8euqV+hM7It+jIGAz0rIXR+QWGhs6sC5SQ3SGNLsvgKcKLIs4HRHEon4lqzrV2HJkwXp7CFbuSC9GWE"
    "8spliEl11YdmP+qRhJxgL9i44435tAQEqSa2f9h9LQVy+48Wc7bgGglVMhuuLFP26AJ8YaZsTL2peZR2rpD8nekmVHKFcvOx"
    "87FBR6VdmHjLqjIL1KKplg5t51IhlezursMBZIDySFegcWXJMbvqTFlvi9TsB6Wb5Xl17PAoqUmWqRmGt6gOmUr+sul5ZxnA"
    "0Ok4WPrPIhBJvLO1SSGlg+XE/RIhykKx96Kpq+Gzul5LyIPdxctzcbiKUiYzmdf9SkE1CeboC+8lQs5i2hp8/5TAtCYCb6DN"
    "W9STiRTVpfQ2k3DRszanq2LFvYa6E0nt0WUc3U+MohMX0ZCKC+NS/z57TRTag6uW5yJHiGMV0OsEZKneHv+BKVuvnqQXU3Zc"
    "AXFNHwFyCH+TY/8TTIkwYydMeXW5vmFKhL+qbMp2PCknN2+J2HqfOf0SrC4pfjDh+A5ywDaQy/UTblkn54+gz1S6hCWNRjDQ"
    "nmh3XT2TdDzhBy2YL6FauzsmjEs2dgIvlUqPtHHm5UPuB6mLOgBzRGczn/D1wM0IZn4FCf29OooPUV/CWBsJov1hoRj4here"
    "tfldCeSIWmtCA6MqsJlEiC/0OqXlXnk1PRUP6ksi8ES5TGQvNhKYnUKvV5MLtU2sqZwL/fRKRBbnFCxPlStCyeasV7ee1xuE"
    "b36qCJFTZflog4/tYnEil5D2UyObNmHMk8NhqNBR1ndeSjaUSNbWsnaXwZj63K6n/4Sv4ya891/JW8vKiShZSfDTLsbr1UtB"
    "XW1e8AiYeaPg7GBHeXYn75SloVaofLwlQhoVPrnn7GplNHToFdar7wAkm4d58Rn0QdsKKbuYUFWwwadeLQoBPS7lhi4e17pZ"
    "I/Ma4RBVOO20cAjaVjuXmm2mkh8swalk3vebgtWU/5Ocy0ulXVIV4CTUS7hhMP6+upFk6LqeC25PkDbbUhnmJruPdGnKSP4V"
    "BIBPEx9p070dQb9QV+Mu7qYxtJRCbkBCgfoNZ/gkkVkBmz1X6IX8/0vsr39naUFCuF9bvD+pAgsxvUAB+8H3EuIe90ez2Dka"
    "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"
)


# colour ramp sampled from the reference:  brightness -> (R, G, B)
RAMP = [(0, (2, 0, 0)), (6, (8, 1, 1)), (28, (36, 10, 10)), (55, (74, 20, 19)),
        (85, (108, 24, 22)), (115, (137, 24, 19)), (140, (172, 33, 27)),
        (160, (190, 34, 27)), (180, (205, 32, 26))]

W, H = WIDTH * SS, HEIGHT * SS
CX, CY = W // 2, int(H * SKULL_Y)
RPX = H * SKULL_SIZE / 2            # skull circle radius in pixels
K = RPX / RAD_DATA                  # data units -> pixels


def clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def noise(blur, sigma=64):
    n = Image.effect_noise((W, H), sigma)
    if blur:
        n = n.filter(ImageFilter.GaussianBlur(blur))
    return ImageOps.autocontrast(n, cutoff=1)


def load_font(size):
    names = [
        "impact.ttf", "Impact.ttf", "C:/Windows/Fonts/impact.ttf",
        "C:/Windows/Fonts/arialbd.ttf",
        "/System/Library/Fonts/Supplemental/Impact.ttf", "/Library/Fonts/Impact.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "DejaVuSans-Bold.ttf", "arialbd.ttf",
    ]
    for n in names:
        try:
            return ImageFont.truetype(n, size)
        except OSError:
            pass
    try:
        return ImageFont.load_default(size)
    except TypeError:
        return ImageFont.load_default()


def load_layers():
    txt = zlib.decompress(base64.b64decode("".join(SHAPE_DATA))).decode()
    layers = []
    for line in txt.split("\n"):
        if line == "#":
            layers.append([])
            continue
        v = line.split()
        nums = list(map(int, v[1:]))
        x, y = nums[0], nums[1]
        pts = [(x, y)]
        for i in range(2, len(nums), 2):
            x += nums[i]
            y += nums[i + 1]
            pts.append((x, y))
        layers[-1].append((int(v[0]), pts))
    return layers


def ramp_lut(channel):
    lut = []
    total = sum(LEVEL_W)
    for i in range(256):
        val = i * total / 255.0
        for (a, ca), (b, cb) in zip(RAMP, RAMP[1:]):
            if val <= b:
                t = (val - a) / float(b - a) if b > a else 0
                lut.append(clamp(ca[channel] + (cb[channel] - ca[channel]) * max(0.0, t)))
                break
        else:
            lut.append(RAMP[-1][1][channel])
    return lut


# =====================================================================
def render():
    # ---------------------------------------------- 1) rebuild the skull from the shape data
    tone = Image.new("L", (W, H), 0)
    for weight, layer in zip(LEVEL_W, load_layers()):
        mk = Image.new("L", (W, H), 0)
        d = ImageDraw.Draw(mk)
        for flag, pts in layer:                      # filled shapes, then holes inside them
            d.polygon([(CX + x * K, CY + y * K) for x, y in pts], fill=255 if flag else 0)
        tone = ImageChops.add(tone, mk.point(lambda v, w=weight: v * w // 255))
    total = float(sum(LEVEL_W))
    tone = tone.point(lambda v: clamp(v * 255 / total))
    tone = tone.filter(ImageFilter.GaussianBlur(0.6 * K))          # smooth the stair-steps

    # crisp, high-contrast "engraved" look like the reference
    def curve(v):
        x = min(1.0, max(0.0, (v / 255.0 - 0.06) / 0.84))
        return int(255 * (0.55 * x + 0.45 * x * x * (3 - 2 * x)))
    tone = tone.point(curve)
    tone = tone.filter(ImageFilter.UnsharpMask(radius=1.0 * SS, percent=150, threshold=3))

    # ---------------------------------------------- 2) ragged fade where the circle clipped it
    edge = Image.new("L", (W, H), 0)
    ImageDraw.Draw(edge).ellipse([CX - RPX * 0.975, CY - RPX * 0.975,
                                  CX + RPX * 0.975, CY + RPX * 0.975], fill=255)
    edge = edge.filter(ImageFilter.GaussianBlur(0.035 * RPX))
    ragged = noise(2.2 * SS).point(lambda v: int(v * 0.8))
    fade = ImageChops.subtract(edge, ragged).point(lambda v: clamp(v * 3))
    tone = ImageChops.multiply(tone, fade)

    # ---------------------------------------------- 3) colour + grit
    skull = Image.merge("RGB", [tone.point(ramp_lut(c)) for c in range(3)])
    grit = ImageChops.multiply(noise(0.7 * SS).point(lambda v: 200 + v * 55 // 255),
                               noise(4 * SS).point(lambda v: 225 + v * 30 // 255))
    specks = noise(0.9 * SS).point(lambda v: 120 if v > 238 else 255).filter(ImageFilter.GaussianBlur(0.5 * SS))
    skull = ImageChops.multiply(skull, ImageChops.multiply(grit, specks).convert("RGB"))

    canvas = Image.new("RGB", (W, H), RAMP[0][1])
    canvas = ImageChops.lighter(canvas, skull)

    # soft red bloom around the bright bone
    for blur, amount in ((0.015 * RPX, 0.30), (0.10 * RPX, 0.35)):
        bloom = skull.filter(ImageFilter.GaussianBlur(blur)).point(lambda v, a=amount: int(v * a))
        canvas = ImageChops.screen(canvas, bloom)

    # ---------------------------------------------- 4) bottom text
    size = int(0.085 * H)
    font = load_font(size)
    track = int(size * 0.14)
    widths = [font.getlength(c) for c in TEXT]
    total_w = sum(widths) + track * (len(TEXT) - 1)
    ty = int(H * 0.935)

    tm = Image.new("L", (W, H), 0)
    tdw = ImageDraw.Draw(tm)
    x = CX - total_w / 2
    for ch, w in zip(TEXT, widths):
        try:
            tdw.text((x, ty), ch, font=font, fill=255, anchor="lm")
        except ValueError:
            tdw.text((x, ty - size // 2), ch, font=font, fill=255)
        x += w + track

    gap = 0.035 * W
    for side in (-1, 1):
        start = CX + side * (total_w / 2 + gap)
        seg = 8 * SS
        n = int(0.16 * W / seg)
        for i in range(n):
            a = int(255 * (1 - i / n) ** 1.3)
            tdw.line([(start + side * i * seg, ty), (start + side * (i + 1) * seg, ty)],
                     fill=a, width=3 * SS)
        dx, r = CX + side * (total_w / 2 + gap * 0.5), 7 * SS
        tdw.polygon([(dx, ty - r), (dx + r, ty), (dx, ty + r), (dx - r, ty)], fill=255)

    t_alpha = ImageChops.multiply(
        tm, noise(1.0 * SS).point(lambda v: 255 if v > 28 else 0).filter(ImageFilter.GaussianBlur(0.6 * SS)))
    canvas.paste(Image.new("RGB", (W, H), (190, 0, 0)),
                 mask=tm.filter(ImageFilter.GaussianBlur(0.012 * H)).point(lambda v: int(v * 0.8)))
    canvas.paste(Image.new("RGB", (W, H), (205, 32, 26)), mask=t_alpha)

    # ---------------------------------------------- 5) vignette, resize, film grain
    vig = Image.radial_gradient("L").resize((W, H), Image.BICUBIC)
    vig = vig.point(lambda v: int(255 - 255 * 0.85 * max(0.0, (v - 110) / 145) ** 1.4))
    canvas = ImageChops.multiply(canvas, vig.convert("RGB"))
    canvas = canvas.resize((WIDTH, HEIGHT), Image.LANCZOS)
    grain = Image.effect_noise((WIDTH, HEIGHT), 20).convert("RGB")
    return Image.blend(canvas, ImageChops.soft_light(canvas, grain), 0.30)


# =====================================================================
def main():
    try:
        import tkinter as tk
        from PIL import ImageTk
    except ImportError:
        print("tkinter not available - opening with your default image viewer instead")
        render().show()
        return

    root = tk.Tk()
    root.title("Locked by BossDefender")
    root.configure(bg="black")
    state = {"full": True}
    try:
        root.attributes("-fullscreen", True)
    except tk.TclError:
        root.geometry("1280x720")

    label = tk.Label(root, text="Summoning the skull...", fg="#c00000", bg="black",
                     font=("Arial", 22, "bold"))
    label.pack(expand=True, fill="both")
    root.update()

    img = render()

    def fit(_event=None):
        sw, sh = root.winfo_width(), root.winfo_height()
        if sw < 50 or sh < 50:
            return
        k = min(sw / WIDTH, sh / HEIGHT)
        pic = img.resize((max(1, int(WIDTH * k)), max(1, int(HEIGHT * k))), Image.LANCZOS)
        photo = ImageTk.PhotoImage(pic)
        label.config(image=photo, text="")
        label.image = photo

    def toggle_full(_event=None):
        state["full"] = not state["full"]
        root.attributes("-fullscreen", state["full"])
        if not state["full"]:
            root.geometry("1280x720")

    root.bind("<Escape>", lambda e: root.destroy())
    root.bind("q", lambda e: root.destroy())
    root.bind("<F11>", toggle_full)
    root.bind("<Double-Button-1>", lambda e: root.destroy())
    root.bind("<Configure>", lambda e: root.after_idle(fit) if e.widget is root else None)
    fit()
    root.mainloop()


if __name__ == "__main__":
    main()
