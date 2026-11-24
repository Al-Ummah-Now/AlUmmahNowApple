#!/usr/bin/env python3
"""Checks the App Store files under store/apple (CI job "store"): scripts/check-store-metadata.py

- every app in store/apple/apps.json has en-US and ar-SA listings with the same files, none empty;
- App Store limits: name and subtitle 30 characters, keywords 100 bytes, promotional text 170, description and
  release notes 4000; URLs are https and in the listing's language;
- the copy tone (wiki guides/copy-tone.md): no lessons/lectures/courses/library or hype words, in either language;
- no "for kids" / "for children" in either language: Apple reserves them for the Kids category (guideline 2.3.8);
- store/apple/app-privacy.json: every answer cites source files that exist in the repo;
- store/apple/age-rating.json: every question answered for every App Store record, cited files exist (wiki E20 §3.1);
- Apps/<target>/PrivacyInfo.xcprivacy: every app has a privacy manifest, no tracking, a reason for UserDefaults (and for
  the file timestamp and boot time APIs in the apps that link aun-core), and the collected data types match
  app-privacy.json.
"""
import json
import pathlib
import plistlib
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
RESERVED_EN = re.compile(r"\bfor\s+(kids|children)\b", re.IGNORECASE)
# «للأطفال» / «لأطفال», also after «و» or «ف»; not «الأطفال» (children)
RESERVED_AR = re.compile(r"(?<![\u0621-\u064A])[وف]?لل?(أطفال|اطفال|صغار)")
FREQUENCIES = {"none", "infrequent", "frequent"}
RATINGS = {"4+", "9+", "13+", "16+", "18+"}
LANGUAGE_PATH = {"en-US": "/en", "ar-SA": "/ar"}
# Every app target, its App Store record in apps.json (None: TestFlight internal only), and whether it links aun-core
# (AUNCoreKit), whose Rust code reads file metadata (stat) and a monotonic clock.
APP_TARGETS = {
    "ViewerIOS": ("viewer-ios", False), "ViewerTV": ("viewer-tv", False), "ViewerMac": ("viewer-mac", False),
    "StudioIOS": ("studio-ios", True), "StudioMac": ("studio-mac", True),
    "AdminIOS": (None, True), "AdminMac": (None, True),
}
# Required-reason API categories (developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
API_REASONS = {"UserDefaults": "CA92.1", "FileTimestamp": "C617.1", "SystemBootTime": "35F9.1"}
# App Store Connect data type (app-privacy.json) → privacy manifest key
DATA_TYPES = {
    "Email Address": "EmailAddress", "Name": "Name", "User ID": "UserID", "Device ID": "DeviceID",
    "Photos or Videos": "PhotosorVideos", "Other User Content": "OtherUserContent", "Other Usage Data": "OtherUsageData",
}
# App Store Connect purpose (app-privacy.json) → manifest purpose key, after PURPOSE_PREFIX
PURPOSES = {
    "App Functionality": "AppFunctionality", "Analytics": "Analytics", "Product Personalization": "ProductPersonalization",
    "Developer's Advertising or Marketing": "DevelopersAdvertising", "Third-Party Advertising": "ThirdPartyAdvertising",
    "Other Purposes": "Other",
}
API_PREFIX = "NSPrivacyAccessedAPICategory"
TYPE_PREFIX = "NSPrivacyCollectedDataType"
PURPOSE_PREFIX = "NSPrivacyCollectedDataTypePurpose"


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
        for reserved in (RESERVED_EN, RESERVED_AR):
            for match in reserved.finditer(text):
                errors.append(f"{where}: '{match.group(0)}' is reserved for the Kids category (guideline 2.3.8)")


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


def check_age_rating(errors: list[str], ratings: dict | None = None) -> None:
    if ratings is None:
        path = STORE / "age-rating.json"
        if not path.is_file():
            errors.append("store/apple/age-rating.json is missing")
            return
        ratings = json.loads(path.read_text(encoding="utf-8"))
    apps = {a["dir"] for a in json.loads((STORE / "apps.json").read_text())["apps"]}
    answered, outside = set(ratings.get("apps", {})), set(ratings.get("notInStore", {}))
    for app in sorted(apps - answered - outside):
        errors.append(f"age-rating.json: no answers for {app} (or a reason in notInStore)")
    for app in sorted((answered | outside) - apps):
        errors.append(f"age-rating.json: {app} is not in apps.json")
    for app, answers in ratings.get("apps", {}).items():
        where = f"age-rating.json/{app}"
        for group, questions in ratings["questions"].items():
            given = answers.get(group, {})
            for question in sorted(set(questions) ^ set(given)):
                errors.append(f"{where}: {group}.{question} is {'missing' if question in questions else 'not a question'}")
            for question, value in given.items():
                valid = value in FREQUENCIES if group == "content" else isinstance(value, bool)
                if not valid:
                    errors.append(f"{where}: {group}.{question} has an invalid answer ({value!r})")
        if answers.get("rating") not in RATINGS:
            errors.append(f"{where}: rating must be one of {sorted(RATINGS)}")
        if answers.get("overrideTo") not in RATINGS | {None}:
            errors.append(f"{where}: overrideTo must be a rating or null")
        if answers.get("capabilities", {}).get("socialMediaDisabledUnder13") and not answers["capabilities"].get("socialMedia"):
            errors.append(f"{where}: socialMediaDisabledUnder13 needs socialMedia")
        if not answers.get("primaryCategory"):
            errors.append(f"{where}: no primaryCategory")
        if not answers.get("sources"):
            errors.append(f"{where}: no sources")
        for source in answers.get("sources", []):
            if not (ROOT / source).exists():
                errors.append(f"{where}: source {source} does not exist")


def check_privacy_manifests(errors: list[str], manifests: dict | None = None) -> None:
    privacy = json.loads((STORE / "app-privacy.json").read_text(encoding="utf-8")).get("apps", {})
    for target, (store_dir, links_core) in APP_TARGETS.items():
        where = f"Apps/{target}/PrivacyInfo.xcprivacy"
        if manifests is not None:
            manifest = manifests.get(target)
        else:
            path = ROOT / where
            manifest = plistlib.loads(path.read_bytes()) if path.is_file() else None
        if manifest is None:
            errors.append(f"{where} is missing (App Store uploads need a privacy manifest)")
            continue
        if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains"):
            errors.append(f"{where}: tracking must be false with no tracking domains unless the code tracks")
        reasons: dict[str, list[str]] = {}
        for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
            key = entry.get("NSPrivacyAccessedAPIType", "")
            if not key.startswith(API_PREFIX):
                errors.append(f"{where}: API type {key!r} lacks the {API_PREFIX} prefix")
                continue
            api = key.removeprefix(API_PREFIX)
            if api in reasons:
                errors.append(f"{where}: {key} is listed twice (put all its reasons in one entry)")
                continue
            reasons[api] = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        needed = ["UserDefaults"] + (["FileTimestamp", "SystemBootTime"] if links_core else [])
        for api in needed:
            if API_REASONS[api] not in reasons.get(api, []):
                errors.append(f"{where}: no {API_REASONS[api]} reason for the {api} API")
        declared: dict[str, tuple] = {}
        for entry in manifest.get("NSPrivacyCollectedDataTypes", []):
            key = entry.get("NSPrivacyCollectedDataType", "")
            if not key.startswith(TYPE_PREFIX):
                errors.append(f"{where}: data type {key!r} lacks the {TYPE_PREFIX} prefix")
                continue
            name = key.removeprefix(TYPE_PREFIX)
            if name in declared:
                errors.append(f"{where}: {key} is listed twice")
                continue
            purposes = entry.get("NSPrivacyCollectedDataTypePurposes", [])
            if not purposes:
                errors.append(f"{where}: {name} has no purpose")
            if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
                errors.append(f"{where}: {name} must not be used for tracking")
            declared[name] = (entry.get("NSPrivacyCollectedDataTypeLinked"), entry.get("NSPrivacyCollectedDataTypeTracking"),
                              sorted(purposes))
        if store_dir is None:
            continue
        expected: dict[str, tuple] = {}
        for answer in privacy.get(store_dir, {}).get("collected", []):
            purposes = sorted(PURPOSE_PREFIX + PURPOSES.get(x, x) for x in answer.get("purposes", []))
            expected[DATA_TYPES.get(answer["dataType"], answer["dataType"])] = (
                answer.get("linkedToUser"), answer.get("usedForTracking"), purposes)
        if sorted(declared) != sorted(expected):
            errors.append(f"{where}: collected data types {sorted(declared)} differ from app-privacy.json/{store_dir} {sorted(expected)}")
            continue
        for name, (linked, tracking, purposes) in declared.items():
            want_linked, want_tracking, want_purposes = expected[name]
            if linked is not want_linked:
                errors.append(f"{where}: {name} linked is {linked!r}, app-privacy.json/{store_dir} says {want_linked!r}")
            if tracking is not want_tracking:
                errors.append(f"{where}: {name} tracking is {tracking!r}, app-privacy.json/{store_dir} says {want_tracking!r}")
            if purposes != want_purposes:
                errors.append(f"{where}: {name} purposes {purposes} differ from app-privacy.json/{store_dir} {want_purposes}")


def main() -> int:
    errors: list[str] = []
    apps = json.loads((STORE / "apps.json").read_text())["apps"]
    for app in apps:
        check_listing(app["dir"], errors)
    check_privacy(errors)
    check_age_rating(errors)
    check_privacy_manifests(errors)
    for error in errors:
        print(f"::error::{error}")
    if not errors:
        print(f"store listings OK: {len(apps)} apps × {len(LOCALES)} languages, App Privacy and age rating answers cite existing files, privacy manifests match")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
