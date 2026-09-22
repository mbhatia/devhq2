#!/usr/bin/env python3
"""Generate deterministic terminal throughput fixtures outside version control."""

from __future__ import annotations

import argparse
from pathlib import Path

MEBIBYTE = 1024 * 1024
SIZE = 150 * MEBIBYTE


def write_repeated(path: Path, pattern: bytes) -> None:
    if SIZE % len(pattern) != 0:
        raise ValueError("fixture size must be an exact number of patterns")
    block = pattern * (MEBIBYTE // len(pattern))
    remaining = SIZE
    with path.open("wb") as output:
        while remaining >= len(block):
            output.write(block)
            remaining -= len(block)
        if remaining:
            output.write(pattern * (remaining // len(pattern)))
    if path.stat().st_size != SIZE:
        raise RuntimeError(f"wrote an unexpected size for {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(".build/terminal-benchmarks"))
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)

    # Both patterns divide 150 MiB exactly. The Unicode pattern is valid UTF-8
    # with Latin, Greek, Cyrillic, Arabic, Devanagari, CJK, Hangul, emoji, and
    # a combining acute accent. Repeating only a narrow character subset would
    # make this a poor mixed-language terminal fixture.
    fixtures = {
        "ascii-150MiB.txt": b"A",
        "unicode-150MiB.txt": "AéΩЖعन中한🙂e\u0301".encode("utf-8"),
    }
    for name, pattern in fixtures.items():
        path = arguments.output / name
        write_repeated(path, pattern)
        print(f"{path}: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
