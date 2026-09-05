"""Tests for the align picker's slot parsing and preview rows."""

import importlib.util
import os
import sys
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SCRIPTS)
_spec = importlib.util.spec_from_file_location(
    "wsalign", os.path.join(SCRIPTS, "workspace-align.py"))
wa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wa)

# Four panels, one decade each, exactly what `workspace-map.sh preview` prints.
ROWS = [("HDMI-A-1", 1), ("DP-3", 11), ("DP-1", 21), ("DP-2", 31)]
ACTIVE = {"HDMI-A-1": 3, "DP-3": 11, "DP-1": 25, "DP-2": 32}


class TestParseSlot(unittest.TestCase):
    def test_plain_digits(self):
        self.assertEqual(wa.parse_slot("3", 10), 3)
        self.assertEqual(wa.parse_slot("10", 10), 10)

    def test_zero_is_the_last_slot(self):
        self.assertEqual(wa.parse_slot("0", 10), 10)
        self.assertEqual(wa.parse_slot("0", 6), 6)

    def test_nothing_typed_yet(self):
        for text in ("", "   "):
            self.assertIsNone(wa.parse_slot(text, 10))

    def test_out_of_range_and_junk(self):
        for text in ("11", "99", "x", "3x", "-2", "1.5"):
            self.assertIsNone(wa.parse_slot(text, 10), text)

    def test_range_follows_the_decade_size(self):
        self.assertEqual(wa.parse_slot("6", 6), 6)
        self.assertIsNone(wa.parse_slot("7", 6))


class TestSlotInUse(unittest.TestCase):
    def test_position_of_the_focused_workspace(self):
        self.assertEqual(wa.slot_in_use(ACTIVE, "HDMI-A-1", ROWS, 10), 3)
        self.assertEqual(wa.slot_in_use(ACTIVE, "DP-1", ROWS, 10), 5)
        self.assertEqual(wa.slot_in_use(ACTIVE, "DP-2", ROWS, 10), 2)

    def test_tenth_workspace_of_a_decade(self):
        self.assertEqual(wa.slot_in_use({"DP-2": 40}, "DP-2", ROWS, 10), 10)

    def test_outside_the_scheme_falls_back_to_one(self):
        for ws in (-99, 0, 41, None):
            self.assertEqual(wa.slot_in_use({"DP-2": ws}, "DP-2", ROWS, 10), 1)

    def test_unknown_monitor(self):
        self.assertEqual(wa.slot_in_use(ACTIVE, "nope", ROWS, 10), 1)


class TestPreviewRows(unittest.TestCase):
    def test_targets_follow_each_display_own_decade(self):
        self.assertEqual(
            wa.preview_rows(ROWS, ACTIVE, 3, 10),
            [("HDMI-A-1", 3, 3), ("DP-3", 11, 13),
             ("DP-1", 25, 23), ("DP-2", 32, 33)])

    def test_last_slot(self):
        self.assertEqual([t for _, _, t in wa.preview_rows(ROWS, ACTIVE, 10, 10)],
                         [10, 20, 30, 40])

    def test_display_without_a_decade_is_left_alone(self):
        rows = ROWS + [("DP-5", None)]
        out = wa.preview_rows(rows, dict(ACTIVE, **{"DP-5": 7}), 3, 10)
        self.assertEqual(out[-1], ("DP-5", 7, None))

    def test_unknown_current_workspace_is_not_invented(self):
        out = wa.preview_rows(ROWS, {}, 1, 10)
        self.assertEqual(out[0], ("HDMI-A-1", None, 1))

    def test_row_order_is_the_layout_order(self):
        self.assertEqual([n for n, _, _ in wa.preview_rows(ROWS, ACTIVE, 1, 10)],
                         ["HDMI-A-1", "DP-3", "DP-1", "DP-2"])


if __name__ == "__main__":
    unittest.main()
