#!/usr/bin/env python3
"""Negative cases for scripts/check-store-metadata.py (CI job "store"): age rating answers, privacy manifests, reserved words."""
import copy
import importlib.util
import json
import pathlib
import plistlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_store_metadata", HERE / "check-store-metadata.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
GOOD = json.loads((check.STORE / "age-rating.json").read_text(encoding="utf-8"))


class AgeRating(unittest.TestCase):
    def problems(self, change):
        ratings = copy.deepcopy(GOOD)
        change(ratings)
        errors: list[str] = []
        check.check_age_rating(errors, ratings)
        return errors

    def only(self, change, text):
        errors = self.problems(change)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(text, errors[0])

    def test_the_committed_answers_pass(self):
        self.assertEqual(self.problems(lambda r: None), [])

    def test_a_missing_or_unknown_question(self):
        self.only(lambda r: r["apps"]["viewer-ios"]["capabilities"].pop("sharedLocation"), "capabilities.sharedLocation is missing")
        self.only(lambda r: r["apps"]["viewer-ios"]["content"].update(extra="none"), "content.extra is not a question")

    def test_invalid_answers(self):
        self.only(lambda r: r["apps"]["viewer-tv"]["content"].update(realisticViolence="sometimes"), "invalid answer")
        self.only(lambda r: r["apps"]["viewer-tv"]["capabilities"].update(advertising="no"), "invalid answer")
        self.only(lambda r: r["apps"]["studio-ios"].update(rating="12+"), "rating must be one of")
        self.only(lambda r: r["apps"]["studio-ios"].update(overrideTo="12+"), "overrideTo must be")

    def test_disabled_under_13_needs_social_media(self):
        self.only(lambda r: r["apps"]["viewer-tv"]["capabilities"].update(socialMediaDisabledUnder13=True), "needs socialMedia")

    def test_every_app_is_covered_and_sources_exist(self):
        self.only(lambda r: r["apps"].pop("viewer-mac"), "no answers for viewer-mac")
        self.only(lambda r: r["apps"]["viewer-mac"].update(sources=["Apps/Gone.swift"]), "Apps/Gone.swift does not exist")
        self.only(lambda r: r["notInStore"].update(watch="no"), "watch is not in apps.json")


class PrivacyManifests(unittest.TestCase):
    def manifests(self):
        return {t: plistlib.loads((check.ROOT / "Apps" / t / "PrivacyInfo.xcprivacy").read_bytes()) for t in check.APP_TARGETS}

    def problems(self, change):
        manifests = self.manifests()
        change(manifests)
        errors: list[str] = []
        check.check_privacy_manifests(errors, manifests)
        return errors

    def only(self, change, text):
        errors = self.problems(change)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(text, errors[0])

    def test_the_committed_manifests_pass(self):
        self.assertEqual(self.problems(lambda m: None), [])

    def test_a_missing_manifest(self):
        self.only(lambda m: m.pop("ViewerTV"), "ViewerTV/PrivacyInfo.xcprivacy is missing")

    def test_tracking(self):
        self.only(lambda m: m["ViewerIOS"].update(NSPrivacyTracking=True), "tracking must be false")

    def test_required_reasons(self):
        self.only(lambda m: m["ViewerMac"].update(NSPrivacyAccessedAPITypes=[]), "no CA92.1 reason")
        self.only(lambda m: m["StudioMac"]["NSPrivacyAccessedAPITypes"].pop(), "no 35F9.1 reason")
        self.only(lambda m: m["AdminIOS"]["NSPrivacyAccessedAPITypes"].pop(1), "no C617.1 reason")

    def test_collected_types_match_app_privacy(self):
        self.only(lambda m: m["StudioIOS"]["NSPrivacyCollectedDataTypes"].pop(), "differ from app-privacy.json/studio-ios")
        extra = {"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeSearchHistory", "NSPrivacyCollectedDataTypeTracking": False,
                 "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}
        self.only(lambda m: m["ViewerIOS"]["NSPrivacyCollectedDataTypes"].append(extra), "differ from app-privacy.json/viewer-ios")

    def test_linked_tracking_and_purposes_match_app_privacy(self):
        first = lambda m: m["StudioIOS"]["NSPrivacyCollectedDataTypes"][0]
        self.only(lambda m: first(m).update(NSPrivacyCollectedDataTypeLinked=False), "linked is False, app-privacy.json/studio-ios says True")
        self.only(lambda m: first(m).update(NSPrivacyCollectedDataTypePurposes=["NSPrivacyCollectedDataTypePurposeAnalytics"]),
                  "purposes")
        self.only(lambda m: first(m)["NSPrivacyCollectedDataTypePurposes"].append("NSPrivacyCollectedDataTypePurposeAnalytics"),
                  "purposes")
        errors = self.problems(lambda m: first(m).update(NSPrivacyCollectedDataTypeTracking=True))
        self.assertTrue(any("must not be used for tracking" in e for e in errors), errors)
        self.assertTrue(any("tracking is True, app-privacy.json/studio-ios says False" in e for e in errors), errors)

    def test_unprefixed_keys_and_duplicates_are_refused(self):
        errors = self.problems(lambda m: m["ViewerIOS"]["NSPrivacyAccessedAPITypes"][0].update(NSPrivacyAccessedAPIType="UserDefaults"))
        self.assertEqual(len(errors), 2, errors)
        self.assertIn("lacks the NSPrivacyAccessedAPICategory prefix", errors[0])
        self.assertIn("no CA92.1 reason", errors[1])
        # On Admin (no App Store record) only the prefix error shows; on Studio the type also goes missing from the answers.
        self.only(lambda m: m["AdminIOS"]["NSPrivacyCollectedDataTypes"][0].update(NSPrivacyCollectedDataType="EmailAddress"),
                  "lacks the NSPrivacyCollectedDataType prefix")
        self.only(lambda m: m["ViewerTV"]["NSPrivacyAccessedAPITypes"].append(dict(m["ViewerTV"]["NSPrivacyAccessedAPITypes"][0])),
                  "NSPrivacyAccessedAPICategoryUserDefaults is listed twice")
        self.only(lambda m: m["AdminMac"]["NSPrivacyCollectedDataTypes"].append(dict(m["AdminMac"]["NSPrivacyCollectedDataTypes"][0])),
                  "is listed twice")


class ReservedWords(unittest.TestCase):
    def test_kids_category_words(self):
        for text in ("Videos for kids", "FOR  CHILDREN and parents"):
            self.assertTrue(check.RESERVED_EN.search(text), text)
        for text in ("مرئيات للأطفال", "برامج لأطفال", "وللأطفال", "للصغار"):
            self.assertTrue(check.RESERVED_AR.search(text), text)
        for text in ("Watch videos", "children's hospital news", "Forkids"):
            self.assertFalse(check.RESERVED_EN.search(text), text)
        for text in ("شاهد المرئيات", "أخبار الأطفال", "والأطفال"):
            self.assertFalse(check.RESERVED_AR.search(text), text)


if __name__ == "__main__":
    unittest.main()
