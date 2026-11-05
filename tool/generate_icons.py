"""Generate launcher icons from assets/branding/openlauf.svg.

Run from any directory: python3 tool/generate_icons.py
Requires rsvg-convert (librsvg) and Pillow.
"""

import io
import json
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/branding/openlauf.svg"
ANDROID = ROOT / "android/app/src/main/res"
IOS = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
SVG = "{http://www.w3.org/2000/svg}"


def render(target, size):
    png = subprocess.run(
        ["rsvg-convert", "--width", str(size), "--height", str(size), str(SOURCE)],
        check=True,
        capture_output=True,
    ).stdout
    target.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(io.BytesIO(png)) as image:
        # App Store icons must be opaque and carry no alpha channel.
        image.convert("RGB").save(target)


def write_vector(target, paths):
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp" android:height="108dp"\n'
        '    android:viewportWidth="108" android:viewportHeight="108">\n'
        + "".join(paths)
        + "</vector>\n"
    )


def main():
    if not shutil.which("rsvg-convert"):
        raise SystemExit("rsvg-convert is required (install librsvg).")
    source = ET.parse(SOURCE).getroot()
    background = source.find(f"{SVG}rect[@id='background']").attrib["fill"]
    paths = source.find(f"{SVG}g[@id='mark']").findall(f"{SVG}path")
    write_vector(
        ANDROID / "drawable/ic_openlauf.xml",
        [
            f'    <path android:fillColor="{path.attrib["fill"]}" '
            f'android:pathData="{path.attrib["d"]}" />\n'
            for path in paths
        ],
    )
    # The wave is a cutout in the monochrome silhouette. Coordinates remain in
    # Android's 108dp viewport so the complete mark fits its 66dp safe circle.
    monochrome = " ".join(path.attrib["d"] for path in paths)
    write_vector(
        ANDROID / "drawable/ic_openlauf_monochrome.xml",
        [
            '    <path android:fillColor="#FFFFFF" android:fillType="evenOdd" '
            f'android:pathData="{monochrome}" />\n'
        ],
    )
    colors = ANDROID / "values/colors.xml"
    color_tree = ET.parse(colors)
    color = color_tree.getroot().find("color[@name='openlauf_background']")
    if color is None:
        raise SystemExit("Missing openlauf_background color resource.")
    color.text = background
    ET.indent(color_tree, space="    ")
    color_tree.write(colors, encoding="unicode")

    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                          "xxhdpi": 144, "xxxhdpi": 192}.items():
        render(ANDROID / f"mipmap-{density}/ic_launcher.png", size)

    contents = json.loads((IOS / "Contents.json").read_text())
    rendered = set()
    for entry in contents["images"]:
        filename = entry["filename"]
        if filename in rendered:
            continue
        size = float(entry["size"].split("x")[0])
        scale = float(entry["scale"].removesuffix("x"))
        render(IOS / filename, round(size * scale))
        rendered.add(filename)

    render(ROOT / "assets/branding/openlauf.png", 512)
    print(f"Generated Android icons, {len(rendered)} iOS icons and a preview.")


if __name__ == "__main__":
    main()
