#!/usr/bin/env python3
"""Files exported XCUITest attachments into fastlane deliver's screenshot layout (called by scripts/screenshots.sh).

    file-screenshots.py <exported-attachments-dir> <out-app-dir> <iphone|ipad|tv|mac>

Attachments named store_<en|ar>_<theme>_<NN>_<screen> become <out>/<en-US|ar-SA>/<device>-<NN>-<screen>-<theme>.png.
Each image must have an App Store size for its device; Mac windows are scaled and centred on a 2880×1800 canvas.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys

LOCALES = {"en": "en-US", "ar": "ar-SA"}
SIZES = {
    "iphone": {(1320, 2868), (1290, 2796)},
    "ipad": {(2064, 2752), (2048, 2732)},
    "tv": {(1920, 1080), (3840, 2160)},
    "mac": {(2880, 1800)},
}
MAC = (2880, 1800)
NAME = re.compile(r"store_(en|ar)_(dark|light)_(\d\d)_([a-z-]+)")


def size(path: pathlib.Path) -> tuple[int, int]:
    out = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], text=True)
    width = int(re.search(r"pixelWidth: (\d+)", out).group(1))
    height = int(re.search(r"pixelHeight: (\d+)", out).group(1))
    return width, height


def fit_mac(path: pathlib.Path, theme: str) -> None:
    width, height = size(path)
    scale = min(MAC[0] / width, MAC[1] / height)
    new_w, new_h = int(width * scale), int(height * scale)
    subprocess.check_call(["sips", "--resampleHeightWidth", str(new_h), str(new_w), str(path)], stdout=subprocess.DEVNULL)
    pad = "0B0D10" if theme == "dark" else "F7F7F5"
    subprocess.check_call(
        ["sips", "--padToHeightWidth", str(MAC[1]), str(MAC[0]), "--padColor", pad, str(path)], stdout=subprocess.DEVNULL
    )


def attachments(manifest: object):
    """(exported file, human name) pairs, wherever the manifest nests them."""
    if isinstance(manifest, dict):
        if "exportedFileName" in manifest:
            yield manifest["exportedFileName"], manifest.get("suggestedHumanReadableName", "")
        for value in manifest.values():
            yield from attachments(value)
    elif isinstance(manifest, list):
        for value in manifest:
            yield from attachments(value)


def main() -> int:
    source, out, device = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
    manifest = json.loads((source / "manifest.json").read_text())
    filed = 0
    errors = []
    for exported, human in attachments(manifest):
        match = NAME.search(human) or NAME.search(exported)
        if not match:
            continue
        language, theme, index, screen = match.groups()
        target = out / LOCALES[language] / f"{device}-{index}-{screen}-{theme}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / exported, target)
        if device == "mac":
            fit_mac(target, theme)
        got = size(target)
        if got not in SIZES[device]:
            errors.append(f"{target}: {got[0]}×{got[1]} is not an App Store size for {device}")
        filed += 1
    for error in errors:
        print(f"::error::{error}")
    if filed == 0:
        print(f"::error::no store screenshots in {source}")
        return 1
    print(f"filed {filed} {device} screenshots into {out}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
