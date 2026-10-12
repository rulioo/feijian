#!/usr/bin/env python3
"""Draws the Feijian app icon and writes it as a multi-size .ico.

Run by hand, not by the build:

    python tool/make_app_icon.py

Output goes to `windows/runner/resources/app_icon.ico`, the resource `Runner.rc`
binds to `IDI_APP_ICON`. One resource serves four surfaces -- title bar,
taskbar, Alt-Tab, and the notification-area tray icon that `tray_window.cpp`
loads for close-to-tray -- which is why this replaces the stock Flutter icon
instead of adding a second file: a tray icon that did not match the taskbar
icon would read as two different programs.

The Android launcher icons (android/app/src/main/res/mipmap-*/) are *not*
touched by this script.

Kept in the repo as a script rather than committing only the .ico, because a
binary nobody can regenerate is a binary nobody can change. The drawing is
deliberately geometric -- a paper plane, which still reads at 16x16 where a
glyph or a letter would turn to mud.
"""

from __future__ import annotations

import pathlib
import struct

from PIL import Image, ImageDraw

# design.md §6.5: the product accent. Used here rather than a surface colour so
# the plate stays legible against both a light and a dark taskbar.
ACCENT = (14, 165, 233)       # #0EA5E9
ACCENT_DEEP = (2, 132, 199)   # #0284C7, the gradient's lower edge

# Windows asks for a 16x16 tray icon most often; 256 covers Alt-Tab and the
# shell's "extra large icons" view.
SIZES = (16, 24, 32, 48, 64, 128, 256)

# The plane's nose is a sharp point and its fold is a concave corner; both
# alias badly if drawn straight to size.
SS = 8

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "windows/runner/resources/app_icon.ico"
# Under build/, which is gitignored: this is an aid for the person running the
# script, not a file the repository needs to carry.
PREVIEW = ROOT / "build/icon-16x.png"


def _lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def draw_master(size: int) -> Image.Image:
    """One square RGBA icon at `size` px, drawn with supersampling."""
    big = size * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Rounded-square plate, radius as a fraction of the side -- the Windows 11
    # icon convention, and it stays round-looking at 16px.
    radius = int(big * 0.22)
    box = (0, 0, big - 1, big - 1)

    # Vertical gradient, masked to the plate so the corners stay transparent.
    # A per-row fill rather than per-pixel, which is the same result for a
    # linear gradient at a fraction of the cost.
    grad = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(big):
        gd.line((0, y, big, y), fill=_lerp(ACCENT, ACCENT_DEEP, y / (big - 1)))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # The plane, in unit coordinates so the geometry is resolution-independent.
    # Point order matters: left tail -> nose -> lower wing -> the concave fold
    # that makes it read as a plane rather than as a plain arrowhead.
    pts = [(0.16, 0.47), (0.86, 0.16), (0.60, 0.86), (0.47, 0.58)]
    d.polygon([(x * big, y * big) for x, y in pts], fill=(255, 255, 255, 255))

    return img.resize((size, size), Image.LANCZOS)


def _bmp_payload(img: Image.Image) -> bytes:
    """One ICO image entry as a 32bpp BMP: header, BGRA rows, then AND mask.

    BMP rather than PNG inside the .ico because a 16x16 tray icon is exactly
    where the shell's PNG path is least exercised, and the BMP form is what
    every icon tool emits for the small sizes.
    """
    w, h = img.size
    px = img.load()

    # Rows are bottom-up, and the AND mask (a 1-bit transparency mask, for
    # renderers that ignore the alpha channel) is presented as a second image
    # below the colour data -- which is why biHeight is twice the real height.
    xor = bytearray()
    and_stride = ((w + 31) // 32) * 4
    and_mask = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray()
        bits = bytearray(and_stride)
        for x in range(w):
            r, g, b, a = px[x, y]
            row += bytes((b, g, r, a))
            # 0 = opaque, 1 = transparent. A hard threshold at half alpha is
            # the convention; the colour channel already carries the soft edge.
            if a < 128:
                bits[x // 8] |= 0x80 >> (x % 8)
        xor += row
        and_mask += bits

    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        w,           # biWidth
        h * 2,       # biHeight: colour data + AND mask
        1,           # biPlanes
        32,          # biBitCount
        0,           # biCompression: BI_RGB
        len(xor) + len(and_mask),
        0, 0,        # biXPelsPerMeter, biYPelsPerMeter
        0, 0,        # biClrUsed, biClrImportant
    )
    return header + bytes(xor) + bytes(and_mask)


def _write_ico(frames: dict[int, Image.Image], path: pathlib.Path) -> None:
    """Assembles an .ico from per-size frames.

    Hand-rolled because Pillow's ICO writer takes a single image and derives
    the smaller entries by resampling it -- which would discard the frames
    drawn above and soften exactly the 16px entry that matters most.
    """
    sizes = sorted(frames)
    payloads = [_bmp_payload(frames[s]) for s in sizes]

    out = bytearray(struct.pack("<HHH", 0, 1, len(sizes)))  # reserved, type, count
    offset = 6 + 16 * len(sizes)
    for size, payload in zip(sizes, payloads):
        out += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,   # width, 0 means 256
            0 if size >= 256 else size,   # height, 0 means 256
            0,            # palette size, 0 for truecolour
            0,            # reserved
            1,            # colour planes
            32,           # bits per pixel
            len(payload),
            offset,
        )
        offset += len(payload)
    for payload in payloads:
        out += payload

    path.write_bytes(bytes(out))


def main() -> None:
    frames = {s: draw_master(s) for s in SIZES}

    OUT.parent.mkdir(parents=True, exist_ok=True)
    _write_ico(frames, OUT)

    # The 16px frame decides whether the icon is usable at all, so it is also
    # written out on its own: eyeball that before believing the icon is right.
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    frames[16].resize((128, 128), Image.NEAREST).save(PREVIEW)

    print(f"{OUT}  ({OUT.stat().st_size} bytes)  sizes={list(SIZES)}")
    print(f"{PREVIEW}  (the 16px frame, scaled 8x to inspect)")


if __name__ == "__main__":
    main()
