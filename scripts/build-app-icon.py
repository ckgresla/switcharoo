#!/usr/bin/env python3
"""Regenerate the macOS icon from kangaroo.svg (requires librsvg and iconutil)."""
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
resources = root / "Resources"
logo = ET.parse(resources / "kangaroo.svg").getroot()
logo.set("x", "100")
logo.set("y", "100")
logo.set("width", "824")
logo.set("height", "824")
ET.register_namespace("", "http://www.w3.org/2000/svg")
svg = ET.Element("{http://www.w3.org/2000/svg}svg", {
    "viewBox": "0 0 1024 1024", "width": "1024", "height": "1024", "color": "#171717"
})
ET.SubElement(svg, "{http://www.w3.org/2000/svg}rect", {
    "x": "100", "y": "100", "width": "824", "height": "824", "rx": "185", "fill": "#ffffff"
})
svg.append(logo)
with tempfile.TemporaryDirectory(prefix="switcharoo-icon-") as temp:
    folder = Path(temp)
    source = folder / "app-icon.svg"
    ET.ElementTree(svg).write(source, encoding="unicode")
    iconset = folder / "AppIcon.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            target = iconset / f"icon_{points}x{points}{suffix}.png"
            subprocess.run(["rsvg-convert", "-w", str(pixels), "-h", str(pixels), "-o", str(target), str(source)], check=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns")], check=True)
    (resources / "AppIcon.png").write_bytes((iconset / "icon_512x512@2x.png").read_bytes())
