"""Store tests: validation, sidecar naming, round-trips, presets."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bglayout import store  # noqa: E402
from bglayout.store import LayoutError  # noqa: E402


def valid_layout(**kw):
    lay = {"version": 1, "image": "/x/00.jpg",
           "regions": [{"monitors": ["DP-1", "DP-2"], "mode": "fill",
                        "zoom": 1.0, "pan": [0.0, 0.0], "fallback": "hold"},
                       {"monitors": ["DP-3"], "mode": "center",
                        "zoom": 2.0, "pan": [0.25, -0.5]}]}
    lay.update(kw)
    return lay


class StoreCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._orig = (store.STORE_DIR, store.IMAGES_DIR, store.PRESETS_FILE)
        store.STORE_DIR = self._tmp.name
        store.IMAGES_DIR = os.path.join(self._tmp.name, "images")
        store.PRESETS_FILE = os.path.join(self._tmp.name, "presets.json")
        self.addCleanup(self._restore)

    def _restore(self):
        store.STORE_DIR, store.IMAGES_DIR, store.PRESETS_FILE = self._orig
        self._tmp.cleanup()


class TestValidation(StoreCase):
    def test_valid_passes(self):
        store.validate_layout(valid_layout())

    def test_overlapping_regions_rejected(self):
        lay = valid_layout()
        lay["regions"][1]["monitors"] = ["DP-2"]
        with self.assertRaisesRegex(LayoutError, "more than one region"):
            store.validate_layout(lay)

    def test_bad_zoom_rejected(self):
        for zoom in (0, -1, 0.01, 11):
            lay = valid_layout()
            lay["regions"][0]["zoom"] = zoom
            with self.assertRaisesRegex(LayoutError, "zoom"):
                store.validate_layout(lay)

    def test_unknown_mode_rejected(self):
        lay = valid_layout()
        lay["regions"][0]["mode"] = "cover"
        with self.assertRaisesRegex(LayoutError, "unknown mode"):
            store.validate_layout(lay)

    def test_pan_out_of_range_rejected(self):
        lay = valid_layout()
        lay["regions"][0]["pan"] = [2.0, 0]
        with self.assertRaisesRegex(LayoutError, "pan"):
            store.validate_layout(lay)

    def test_bad_letterbox_rejected(self):
        with self.assertRaisesRegex(LayoutError, "letterbox"):
            store.validate_layout(valid_layout(letterbox="red"))

    def test_bad_fallback_rejected(self):
        lay = valid_layout()
        lay["regions"][0]["fallback"] = "shrink"
        with self.assertRaisesRegex(LayoutError, "fallback"):
            store.validate_layout(lay)

    def test_empty_regions_rejected(self):
        with self.assertRaisesRegex(LayoutError, "regions"):
            store.validate_layout(valid_layout(regions=[]))


class ThemeKeyCase(StoreCase):
    """Fixture with a fake omarchy theme arrangement: a current/theme copy,
    a theme.name file, and a theme source dir."""

    def setUp(self):
        super().setUp()
        base = self._tmp.name
        self._orig_theme = (store.CURRENT_THEME_DIR, store.THEME_NAME_FILE,
                            store.THEME_SOURCE_DIRS)
        store.CURRENT_THEME_DIR = os.path.join(base, "current", "theme")
        store.THEME_NAME_FILE = os.path.join(base, "current", "theme.name")
        store.THEME_SOURCE_DIRS = (os.path.join(base, "themes"),)
        self.addCleanup(self._restore_theme)
        os.makedirs(os.path.join(store.CURRENT_THEME_DIR, "backgrounds"))
        self.current_img = os.path.join(store.CURRENT_THEME_DIR,
                                        "backgrounds", "00.jpg")
        open(self.current_img, "w").close()
        self.source_img = os.path.join(base, "themes", "alpha",
                                       "backgrounds", "00.jpg")
        os.makedirs(os.path.dirname(self.source_img))
        open(self.source_img, "w").close()
        self._set_theme("alpha")

    def _set_theme(self, name):
        with open(store.THEME_NAME_FILE, "w") as f:
            f.write(name + "\n")

    def _restore_theme(self):
        (store.CURRENT_THEME_DIR, store.THEME_NAME_FILE,
         store.THEME_SOURCE_DIRS) = self._orig_theme


class TestThemeAwareKeys(ThemeKeyCase):
    def test_same_path_different_theme_different_key(self):
        key_alpha = store.image_key(self.current_img)
        self._set_theme("beta")
        key_beta = store.image_key(self.current_img)
        self.assertNotEqual(key_alpha, key_beta)
        self.assertTrue(key_alpha.startswith("00.jpg."))

    def test_source_path_collapses_with_active_copy(self):
        # active theme is alpha: the copied path and alpha's source path are
        # the same image, one sidecar
        self.assertEqual(store.image_key(self.current_img),
                         store.image_key(self.source_img))
        # but not once another theme is active
        self._set_theme("beta")
        self.assertNotEqual(store.image_key(self.current_img),
                            store.image_key(self.source_img))
        # the source path's key is theme-pinned: unaffected by active theme
        self._set_theme("alpha")
        key_a = store.image_key(self.source_img)
        self._set_theme("beta")
        self.assertEqual(store.image_key(self.source_img), key_a)

    def test_layout_follows_theme(self):
        lay = valid_layout()
        store.save_layout(self.current_img, lay)
        self.assertIsNotNone(store.load_layout(self.current_img))
        self.assertIsNotNone(store.load_layout(self.source_img))
        self._set_theme("beta")
        self.assertIsNone(store.load_layout(self.current_img))
        self._set_theme("alpha")
        self.assertIsNotNone(store.load_layout(self.current_img))

    def test_missing_theme_name_falls_back_to_realpath(self):
        os.unlink(store.THEME_NAME_FILE)
        key = store.image_key(self.current_img)
        self.assertTrue(key.startswith("00.jpg."))
        # stable without a name file too
        self.assertEqual(key, store.image_key(self.current_img))


class TestSidecars(StoreCase):
    def test_symlink_collapses_to_one_sidecar(self):
        real_dir = os.path.join(self._tmp.name, "theme")
        os.makedirs(real_dir)
        img = os.path.join(real_dir, "00.jpg")
        open(img, "w").close()
        link_dir = os.path.join(self._tmp.name, "current")
        os.symlink(real_dir, link_dir)
        via_link = os.path.join(link_dir, "00.jpg")
        self.assertEqual(store.image_key(img), store.image_key(via_link))
        self.assertTrue(store.image_key(img).startswith("00.jpg."))

    def test_round_trip_preserves_unknown_keys(self):
        lay = valid_layout(my_custom_note="keep me")
        path = store.save_layout("/x/00.jpg", lay)
        self.assertTrue(os.path.isfile(path))
        loaded = store.load_layout("/x/00.jpg")
        self.assertEqual(loaded["my_custom_note"], "keep me")
        self.assertEqual(loaded["regions"], lay["regions"])

    def test_load_missing_returns_none(self):
        self.assertIsNone(store.load_layout("/nope/xx.jpg"))

    def test_malformed_sidecar_raises(self):
        os.makedirs(store.IMAGES_DIR)
        with open(store.sidecar_path("/x/00.jpg"), "w") as f:
            f.write("{not json")
        with self.assertRaisesRegex(LayoutError, "unreadable sidecar"):
            store.load_layout("/x/00.jpg")

    def test_save_rejects_invalid(self):
        with self.assertRaises(LayoutError):
            store.save_layout("/x/00.jpg", valid_layout(regions=[]))
        self.assertIsNone(store.load_layout("/x/00.jpg"))

    def test_delete(self):
        store.save_layout("/x/00.jpg", valid_layout())
        self.assertTrue(store.delete_layout("/x/00.jpg"))
        self.assertFalse(store.delete_layout("/x/00.jpg"))
        self.assertIsNone(store.load_layout("/x/00.jpg"))

    def test_list_sidecars_skips_invalid(self):
        store.save_layout("/x/00.jpg", valid_layout())
        with open(os.path.join(store.IMAGES_DIR, "junk.json"), "w") as f:
            f.write("[]")
        self.assertEqual(len(store.list_sidecars()), 1)


class TestPresets(StoreCase):
    def test_preset_round_trip_and_apply(self):
        store.save_preset("quad", valid_layout(letterbox="#101010"))
        data = store.load_presets()
        self.assertIn("quad", data["presets"])

        applied = store.apply_preset("quad", "/y/07.jpg")
        self.assertEqual(applied["regions"], valid_layout()["regions"])
        self.assertEqual(applied["letterbox"], "#101010")
        self.assertTrue(applied["image"].endswith("07.jpg"))
        # apply is a pure copy: mutating the applied layout must not touch
        # the stored preset
        applied["regions"][0]["zoom"] = 9.9
        self.assertEqual(
            store.load_presets()["presets"]["quad"]["regions"][0]["zoom"], 1.0)
        # and it persisted a sidecar for the new image
        self.assertIsNotNone(store.load_layout("/y/07.jpg"))

    def test_apply_unknown_preset_raises(self):
        with self.assertRaisesRegex(LayoutError, "no preset"):
            store.apply_preset("ghost", "/y/07.jpg")

    def test_empty_presets_file_default(self):
        self.assertEqual(store.load_presets()["presets"], {})


if __name__ == "__main__":
    unittest.main()
