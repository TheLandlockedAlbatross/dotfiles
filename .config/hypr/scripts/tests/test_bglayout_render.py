"""Renderer tests: pixel-level slice checks on synthetic images, cache and
index behavior. No live hyprctl/awww involved — monitors are fixtures."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from PIL import Image  # noqa: E402

from bglayout import render, store  # noqa: E402
from bglayout.geometry import Mon, member_crop  # noqa: E402

# Scaled-down 2x2 grid (keeps tests fast): logical 512x288 per monitor,
# physical 640x360, scale 1.25 — same proportions as the real Hamlet grid.
def mon(name, lx, ly):
    return Mon(name, lx, ly, 512, 288, 640, 360, 1.25, 0, False)


GRID = [mon("DP-1", 0, 0), mon("DP-2", 512, 0),
        mon("DP-3", 0, 288), mon("HDMI-A-1", 512, 288)]
QUAD = ["DP-1", "DP-2", "DP-3", "HDMI-A-1"]


def region(monitors, mode="fill", zoom=1.0, pan=(0.0, 0.0), **kw):
    return dict({"monitors": monitors, "mode": mode, "zoom": zoom,
                 "pan": list(pan)}, **kw)


class RenderCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = self._tmp.name
        self._orig_render = {k: getattr(render, k) for k in
                             ("CACHE_DIR", "SLICES_DIR", "INDEX_FILE",
                              "LOCK_FILE", "LOG_FILE", "WS_MAP_FILE")}
        render.CACHE_DIR = os.path.join(base, "cache")
        render.SLICES_DIR = os.path.join(base, "cache", "slices")
        render.INDEX_FILE = os.path.join(base, "cache", "index.tsv")
        render.LOCK_FILE = os.path.join(base, "cache", ".lock")
        render.LOG_FILE = os.path.join(base, "cache", "engine.log")
        render.WS_MAP_FILE = os.path.join(base, "ws-map")
        self._orig_store = (store.STORE_DIR, store.IMAGES_DIR,
                            store.PRESETS_FILE)
        store.STORE_DIR = os.path.join(base, "layouts")
        store.IMAGES_DIR = os.path.join(base, "layouts", "images")
        store.PRESETS_FILE = os.path.join(base, "layouts", "presets.json")
        self.addCleanup(self._restore)

    def _restore(self):
        for k, v in self._orig_render.items():
            setattr(render, k, v)
        store.STORE_DIR, store.IMAGES_DIR, store.PRESETS_FILE = self._orig_store
        self._tmp.cleanup()

    def make_image(self, name, w, h, painter):
        img = Image.new("RGB", (w, h))
        px = img.load()
        for y in range(h):
            for x in range(w):
                px[x, y] = painter(x, y)
        path = os.path.join(self._tmp.name, name)
        img.save(path, "PNG")
        return path


class TestRenderSlice(RenderCase):
    def test_quad_span_quadrant_colors(self):
        # Image quadrants: red / green / blue / white. Span across the 2x2
        # grid: each monitor's slice must be its quadrant's solid color.
        colors = {(0, 0): (255, 0, 0), (1, 0): (0, 255, 0),
                  (0, 1): (0, 0, 255), (1, 1): (255, 255, 255)}
        path = self.make_image(
            "quads.png", 512, 288,
            lambda x, y: colors[(x >= 256, y >= 144)])
        cfg = region(QUAD)
        expected = {"DP-1": (255, 0, 0), "DP-2": (0, 255, 0),
                    "DP-3": (0, 0, 255), "HDMI-A-1": (255, 255, 255)}
        with Image.open(path) as img:
            for m in GRID:
                spec = member_crop((512, 288), cfg, GRID, m)
                out_path = os.path.join(self._tmp.name, f"{m.name}.png")
                render.render_slice(img, spec, out_path)
                with Image.open(out_path) as out:
                    self.assertEqual(out.size, (640, 360))
                    # Sample interior points: the LANCZOS kernel deliberately
                    # reads a few source px past the box (that is what blends
                    # span seams), so edge pixels mix quadrant colors.
                    for sample in ((20, 20), (320, 180), (600, 330)):
                        self.assertEqual(out.getpixel(sample),
                                         expected[m.name], m.name)

    def test_horizontal_seam_continuity(self):
        # Smooth horizontal gradient spanned across the top row: DP-1's right
        # edge must continue into DP-2's left edge without a jump or overlap.
        path = self.make_image("grad.png", 1024, 288,
                               lambda x, y: (x * 255 // 1023, 0, 0))
        cfg = region(["DP-1", "DP-2"])
        members = GRID[:2]
        outs = {}
        with Image.open(path) as img:
            for m in members:
                spec = member_crop((1024, 288), cfg, members, m)
                out_path = os.path.join(self._tmp.name, f"seam-{m.name}.png")
                render.render_slice(img, spec, out_path)
                outs[m.name] = Image.open(out_path)
        y = 180
        right = outs["DP-1"].getpixel((639, y))[0]
        left = outs["DP-2"].getpixel((0, y))[0]
        # Adjacent output columns sample adjacent source px (0.8 img px/out px)
        self.assertLess(abs(left - right), 3)
        self.assertGreater(left, 120)  # both sit at the gradient midpoint
        self.assertLess(right, 135)
        for im in outs.values():
            im.close()

    def test_fit_letterbox_bars(self):
        # 1:1 image fit onto a 16:9 monitor -> pillarbox bars in letterbox
        # color, image centered.
        path = self.make_image("sq.png", 200, 200,
                               lambda x, y: (0, 200, 200))
        m = GRID[3]
        spec = member_crop((200, 200), region(["HDMI-A-1"], mode="fit"),
                           [m], m)
        spec = type(spec)(box=spec.box, out_size=spec.out_size,
                          mode=spec.mode, letterbox="#102030")
        out_path = os.path.join(self._tmp.name, "fit.png")
        with Image.open(path) as img:
            render.render_slice(img, spec, out_path)
        with Image.open(out_path) as out:
            # dest is x in [140, 500) — bars on both sides
            self.assertEqual(out.getpixel((10, 180)), (16, 32, 48))
            self.assertEqual(out.getpixel((630, 180)), (16, 32, 48))
            self.assertEqual(out.getpixel((320, 180)), (0, 200, 200))

    def test_tile_repeats_at_phase(self):
        # 100x90 two-tone tile, centered: tile corners land where
        # tile_phase says (phase = (-80+320) % 100 = 40 ... verify pattern
        # by sampling period-spaced pixels).
        path = self.make_image(
            "tile.png", 100, 90,
            lambda x, y: (255, 255, 0) if (x < 50) == (y < 45)
            else (40, 40, 40))
        m = GRID[0]
        spec = member_crop((100, 90), region(["DP-1"], mode="tile"), [m], m)
        out_path = os.path.join(self._tmp.name, "tile-out.png")
        with Image.open(path) as img:
            render.render_slice(img, spec, out_path)
        with Image.open(out_path) as out:
            self.assertEqual(out.size, (640, 360))
            a = out.getpixel((120, 100))
            self.assertEqual(out.getpixel((220, 100)), a)   # +1 x-period
            self.assertEqual(out.getpixel((120, 190)), a)   # +1 y-period


class TestRenderImages(RenderCase):
    def _saved_image_with_layout(self, name="img.png", regions=None):
        path = self.make_image(name, 512, 288, lambda x, y: (x % 256, y % 256, 0))
        store.save_layout(path, {
            "version": 1, "image": path,
            "regions": regions or [region(QUAD, fallback="fit")]})
        return path

    def test_index_rows_and_slices(self):
        path = self._saved_image_with_layout()
        rows = render.render_images([path], mons=GRID)
        self.assertEqual(len(rows), 4)
        for img_col, mon_name, span_path, solo_path, members in rows:
            self.assertEqual(img_col, path)
            self.assertTrue(os.path.isfile(span_path))
            self.assertTrue(os.path.isfile(solo_path))
            self.assertNotEqual(span_path, solo_path)  # fallback fit != hold
            self.assertEqual(len(members.split(",")), 3)
            with Image.open(span_path) as s:
                self.assertEqual(s.size, (640, 360))

    def test_hold_fallback_repeats_span_path(self):
        path = self._saved_image_with_layout(
            regions=[region(QUAD, fallback="hold")])
        rows = render.render_images([path], mons=GRID)
        for _, _, span_path, solo_path, _ in rows:
            self.assertEqual(span_path, solo_path)

    def test_idempotent_cache_hits(self):
        path = self._saved_image_with_layout()
        rows = render.render_images([path], mons=GRID)
        mtimes = {r[2]: os.stat(r[2]).st_mtime_ns for r in rows}
        rows2 = render.render_images([path], mons=GRID)
        self.assertEqual(rows, rows2)
        for r in rows2:
            self.assertEqual(os.stat(r[2]).st_mtime_ns, mtimes[r[2]])

    def test_index_merge_preserves_other_images(self):
        a = self._saved_image_with_layout("a.png")
        b = self._saved_image_with_layout("b.png")
        render.render_images([a], mons=GRID)
        render.render_images([b], mons=GRID)
        images_in_index = {r[0] for r in render._read_index()}
        self.assertEqual(images_in_index, {a, b})
        # re-rendering a must not drop b's rows
        render.render_images([a], mons=GRID)
        self.assertEqual({r[0] for r in render._read_index()}, {a, b})

    def test_layoutless_image_has_no_rows(self):
        path = self.make_image("bare.png", 512, 288, lambda x, y: (9, 9, 9))
        render.render_images([path], mons=GRID)
        self.assertEqual(render._read_index(), [])

    def test_cleanup_drops_unreferenced_slices(self):
        path = self._saved_image_with_layout()
        render.render_images([path], mons=GRID)
        stray = os.path.join(render.SLICES_DIR, "deadbeefdeadbeef.png")
        open(stray, "w").close()
        render.render_images([path], mons=GRID)
        self.assertFalse(os.path.exists(stray))

    def test_render_all_uses_ws_map(self):
        path = self._saved_image_with_layout()
        with open(render.WS_MAP_FILE, "w") as f:
            f.write((path + "\n") * 40)
        rows = render.render_all(mons=GRID)
        self.assertEqual(len(rows), 4)

    def test_deleted_layout_drops_rows(self):
        path = self._saved_image_with_layout()
        render.render_images([path], mons=GRID)
        store.delete_layout(path)
        render.render_images([path], mons=GRID)
        self.assertEqual(render._read_index(), [])


if __name__ == "__main__":
    unittest.main()
