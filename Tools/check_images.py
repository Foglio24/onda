"""Checks that the repository's PNG and JPEG images are whole, and the app icon's size.

Usage: python3 Tools/check_images.py   (from the repository root)

A PNG is read chunk by chunk (each checksum, an IEND at the very end) and its image data is
inflated in full: 1.21.1's and 1.22.1's app icons had a block of their data replaced, and iOS
drew their top rows only. A JPEG must start and end with its markers. The app icon must be a
1024 x 1024 PNG without transparency.
"""

import os
import struct
import sys
import zlib

ICON = os.path.join("Seaglass", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def check_png(path):
    """The problem with the file, or None. Returns (problem, width, height, color type)."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return "not a PNG", 0, 0, None
    position, compressed, header = 8, b"", None
    while True:
        if position + 12 > len(data):
            return "ends before IEND", 0, 0, None
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        if len(body) != length or position + 12 + length > len(data):
            return f"chunk {kind!r} at {position} runs past the end", 0, 0, None
        crc = struct.unpack(">I", data[position + 8 + length:position + 12 + length])[0]
        if zlib.crc32(kind + body) != crc:
            return f"chunk {kind!r} at {position} is damaged (checksum)", 0, 0, None
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed += body
        position += 12 + length
        if kind == b"IEND":
            break
    if position != len(data):
        return f"{len(data) - position} bytes after IEND", 0, 0, None
    if header is None:
        return "no IHDR", 0, 0, None
    width, height, depth, color, _, _, interlace = header
    try:
        inflater = zlib.decompressobj()
        raw = inflater.decompress(compressed) + inflater.flush()
    except zlib.error as error:
        return f"image data damaged ({error})", width, height, color
    if not inflater.eof:
        return "image data cut short", width, height, color
    if interlace == 0:
        row = 1 + (width * CHANNELS.get(color, 4) * depth + 7) // 8
        if len(raw) != row * height:
            return f"{len(raw)} bytes of pixels, {row * height} expected", width, height, color
        if any(raw[r * row] > 4 for r in range(height)):
            return "invalid row filters", width, height, color
    return None, width, height, color


def check_jpeg(path):
    data = open(path, "rb").read()
    if data[:2] != b"\xff\xd8":
        return "not a JPEG"
    if data.rstrip(b"\x00")[-2:] != b"\xff\xd9":
        return "cut short (no end marker)"
    return None


def main():
    problems = []
    count = 0
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in (".git", "build", "DerivedData", "Generated")]
        for name in files:
            path = os.path.join(root, name)[2:]
            lower = name.lower()
            if lower.endswith(".png"):
                problem, width, height, color = check_png(path)
                if problem is None and path == ICON and (width, height, color) != (1024, 1024, 2):
                    problem = f"the app icon is {width} x {height}, color type {color}: a 1024 x 1024 RGB PNG is needed"
            elif lower.endswith((".jpg", ".jpeg")):
                problem = check_jpeg(path)
            else:
                continue
            count += 1
            if problem:
                problems.append(f"{path}: {problem}")
    if not os.path.exists(ICON):
        problems.append(f"{ICON}: missing")
    for problem in problems:
        print("FAIL", problem)
    print(f"check_images: {count} images, {len(problems)} damaged" if problems else f"check_images: {count} images, all whole")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
