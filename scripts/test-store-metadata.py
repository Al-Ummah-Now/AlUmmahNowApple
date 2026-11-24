#!/usr/bin/env python3
"""Negative cases for scripts/check-store-metadata.py (CI job "store"): the age rating answers and reserved words."""
import copy
import importlib.util
import json
import pathlib
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
