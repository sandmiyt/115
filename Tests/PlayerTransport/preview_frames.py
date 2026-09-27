"""Deterministic numbered RGB frames, no fonts/image packages required."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
digits = ["abcdef", "bc", "abged", "abgcd", "fgbc", "afgcd", "afgecd", "abc", "abcdefg", "abfgcd"]
segments = {"a": (2, 0, 12, 2), "b": (12, 2, 14, 12), "c": (12, 14, 14, 24),
            "d": (2, 24, 12, 26), "e": (0, 14, 2, 24), "f": (0, 2, 2, 12), "g": (2, 12, 12, 14)}
for number in range(144):
    width, height = 320, 180
    data = bytearray(bytes((20 + number % 80, 25, 50)) * (width * height))
    def rect(x0, y0, x1, y1, white=True):
        color = b"\xff\xff\xff" if white else b"\0\0\0"
        for y in range(y0, y1):
            data[(y * width + x0) * 3:(y * width + x1) * 3] = color * (x1 - x0)
    # Human-readable frame number and milliseconds, plus machine-readable bits.
    text = f"{number:03d}{round(number / 24 * 1000):04d}"
    for index, char in enumerate(text):
        for segment in digits[int(char)]:
            x0, y0, x1, y1 = segments[segment]
            rect(15 + index * 40 + x0 * 2, 15 + y0 * 2, 15 + index * 40 + x1 * 2, 15 + y1 * 2)
    for bit in range(8):
        rect(20 + bit * 32, 120, 40 + bit * 32, 140, bool(number & (1 << bit)))
    (root / f"{number:03d}.ppm").write_bytes(f"P6\n{width} {height}\n255\n".encode() + data)
