#!/usr/bin/env python3
"""Reject a bank diagnostic Stella snapshot unless it shows the green PASS frame."""

import sys
from PIL import Image


def main(path):
    image = Image.open(path).convert("RGB")
    width, height = image.size
    center = image.getpixel((width // 2, height // 2))
    if not (center[1] > center[0] + 30 and center[1] > center[2] + 30):
        raise SystemExit(f"FAIL-colored final frame: center={center}")
    pixels = image.get_flattened_data() if hasattr(image, "get_flattened_data") else image.getdata()
    bright = sum(
        1
        for red, green, blue in pixels
        if green > 150 and green > red + 30 and green > blue + 30
    )
    if bright < 100:
        raise SystemExit(f"PASS glyph missing or too small: bright-green pixels={bright}")
    print(f"{width}x{height} center={center} pass_pixels={bright}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} SNAPSHOT.png")
    main(sys.argv[1])
