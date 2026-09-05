"""Tests for bg_picker_state: parsing, group invariants, pan/zoom/snap
transitions, serialization round-trips."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import bg_picker_state as st  # noqa: E402
from bglayout.geometry import region_scales  # noqa: E402

REAL_QUERY = """\
: DP-3: 2048x1152, scale: 1.25, currently displaying: image: /home/tla/.config/omarchy/current/theme/backgrounds/11.png
: DP-1: 2048x1152, scale: 1.25, currently displaying: image: /home/tla/.config/omarchy/current/theme/backgrounds/06.jpg
: DP-2: 2048x1152, scale: 1.25, currently displaying: image: /home/tla/.config/omarchy/current/theme/backgrounds/02.jpg
: HDMI-A-1: 2048x1152, scale: 1.25, currently displaying: image: /home/tla/.config/omarchy/current/theme/backgrounds/03.jpg
"""

LIVE = ["DP-1", "DP-2", "DP-3", "HDMI-A-1"]


def region(monitors, mode="fill", zoom=1.0, pan=(0.0, 0.0), fallback="fill"):
    return {"monitors": list(monitors), "mode": mode, "zoom": zoom,
            "pan": list(pan), "fallback": fallback}


class TestParseQuery(unittest.TestCase):
    def test_real_output(self):
        parsed = st.parse_awww_query(REAL_QUERY)
        self.assertEqual(len(parsed), 4)
        self.assertEqual(
            parsed["DP-2"],
            "/home/tla/.config/omarchy/current/theme/backgrounds/02.jpg")

    def test_path_with_spaces_and_junk_lines(self):
        text = (": DP-1: 2048x1152, scale: 1.25, currently displaying: "
                "image: /home/x/my wallpapers/cool image.png\n"
                "some unrelated line\n")
        self.assertEqual(st.parse_awww_query(text),
                         {"DP-1": "/home/x/my wallpapers/cool image.png"})

    def test_empty(self):
        self.assertEqual(st.parse_awww_query(""), {})


class TestGroups(unittest.TestCase):
    def test_materialize_none_layout(self):
        groups = st.layout_groups_for(None, LIVE)
        self.assertEqual(len(groups), 4)
        for g in groups:
            self.assertEqual(len(g["monitors"]), 1)
            self.assertTrue(st.is_default_region(g["region"]))

    def test_materialize_with_span_and_stale_names(self):
        layout = {"regions": [region(["DP-1", "DP-2"], zoom=1.2),
                              region(["GHOST-1", "DP-3"], zoom=2.0)]}
        groups = st.layout_groups_for(layout, LIVE)
        by_size = sorted(groups, key=lambda g: -len(g["monitors"]))
        self.assertEqual(by_size[0]["monitors"], {"DP-1", "DP-2"})
        self.assertEqual(by_size[0]["region"]["zoom"], 1.2)
        # partially-present region falls back to implicit solos
        dp3 = st.group_of(groups, "DP-3")
        self.assertEqual(dp3["monitors"], {"DP-3"})
        self.assertTrue(st.is_default_region(dp3["region"]))
        # every live monitor in exactly one group
        all_mons = [m for g in groups for m in g["monitors"]]
        self.assertEqual(sorted(all_mons), sorted(LIVE))

    def test_serialize_round_trip(self):
        layout = {"regions": [region(["DP-1", "DP-2"], mode="fit", zoom=1.3,
                                     pan=(0.1, -0.2), fallback="hold"),
                              region(["DP-3"], zoom=2.0)]}
        groups = st.layout_groups_for(layout, LIVE)
        out = st.serialize_layout("/x/00.jpg", groups)
        self.assertEqual(len(out["regions"]), 2)  # HDMI implicit solo dropped
        by_mons = {tuple(r["monitors"]): r for r in out["regions"]}
        span = by_mons[("DP-1", "DP-2")]
        self.assertEqual((span["mode"], span["zoom"], span["pan"],
                          span["fallback"]),
                         ("fit", 1.3, [0.1, -0.2], "hold"))
        self.assertEqual(by_mons[("DP-3",)]["zoom"], 2.0)

    def test_serialize_all_default_returns_none(self):
        groups = st.layout_groups_for(None, LIVE)
        self.assertIsNone(st.serialize_layout("/x/00.jpg", groups))

    def test_make_group_inherits_and_dissolves(self):
        groups = st.layout_groups_for(
            {"regions": [region(["DP-1", "DP-2", "DP-3"], zoom=1.5)]}, LIVE)
        # steal DP-3 + HDMI into a new group: donor trio keeps DP-1+DP-2
        groups2 = st.make_group(groups, ["DP-3", "HDMI-A-1"])
        new = st.group_of(groups2, "HDMI-A-1")
        self.assertEqual(new["monitors"], {"DP-3", "HDMI-A-1"})
        rest = st.group_of(groups2, "DP-1")
        self.assertEqual(rest["monitors"], {"DP-1", "DP-2"})
        self.assertEqual(rest["region"]["zoom"], 1.5)
        # largest donor was the trio -> new group inherits zoom 1.5
        self.assertEqual(new["region"]["zoom"], 1.5)

    def test_make_group_single_leftover_becomes_solo(self):
        groups = st.layout_groups_for(
            {"regions": [region(["DP-1", "DP-2"], zoom=1.5)]}, LIVE)
        groups2 = st.make_group(groups, ["DP-2", "DP-3"])
        dp1 = st.group_of(groups2, "DP-1")
        self.assertEqual(dp1["monitors"], {"DP-1"})
        self.assertEqual(dp1["region"]["zoom"], 1.5)  # placement kept

    def test_split_group(self):
        groups = st.layout_groups_for(
            {"regions": [region(["DP-1", "DP-2"], zoom=1.5)]}, LIVE)
        target = st.group_of(groups, "DP-1")
        groups2 = st.split_group(groups, target)
        self.assertEqual(len(groups2), 4)
        self.assertEqual(st.group_of(groups2, "DP-1")["monitors"], {"DP-1"})
        self.assertEqual(st.group_of(groups2, "DP-1")["region"]["zoom"], 1.5)

    def test_group_round_trip_regroup(self):
        groups = st.layout_groups_for(None, LIVE)
        grouped = st.make_group(groups, ["DP-1", "DP-2"])
        split = st.split_group(grouped, st.group_of(grouped, "DP-1"))
        regrouped = st.make_group(split, ["DP-1", "DP-2"])
        self.assertEqual(st.group_of(regrouped, "DP-1")["monitors"],
                         {"DP-1", "DP-2"})


class TestTransitions(unittest.TestCase):
    IMG = (3840, 2160)
    RW, RH = 2560.0, 1440.0

    def test_pan_by_moves_anchor_opposite(self):
        r = region(["HDMI-A-1"])
        # fill scale = 2/3: dragging +90 phys px moves pan by -90/((2/3)*3840)
        out = st.pan_by(r, 90, 0, self.IMG, self.RW, self.RH)
        self.assertAlmostEqual(out["pan"][0], -90 / ((2 / 3) * 3840))
        self.assertEqual(out["pan"][1], 0.0)

    def test_pan_clamped(self):
        r = region(["HDMI-A-1"], pan=(1.49, 0))
        out = st.pan_by(r, -1e9, 0, self.IMG, self.RW, self.RH)
        self.assertEqual(out["pan"][0], 1.5)

    def test_zoom_about_fixes_anchor_point(self):
        r = region(["HDMI-A-1"], zoom=1.2, pan=(0.05, -0.1))
        anchor = (400.0, 1100.0)
        sx, sy = region_scales(r, *self.IMG, self.RW, self.RH)
        au = self.IMG[0] * (0.5 + 0.05)
        av = self.IMG[1] * (0.5 - 0.1)
        u_before = au + (anchor[0] - self.RW / 2) / sx
        v_before = av + (anchor[1] - self.RH / 2) / sy

        out = st.zoom_about(r, 1.3, anchor, self.IMG, self.RW, self.RH)
        sx2, sy2 = region_scales(out, *self.IMG, self.RW, self.RH)
        au2 = self.IMG[0] * (0.5 + out["pan"][0])
        av2 = self.IMG[1] * (0.5 + out["pan"][1])
        u_after = au2 + (anchor[0] - self.RW / 2) / sx2
        v_after = av2 + (anchor[1] - self.RH / 2) / sy2
        self.assertAlmostEqual(u_before, u_after, places=6)
        self.assertAlmostEqual(v_before, v_after, places=6)
        self.assertAlmostEqual(out["zoom"], 1.56, places=9)

    def test_zoom_clamped_at_bounds(self):
        r = region(["HDMI-A-1"], zoom=9.0)
        out = st.zoom_about(r, 10, (0, 0), self.IMG, self.RW, self.RH)
        self.assertEqual(out["zoom"], 10.0)
        out2 = st.zoom_about(region(["HDMI-A-1"], zoom=0.06), 0.01,
                             (0, 0), self.IMG, self.RW, self.RH)
        self.assertEqual(out2["zoom"], 0.05)

    def test_snap_pan_snaps_center_within_threshold(self):
        r = region(["HDMI-A-1"], zoom=1.5, pan=(0.004, 0.0))
        out, axes = st.snap_pan(r, self.IMG, self.RW, self.RH, 16.0)
        self.assertEqual(out["pan"][0], 0.0)
        self.assertEqual(axes, {"x"})

    def test_snap_pan_outside_threshold_untouched(self):
        r = region(["HDMI-A-1"], zoom=1.5, pan=(0.08, 0.0))
        out, axes = st.snap_pan(r, self.IMG, self.RW, self.RH, 16.0)
        self.assertEqual(out["pan"][0], 0.08)
        self.assertEqual(axes, set())

    def test_snap_pan_edge_flush(self):
        # zoom 1.5 fill: flush pan = 2560/(2*1*3840) - 0.5 = -1/6
        flush = 2560 / (2 * 1.0 * 3840) - 0.5
        r = region(["HDMI-A-1"], zoom=1.5, pan=(flush + 0.003, 0.0))
        out, axes = st.snap_pan(r, self.IMG, self.RW, self.RH, 16.0)
        self.assertAlmostEqual(out["pan"][0], flush, places=9)
        self.assertEqual(axes, {"x"})

    def test_cycle_mode_ring_and_reset(self):
        r = region(["HDMI-A-1"], zoom=2.0, pan=(0.3, 0.3))
        seen = []
        for _ in range(len(st.MODE_RING)):
            r = st.cycle_mode(r)
            seen.append(r["mode"])
        self.assertEqual(seen, ["fit", "center", "tile", "stretch", "fill"])
        self.assertEqual(r["zoom"], 1.0)
        self.assertEqual(r["pan"], [0.0, 0.0])
        back = st.cycle_mode(r, -1)
        self.assertEqual(back["mode"], "stretch")


PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00" * 24)
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 28
WEBP = b"RIFF\x24\x00\x00\x00WEBPVP8 " + b"\x00" * 16
AVIF = b"\x00\x00\x00 ftypavif" + b"\x00" * 20


class TestAddedImages(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, name, data):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def test_recognises_real_headers(self):
        for name, data in (("a.png", PNG), ("b.jpg", JPEG),
                           ("c.webp", WEBP), ("d.avif", AVIF)):
            self.assertTrue(st.is_image_file(self.write(name, data)), name)

    def test_extension_alone_is_not_enough(self):
        liar = self.write("liar.png", b"#!/bin/sh\nrm -rf /\n")
        self.assertFalse(st.is_image_file(liar))

    def test_missing_file(self):
        self.assertFalse(st.is_image_file(os.path.join(self.dir, "nope.png")))

    def test_merge_keeps_order_and_rejects_junk(self):
        good = self.write("good.png", PNG)
        bad = self.write("bad.png", b"nope")
        kept, rejected = st.merge_extras([], [good, bad], known=[])
        self.assertEqual(kept, [good])
        self.assertEqual(rejected, [bad])

    def test_merge_ignores_duplicates_and_theme_images(self):
        one = self.write("one.png", PNG)
        two = self.write("two.png", PNG)
        kept, rejected = st.merge_extras([one], [one, two, two], known=[])
        self.assertEqual(kept, [one, two])
        self.assertEqual(rejected, [])
        kept, _ = st.merge_extras([], [one], known=[one])
        self.assertEqual(kept, [])

    def test_extras_in_use_only_counts_what_is_painted(self):
        extras = ["/tmp/mine.png", "/tmp/unused.png"]
        live = {"DP-1": "/tmp/mine.png", "DP-2": "/theme/00.jpg"}
        self.assertEqual(st.extras_in_use(live, extras), ["/tmp/mine.png"])
        self.assertEqual(st.extras_in_use({}, extras), [])

    def test_arrangement_prefers_what_was_painted(self):
        names = ["DP-1", "DP-2", "DP-3"]
        mon_image = {"DP-1": "/theme/00.jpg", "DP-2": "/theme/01.jpg"}
        live = {"DP-2": "/tmp/mine.png"}
        self.assertEqual(
            st.arrangement(names, mon_image, live),
            {"DP-1": "/theme/00.jpg", "DP-2": "/tmp/mine.png"})

    def test_apply_commands_repaint_vs_freeze(self):
        cmds = st.apply_commands({"/theme/00.jpg"}, "/e.py", "/w.sh",
                                 locking=False)
        self.assertEqual(cmds, ['python3 /e.py render "/theme/00.jpg"',
                                "/w.sh apply-all"])
        cmds = st.apply_commands({"/theme/00.jpg"}, "/e.py", "/w.sh",
                                 locking=True)
        self.assertEqual(cmds, ['python3 /e.py render "/theme/00.jpg"',
                                "/w.sh lock", "/w.sh paint-arrangement"])
        self.assertEqual(st.apply_commands(set(), "/e.py", "/w.sh", False), [])
        self.assertEqual(
            st.apply_commands(set(), "/e.py", "/w.sh", True),
            ["/w.sh lock", "/w.sh paint-arrangement"])


class TestRegroup(unittest.TestCase):
    def groups(self):
        return [{"monitors": ["DP-1", "DP-2"],
                 "region": {"mode": "fill", "zoom": 1.4, "pan": [0.2, 0.0]}},
                {"monitors": ["DP-3"], "region": st.default_region()}]

    def test_unplugged_member_leaves_the_span_intact(self):
        out = st.regroup(self.groups(), ["DP-1", "DP-3"])
        self.assertEqual([g["monitors"] for g in out], [["DP-1"], ["DP-3"]])
        self.assertEqual(out[0]["region"]["zoom"], 1.4)
        self.assertEqual(out[0]["region"]["pan"], [0.2, 0.0])

    def test_group_that_empties_disappears(self):
        out = st.regroup(self.groups(), ["DP-3"])
        self.assertEqual([g["monitors"] for g in out], [["DP-3"]])

    def test_new_display_arrives_as_its_own_group(self):
        out = st.regroup(self.groups(), ["DP-1", "DP-2", "DP-3", "DP-4"])
        self.assertEqual([g["monitors"] for g in out],
                         [["DP-1", "DP-2"], ["DP-3"], ["DP-4"]])
        self.assertTrue(st.is_default_region(out[-1]["region"]))

    def test_everything_unplugged(self):
        self.assertEqual(st.regroup(self.groups(), []), [])

    def test_no_change_is_no_change(self):
        before = self.groups()
        self.assertEqual(st.regroup(before, ["DP-1", "DP-2", "DP-3"]), before)

    def test_regions_are_copied_not_shared(self):
        before = self.groups()
        out = st.regroup(before, ["DP-1", "DP-2", "DP-3"])
        out[0]["region"]["zoom"] = 9.0
        self.assertEqual(before[0]["region"]["zoom"], 1.4)


if __name__ == "__main__":
    unittest.main()
