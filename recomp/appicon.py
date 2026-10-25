"""Make an iOS app icon from a Mac game's .icns.

Mac icons carry their own shape on a transparent background (a rounded square, a
badge...); iOS wants an opaque square and applies its own mask. The artwork is
cropped to its visible pixels, placed with a margin on a background in the
colour of the artwork's outer edge, and written as the single 1024px icon of the
Xcode project's AppIcon set.

Runs in the engine's virtualenv (Pillow comes with UnityPy).
usage: appicon.py <Game.icns> <AppIcon.appiconset dir>
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

SIZE = 1024
MARGIN = 0.08  # of the final size on each side, so iOS's corner mask clears the artwork


def largest_image(icns):
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run(["iconutil", "-c", "iconset", icns, "-o", os.path.join(tmp, "x.iconset")],
                       check=True, capture_output=True)
        folder = os.path.join(tmp, "x.iconset")
        best = max((Image.open(os.path.join(folder, n)) for n in os.listdir(folder) if n.endswith(".png")),
                   key=lambda im: im.width * im.height)
        return best.convert("RGBA").copy()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def edge_colour(img):
    """Most common colour among opaque pixels on the artwork's outer edge.

    The most common rather than the average: a badge's ring dominates its edge,
    and averaging would mix in whatever pokes out of it (a hat brim, a sword).
    """
    w, h = img.size
    px = img.load()
    buckets = {}
    for y in range(0, h, max(1, h // 256)):
        row = [x for x in range(w) if px[x, y][3] > 200]
        for x in (row[:4] + row[-4:]) if row else []:
            r, g, b, _ = px[x, y]
            key = (r >> 4, g >> 4, b >> 4)
            acc = buckets.setdefault(key, [0, 0, 0, 0])
            acc[0] += r
            acc[1] += g
            acc[2] += b
            acc[3] += 1
    if not buckets:
        return (0, 0, 0)
    r, g, b, n = max(buckets.values(), key=lambda a: a[3])
    return (r // n, g // n, b // n)


def make_icon(icns, appiconset):
    art = largest_image(icns)
    bbox = art.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    if bbox:
        art = art.crop(bbox)
    inner = int(SIZE * (1 - 2 * MARGIN))
    scale = inner / max(art.size)
    art = art.resize((max(1, round(art.width * scale)), max(1, round(art.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (SIZE, SIZE), edge_colour(art) + (255,))
    canvas.alpha_composite(art, ((SIZE - art.width) // 2, (SIZE - art.height) // 2))

    for n in os.listdir(appiconset):
        os.remove(os.path.join(appiconset, n))
    canvas.convert("RGB").save(os.path.join(appiconset, "AppIcon-1024.png"))
    with open(os.path.join(appiconset, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios",
                               "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    make_icon(sys.argv[1], sys.argv[2])
    print(f"[recomp] app icon made from {os.path.basename(sys.argv[1])}", flush=True)
