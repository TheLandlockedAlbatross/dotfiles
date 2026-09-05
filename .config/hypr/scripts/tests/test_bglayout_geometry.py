"""Geometry tests for the background layout engine.

Run: cd ~/.config/hypr/scripts && python3 -m unittest discover tests
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from bglayout.geometry import (  # noqa: E402
    Mon, cache_key, compute_slices, image_dest_in_out, member_crop,
    mons_from_hyprctl, region_bbox, region_phys, span_members, tile_phase,
)


def mon(name, lx, ly, lw=2048, lh=1152, pw=2560, ph=1440, scale=1.25,
        transform=0, disabled=False):
    return Mon(name, lx, ly, lw, lh, pw, ph, scale, transform, disabled)


# The real Hamlet grid: DP-1/DP-2 top row, DP-3/HDMI-A-1 bottom row.
DP1 = mon("DP-1", 0, 0)
DP2 = mon("DP-2", 2048, 0)
DP3 = mon("DP-3", 0, 1152)
HDMI = mon("HDMI-A-1", 2048, 1152)
FOUR_GRID = [DP1, DP2, DP3, HDMI]

IMG_4K = (3840, 2160)


def region(monitors, mode="fill", zoom=1.0, pan=(0.0, 0.0), **kw):
    return dict({"monitors": monitors, "mode": mode, "zoom": zoom,
                 "pan": list(pan)}, **kw)


def layout(*regions, **kw):
    return dict({"version": 1, "image": "/x.jpg", "regions": list(regions)}, **kw)


def assert_box(tc, box, expected, tol=1e-6):
    for got, want in zip(box, expected):
        tc.assertAlmostEqual(got, want, delta=tol,
                             msg=f"box {box} != expected {expected}")


class TestSpans(unittest.TestCase):
    def test_quad_span_fill_4k(self):
        cfg = region(["DP-1", "DP-2", "DP-3", "HDMI-A-1"])
        expected = {
            "DP-1": (0, 0, 1920, 1080),
            "DP-2": (1920, 0, 3840, 1080),
            "DP-3": (0, 1080, 1920, 2160),
            "HDMI-A-1": (1920, 1080, 3840, 2160),
        }
        for m in FOUR_GRID:
            spec = member_crop(IMG_4K, cfg, FOUR_GRID, m)
            assert_box(self, spec.box, expected[m.name])
            self.assertEqual(spec.out_size, (2560, 1440))

    def test_seam_exactness_odd_image(self):
        cfg = region(["DP-1", "DP-2", "DP-3", "HDMI-A-1"])
        img = (3841, 2161)
        b1 = member_crop(img, cfg, FOUR_GRID, DP1).box
        b2 = member_crop(img, cfg, FOUR_GRID, DP2).box
        b3 = member_crop(img, cfg, FOUR_GRID, DP3).box
        self.assertEqual(b1[2], b2[0])  # exact float equality: shared vertical seam
        self.assertEqual(b1[3], b3[1])  # shared horizontal seam

    def test_top_row_span_fill_4k(self):
        cfg = region(["DP-1", "DP-2"])
        members = [DP1, DP2]
        assert_box(self, member_crop(IMG_4K, cfg, members, DP1).box,
                   (0, 540, 1920, 1620))
        assert_box(self, member_crop(IMG_4K, cfg, members, DP2).box,
                   (1920, 540, 3840, 1620))

    def test_span_pan_shift(self):
        base = region(["DP-1", "DP-2", "DP-3", "HDMI-A-1"])
        panned = region(["DP-1", "DP-2", "DP-3", "HDMI-A-1"], pan=(0.1, -0.05))
        for m in FOUR_GRID:
            b0 = member_crop(IMG_4K, base, FOUR_GRID, m).box
            b1 = member_crop(IMG_4K, panned, FOUR_GRID, m).box
            assert_box(self, b1, (b0[0] + 384, b0[1] - 108,
                                  b0[2] + 384, b0[3] - 108))

    def test_mixed_scale_span(self):
        syn = mon("SYN-2", 2048, 0, lw=2560, lh=1440, pw=2560, ph=1440, scale=1.0)
        members = [DP1, syn]
        lx, ly, dref, rw, rh = region_phys(members)
        self.assertEqual((lx, ly, dref, rw, rh), (0, 0, 1.25, 5760, 1800))
        cfg = region(["DP-1", "SYN-2"])
        spec = member_crop(IMG_4K, cfg, members, syn)
        # s = max(5760/3840, 1800/2160) = 1.5; SYN-2 covers 3200 region-phys px
        self.assertAlmostEqual(spec.box[2] - spec.box[0], 3200 / 1.5, delta=1e-6)
        self.assertEqual(spec.out_size, (2560, 1440))

    def test_exact_size_image_identity(self):
        cfg = region(["DP-1", "DP-2", "DP-3", "HDMI-A-1"])
        spec = member_crop((5120, 2880), cfg, FOUR_GRID, DP3)
        assert_box(self, spec.box, (0, 1440, 2560, 2880))


class TestSoloModes(unittest.TestCase):
    def test_fill_zoom_pan(self):
        cfg = region(["HDMI-A-1"], zoom=1.4, pan=(-0.10, 0.0))
        spec = member_crop(IMG_4K, cfg, [HDMI], HDMI)
        assert_box(self, spec.box,
                   (164.5714285714, 308.5714285714,
                    2907.4285714286, 1851.4285714286))

    def test_fill_aspect_mismatch(self):
        spec = member_crop((3000, 2000), region(["HDMI-A-1"]), [HDMI], HDMI)
        assert_box(self, spec.box, (0, 156.25, 3000, 1843.75))

    def test_fit_letterboxes_sides(self):
        spec = member_crop((3000, 2000), region(["HDMI-A-1"], mode="fit"),
                           [HDMI], HDMI)
        assert_box(self, image_dest_in_out(spec, (3000, 2000)),
                   (200, 0, 2360, 1440))

    def test_center_large_image(self):
        spec = member_crop((3000, 2000), region(["HDMI-A-1"], mode="center"),
                           [HDMI], HDMI)
        assert_box(self, spec.box, (220, 280, 2780, 1720))
        # scale is exactly 1: box size == out size
        self.assertEqual(spec.box[2] - spec.box[0], 2560)

    def test_center_small_image(self):
        spec = member_crop((1000, 800), region(["HDMI-A-1"], mode="center"),
                           [HDMI], HDMI)
        assert_box(self, spec.box, (-780, -320, 1780, 1120))
        assert_box(self, image_dest_in_out(spec, (1000, 800)),
                   (780, 320, 1780, 1120))

    def test_tile_phase_and_pan(self):
        spec = member_crop((1000, 800), region(["HDMI-A-1"], mode="tile"),
                           [HDMI], HDMI)
        px, py, tw, th = tile_phase(spec, (1000, 800))
        self.assertAlmostEqual(tw, 1000, delta=1e-6)
        self.assertAlmostEqual(th, 800, delta=1e-6)
        self.assertAlmostEqual(px % tw, 780, delta=1e-6)
        self.assertAlmostEqual(py % th, 320, delta=1e-6)
        # pan 0.25 shifts the lattice left by 250 scaled px
        spec2 = member_crop((1000, 800),
                            region(["HDMI-A-1"], mode="tile", pan=(0.25, 0)),
                            [HDMI], HDMI)
        px2 = tile_phase(spec2, (1000, 800))[0]
        self.assertAlmostEqual(px2 % tw, 530, delta=1e-6)

    def test_stretch_per_axis(self):
        spec = member_crop((1000, 1000), region(["HDMI-A-1"], mode="stretch"),
                           [HDMI], HDMI)
        assert_box(self, spec.box, (0, 0, 1000, 1000))

    def test_zoom_out_letterboxes(self):
        spec = member_crop(IMG_4K, region(["HDMI-A-1"], zoom=0.5), [HDMI], HDMI)
        assert_box(self, image_dest_in_out(spec, IMG_4K),
                   (640, 360, 1920, 1080))

    def test_pan_pushes_image_left(self):
        spec = member_crop(IMG_4K, region(["HDMI-A-1"], pan=(0.5, 0)),
                           [HDMI], HDMI)
        assert_box(self, spec.box, (1920, 0, 5760, 2160))
        dest = image_dest_in_out(spec, IMG_4K)
        self.assertAlmostEqual(dest[2], 1280, delta=1e-6)  # right half letterbox

    def test_transform_odd_swaps_dims(self):
        [m] = mons_from_hyprctl([{"name": "DP-9", "x": 0, "y": 0,
                                  "width": 2560, "height": 1440,
                                  "scale": 1.25, "transform": 1}])
        self.assertEqual((m.lw, m.lh), (1152, 2048))
        self.assertEqual((m.pw, m.ph), (1440, 2560))
        spec = member_crop(IMG_4K, region(["DP-9"]), [m], m)
        bw = spec.box[2] - spec.box[0]
        bh = spec.box[3] - spec.box[1]
        self.assertAlmostEqual(bw / bh, 1152 / 2048, delta=1e-9)
        self.assertEqual(spec.out_size, (1440, 2560))


class TestComputeSlices(unittest.TestCase):
    QUAD = ["DP-1", "DP-2", "DP-3", "HDMI-A-1"]

    def test_single_monitor_region_is_solo(self):
        lay = layout(region(["DP-3"]))
        slices = compute_slices(lay, FOUR_GRID, IMG_4K)
        self.assertEqual(set(slices), {"DP-3"})
        span, solo = slices["DP-3"]
        self.assertIsNone(solo)
        self.assertEqual(span_members(lay, "DP-3"), [])

    def test_uncovered_monitor_absent(self):
        slices = compute_slices(layout(region(["DP-1", "DP-2"])),
                                FOUR_GRID, IMG_4K)
        self.assertEqual(set(slices), {"DP-1", "DP-2"})

    def test_disabled_member_bbox_over_remaining(self):
        grid = [DP1, DP2, DP3,
                mon("HDMI-A-1", 2048, 1152, disabled=True)]
        lay = layout(region(self.QUAD))
        slices = compute_slices(lay, grid, IMG_4K)
        self.assertNotIn("HDMI-A-1", slices)
        # L-shaped 3-member set keeps the same bbox -> DP-1 crop unchanged
        assert_box(self, slices["DP-1"][0].box, (0, 0, 1920, 1080))

    def test_unknown_member_ignored(self):
        lay = layout(region(["DP-1", "GHOST-9"]))
        slices = compute_slices(lay, FOUR_GRID, IMG_4K)
        self.assertEqual(set(slices), {"DP-1"})
        span, solo = slices["DP-1"]
        self.assertIsNone(solo)  # only one live member -> nothing to break
        # bbox collapses to DP-1 alone; 16:9 image fills a 16:9 region exactly
        assert_box(self, span.box, (0, 0, 3840, 2160))

    def test_zero_live_members(self):
        self.assertEqual(
            compute_slices(layout(region(["GHOST-1", "GHOST-2"])),
                           FOUR_GRID, IMG_4K), {})

    def test_fallback_specs(self):
        lay = layout(region(["DP-1", "DP-2"], fallback="fit"))
        span, solo = compute_slices(lay, FOUR_GRID, IMG_4K)["DP-1"]
        self.assertEqual(solo.mode, "fit")
        assert_box(self, image_dest_in_out(solo, IMG_4K), (0, 0, 2560, 1440))

        hold = layout(region(["DP-1", "DP-2"], fallback="hold"))
        span, solo = compute_slices(hold, FOUR_GRID, IMG_4K)["DP-1"]
        self.assertIsNone(solo)

    def test_span_members(self):
        lay = layout(region(["DP-1", "DP-2"]), region(["DP-3"]))
        self.assertEqual(span_members(lay, "DP-1"), ["DP-2"])
        self.assertEqual(span_members(lay, "DP-3"), [])
        self.assertEqual(span_members(lay, "HDMI-A-1"), [])


class TestHelpers(unittest.TestCase):
    def test_region_bbox(self):
        self.assertEqual(region_bbox(FOUR_GRID), (0, 0, 4096, 2304))
        self.assertEqual(region_bbox([DP2, DP3]), (0, 0, 4096, 2304))

    def test_mons_from_hyprctl_normal(self):
        [m] = mons_from_hyprctl([{"name": "DP-1", "x": 0, "y": 0,
                                  "width": 2560, "height": 1440,
                                  "scale": 1.25, "transform": 0,
                                  "disabled": False}])
        self.assertEqual((m.lw, m.lh, m.pw, m.ph), (2048, 1152, 2560, 1440))

    def test_cache_key_stability_and_sensitivity(self):
        cfg = region(["HDMI-A-1"])
        spec = member_crop(IMG_4K, cfg, [HDMI], HDMI)
        k = cache_key("/a.jpg", 1, 2, "HDMI-A-1", spec, "span")
        self.assertEqual(k, cache_key("/a.jpg", 1, 2, "HDMI-A-1", spec, "span"))
        self.assertEqual(len(k), 16)
        others = {
            cache_key("/b.jpg", 1, 2, "HDMI-A-1", spec, "span"),
            cache_key("/a.jpg", 9, 2, "HDMI-A-1", spec, "span"),
            cache_key("/a.jpg", 1, 2, "DP-1", spec, "span"),
            cache_key("/a.jpg", 1, 2, "HDMI-A-1", spec, "solo"),
            cache_key("/a.jpg", 1, 2, "HDMI-A-1",
                      member_crop(IMG_4K, region(["HDMI-A-1"], zoom=1.1),
                                  [HDMI], HDMI), "span"),
        }
        self.assertNotIn(k, others)
        self.assertEqual(len(others), 5)


if __name__ == "__main__":
    unittest.main()
