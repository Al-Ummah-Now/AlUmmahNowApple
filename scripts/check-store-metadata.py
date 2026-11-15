#!/usr/bin/env python3
"""Checks the App Store files under store/apple (CI job "store"): scripts/check-store-metadata.py

- every app in store/apple/apps.json has en-US and ar-SA listings with the same files, none empty;
- App Store limits: name and subtitle 30 characters, keywords 100 bytes, promotional text 170, description and
  release notes 4000; URLs are https and in the listing's language;
- the copy tone (wiki guides/copy-tone.md): no lessons/lectures/courses/library or hype words, in either language;
- store/apple/app-privacy.json: every answer cites source files that exist in the repo.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STORE = ROOT / "store" / "apple"
LOCALES = ["en-US", "ar-SA"]
REQUIRED = ["name", "subtitle", "description", "keywords", "promotional_text", "release_notes",
            "privacy_url", "support_url", "marketing_url"]
CHAR_LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170, "description": 4000, "release_notes": 4000}
BYTE_LIMITS = {"keywords": 100}
BANNED_EN = re.compile(
    r"\b(lessons?|lectures?|courses?|library|beneficial knowledge|keep learning|learn|study|binge|blockbusters?|hits|stars|trusted)\b",
    re.IGNORECASE)
BANNED_AR = ["دروس", "درس", "محاضرات", "محاضرة", "مكتبة", "العلم النافع", "واصل التعلّم", "واصل التعلم"]
LANGUAGE_PATH = {"en-US": "/en", "ar-SA": "/ar"}


def check_listing(app: str, errors: list[str]) -> None:
    files = {}
    for locale in LOCALES:
        folder = STORE / app / "metadata" / locale
        if not folder.is_dir():
            errors.append(f"{app}: no {locale} listing ({folder.relative_to(ROOT)})")
            continue
        files[locale] = {p.stem: p.read_text(encoding="utf-8").strip() for p in folder.glob("*.txt")}
    if len(files) != len(LOCALES):
        return
    names = [set(files[locale]) for locale in LOCALES]
    if names[0] != names[1]:
        errors.append(f"{app}: en-US and ar-SA differ: {sorted(names[0] ^ names[1])}")
    for locale, fields in files.items():
        where = f"{app}/{locale}"
        for field in REQUIRED:
            if not fields.get(field):
                errors.append(f"{where}: {field}.txt is missing or empty")
        for field, limit in CHAR_LIMITS.items():
            if len(fields.get(field, "")) > limit:
                errors.append(f"{where}: {field} is {len(fields[field])} characters (limit {limit})")
        for field, limit in BYTE_LIMITS.items():
            size = len(fields.get(field, "").encode("utf-8"))
            if size > limit:
                errors.append(f"{where}: {field} is {size} bytes (limit {limit})")
        keywords = [k.strip() for k in fields.get("keywords", "").split(",")]
        if any(not k for k in keywords) or len(set(keywords)) != len(keywords):
            errors.append(f"{where}: keywords must be distinct and comma-separated without empty entries")
        for field in ("privacy_url", "support_url", "marketing_url"):
            url = fields.get(field, "")
            if not url.startswith("https://"):
                errors.append(f"{where}: {field} must be https ({url})")
            elif LANGUAGE_PATH[locale] not in url:
                errors.append(f"{where}: {field} should open the {locale} page ({url})")
        text = "\n".join(v for k, v in fields.items() if not k.endswith("_url"))
        for match in BANNED_EN.finditer(text):
            errors.append(f"{where}: copy tone: '{match.group(0)}' (wiki guides/copy-tone.md)")
        for word in BANNED_AR:
            if word in text:
                errors.append(f"{where}: copy tone: «{word}» (wiki guides/copy-tone.md)")


def check_privacy(errors: list[str]) -> None:
    path = STORE / "app-privacy.json"
    if not path.is_file():
        errors.append("store/apple/app-privacy.json is missing")
        return
    privacy = json.loads(path.read_text(encoding="utf-8"))
    apps = {a["dir"] for a in json.loads((STORE / "apps.json").read_text())["apps"]}
    listed = set(privacy.get("apps", {}))
    if not apps <= listed:
        errors.append(f"app-privacy.json: no answers for {sorted(apps - listed)}")
    for app, answers in privacy.get("apps", {}).items():
        if answers.get("tracking") is not False:
            errors.append(f"app-privacy.json/{app}: tracking must be false unless the code tracks")
        for entry in answers.get("collected", []):
            for key in ("dataType", "linkedToUser", "usedForTracking", "purposes", "sources"):
                if key not in entry:
                    errors.append(f"app-privacy.json/{app}/{entry.get('dataType', '?')}: no {key}")
            for source in entry.get("sources", []):
                if not (ROOT / source).exists():
                    errors.append(f"app-privacy.json/{app}: source {source} does not exist")
        for entry in answers.get("notCollected", []):
            for source in entry.get("sources", []):
                if not (ROOT / source).exists():
                    errors.append(f"app-privacy.json/{app}: source {source} does not exist")


def main() -> int:
    errors: list[str] = []
    apps = json.loads((STORE / "apps.json").read_text())["apps"]
    for app in apps:
        check_listing(app["dir"], errors)
    check_privacy(errors)
    for error in errors:
        print(f"::error::{error}")
    if not errors:
        print(f"store listings OK: {len(apps)} apps × {len(LOCALES)} languages, App Privacy answers cite existing files")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
