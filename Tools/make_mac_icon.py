"""Makes the Mac app's icons from the iPhone's (AppIcon.png), into the same icon set.

A Mac icon isn't a full square as on an iPhone: the artwork sits in the rounded square of macOS's
icon grid (824 of 1024 points, centred), with a soft shadow under it; macOS 26 would otherwise put
it, shrunk, on a grey tile. The edge gets a thin light rim, as glass catches the light.

    python3 Tools/make_mac_icon.py
"""

import json
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SET = os.path.join("Seaglass", "Assets.xcassets", "AppIcon.appiconset")
SIZES = [16, 32, 128, 256, 512]


def squircle(size, inset, exponent=5.0, scale=4):
    """The macOS icon shape (a superellipse, close to its continuous corners) as an antialiased mask."""
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    side = (size - 2 * inset) * scale
    half = side / 2
    centre = big / 2
    points = []
    steps = 2048
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = centre + half * math.copysign(abs(c) ** (2 / exponent), c)
        y = centre + half * math.copysign(abs(s) ** (2 / exponent), s)
        points.append((x, y))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def mac_icon(art):
    size = 1024
    inset = 100
    body = size - 2 * inset
    shape = squircle(size, inset)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # The shadow: the shape, blurred and a little lower.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(shape.point(lambda a: a * 0.32))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(shadow, (0, 10))

    # The artwork, scaled into the shape.
    scaled = art.convert("RGBA").resize((body, body), Image.LANCZOS)
    face = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    face.paste(scaled, (inset, inset))
    face.putalpha(shape)
    canvas.alpha_composite(face)

    # A thin light rim inside the edge, brighter at the top.
    inner = squircle(size, inset + 3)
    rim = ImageChops.subtract(shape, inner)
    gradient = Image.linear_gradient("L").resize((size, size)).point(lambda v: 255 - v)
    rim = ImageChops.multiply(rim, gradient.point(lambda v: int(60 + v * 0.55)))
    light = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    light.putalpha(rim)
    canvas.alpha_composite(light)
    return canvas


def main():
    art = Image.open(os.path.join(SET, "AppIcon.png"))
    icon = mac_icon(art)
    images = [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    written = set()
    for points in SIZES:
        for scale in (1, 2):
            pixels = points * scale
            name = f"AppIcon-mac-{pixels}.png"
            # 16 points at 2x and 32 at 1x are the same file.
            if name not in written:
                icon.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(SET, name), optimize=True)
                written.add(name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(SET, "Contents.json"), "w") as file:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, file, indent=2)
        file.write("\n")


if __name__ == "__main__":
    main()
