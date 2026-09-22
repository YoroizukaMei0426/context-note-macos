#!/usr/bin/env python3
"""Pack the generated PNG sizes into a modern macOS ICNS container."""

from pathlib import Path
import struct
import sys


source = Path(sys.argv[1])
destination = Path(sys.argv[2])
entries = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
]

chunks = []
for kind, filename in entries:
    payload = (source / filename).read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload)

body = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
