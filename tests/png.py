"""A minimal PNG reader for tests that check the colors a window drew.

Supports what WPF and AppKit write: 8-bit RGB or RGBA, not interlaced. Standard library only.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

Pixel = tuple[int, int, int, int]


def read_png(path: Path) -> tuple[int, int, list[Pixel]]:
    """Width, height and the RGBA pixels, row by row."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    width = height = color_type = 0
    compressed = b""
    offset = 8
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset : offset + 4])
        kind = data[offset + 4 : offset + 8]
        body = data[offset + 8 : offset + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or color_type not in (2, 6) or interlace:
                raise ValueError(f"unsupported PNG: depth {depth}, color type {color_type}")
        elif kind == b"IDAT":
            compressed += body
        offset += 12 + length
    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(compressed)
    rows: list[bytearray] = []
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        line = bytearray(raw[start + 1 : start + 1 + stride])
        for x in range(stride):
            left = line[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if kind == 1:
                line[x] = (line[x] + left) & 0xFF
            elif kind == 2:
                line[x] = (line[x] + up) & 0xFF
            elif kind == 3:
                line[x] = (line[x] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                nearest = left if pa <= pb and pa <= pc else up if pb <= pc else corner
                line[x] = (line[x] + nearest) & 0xFF
        rows.append(line)
        previous = line
    pixels: list[Pixel] = []
    for line in rows:
        for x in range(0, stride, channels):
            alpha = line[x + 3] if channels == 4 else 255
            pixels.append((line[x], line[x + 1], line[x + 2], alpha))
    return width, height, pixels


def count_color(pixels: list[Pixel], hex_color: str, tolerance: int = 12) -> int:
    """How many opaque pixels are within `tolerance` of a #RRGGBB color on every channel."""
    target = tuple(int(hex_color.lstrip("#")[i : i + 2], 16) for i in (0, 2, 4))
    return sum(
        1
        for r, g, b, a in pixels
        if a > 200 and all(abs(c - t) <= tolerance for c, t in zip((r, g, b), target, strict=True))
    )
