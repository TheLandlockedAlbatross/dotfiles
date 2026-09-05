"""Slice rendering and /tmp cache for the background layout engine.

Everything rendered lives under /tmp/hypr-bg-layout — original images are
never modified. index.tsv (written atomically) is the contract with
bg-paint.lib.sh:

  image \t monitor \t span_slice \t solo_slice_or_span \t other_members_csv_or_-

The image column is the path exactly as it appears in the workspace bg map
(so bash can string-match); a row exists for every (image, monitor) covered
by a layout region. fallback "hold" repeats the span path in the solo column.
"""

import concurrent.futures
import fcntl
import json
import os
import subprocess
import time

from PIL import Image

from . import store
from .geometry import (cache_key, compute_slices, image_dest_in_out,
                       mons_from_hyprctl, span_members, tile_phase)

CACHE_DIR = "/tmp/hypr-bg-layout"
SLICES_DIR = os.path.join(CACHE_DIR, "slices")
INDEX_FILE = os.path.join(CACHE_DIR, "index.tsv")
LOCK_FILE = os.path.join(CACHE_DIR, ".lock")
LOG_FILE = os.path.join(CACHE_DIR, "engine.log")
WS_MAP_FILE = "/tmp/hypr-workspace-bg-map"

MAX_CACHE_BYTES = 500 * 1024 * 1024
RENDER_WORKERS = 4


def log(msg):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%F %T')} {msg}\n")
    except OSError:
        pass


def _hex_rgb(color):
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def render_slice(img, spec, out_path):
    """Render one CropSpec of an opened PIL image to out_path (PNG)."""
    iw, ih = img.size
    u0, v0, u1, v1 = spec.box
    ow, oh = spec.out_size

    if spec.tile:
        px, py, tw, th = tile_phase(spec, img.size)
        tile = img.resize((max(1, round(tw)), max(1, round(th))),
                          Image.LANCZOS)
        canvas = Image.new("RGB", (ow, oh), _hex_rgb(spec.letterbox))
        y = py
        while y < oh:
            x = px
            while x < ow:
                canvas.paste(tile, (round(x), round(y)))
                x += tw
            y += th
        out = canvas
    elif u0 >= 0 and v0 >= 0 and u1 <= iw and v1 <= ih:
        # Fully inside the image: single subpixel-exact resample.
        out = img.resize((ow, oh), Image.LANCZOS, box=spec.box)
        if out.mode != "RGB":
            out = out.convert("RGB")
    else:
        canvas = Image.new("RGB", (ow, oh), _hex_rgb(spec.letterbox))
        dx0, dy0, dx1, dy1 = image_dest_in_out(spec, img.size)
        # Clip the destination to the canvas, then map back to source px so
        # we only decode/resample what is visible.
        cx0, cy0 = max(dx0, 0.0), max(dy0, 0.0)
        cx1, cy1 = min(dx1, float(ow)), min(dy1, float(oh))
        if cx1 > cx0 and cy1 > cy0:
            kx = (u1 - u0) / ow
            ky = (v1 - v0) / oh
            src = (u0 + cx0 * kx, v0 + cy0 * ky,
                   u0 + cx1 * kx, v0 + cy1 * ky)
            dsize = (max(1, round(cx1) - round(cx0)),
                     max(1, round(cy1) - round(cy0)))
            piece = img.resize(dsize, Image.LANCZOS, box=src)
            if piece.mode != "RGB":
                piece = piece.convert("RGB")
            canvas.paste(piece, (round(cx0), round(cy0)))
        out = canvas
    out.save(out_path, "PNG", compress_level=1)


def slice_rows(image_as_listed, layout, mons):
    """Compute index rows + render jobs for one image.

    Returns (rows, jobs): rows are index.tsv tuples; jobs maps
    slice_path -> CropSpec still needing a render (deduped)."""
    real = os.path.realpath(image_as_listed)
    st = os.stat(real)
    with Image.open(real) as img:
        img_size = img.size
    slices = compute_slices(layout, mons, img_size)
    rows, jobs = [], {}
    for mon_name, (span, solo) in sorted(slices.items()):
        span_key = cache_key(real, st.st_mtime_ns, st.st_size, mon_name,
                             span, "span")
        span_path = os.path.join(SLICES_DIR, span_key + ".png")
        if not os.path.isfile(span_path):
            jobs[span_path] = span
        if solo is not None:
            solo_key = cache_key(real, st.st_mtime_ns, st.st_size, mon_name,
                                 solo, "solo")
            solo_path = os.path.join(SLICES_DIR, solo_key + ".png")
            if not os.path.isfile(solo_path):
                jobs[solo_path] = solo
        else:
            solo_path = span_path  # solo region, or fallback "hold"
        members = span_members(layout, mon_name)
        rows.append((image_as_listed, mon_name, span_path, solo_path,
                     ",".join(members) if members else "-"))
    return rows, jobs


def _run_jobs(image_path, jobs):
    if not jobs:
        return
    real = os.path.realpath(image_path)
    with Image.open(real) as img:
        img.load()
        with concurrent.futures.ThreadPoolExecutor(RENDER_WORKERS) as pool:
            futures = {pool.submit(render_slice, img, spec, path): path
                       for path, spec in jobs.items()}
            for fut in concurrent.futures.as_completed(futures):
                fut.result()


def _read_index():
    rows = []
    try:
        with open(INDEX_FILE) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 5:
                    rows.append(tuple(parts))
    except OSError:
        pass
    return rows


def _write_index(rows):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = INDEX_FILE + ".tmp"
    with open(tmp, "w") as f:
        for row in rows:
            f.write("\t".join(row) + "\n")
    os.rename(tmp, INDEX_FILE)


def _cleanup_slices(rows):
    referenced = {r[2] for r in rows} | {r[3] for r in rows}
    try:
        entries = [os.path.join(SLICES_DIR, n) for n in os.listdir(SLICES_DIR)]
    except OSError:
        return
    unreferenced = [p for p in entries if p not in referenced]
    for p in unreferenced:
        try:
            os.unlink(p)
        except OSError:
            pass
    # Belt-and-braces size cap on what remains.
    kept = [(p, os.stat(p)) for p in entries
            if p in referenced and os.path.isfile(p)]
    total = sum(st.st_size for _, st in kept)
    if total > MAX_CACHE_BYTES:
        for p, st in sorted(kept, key=lambda e: e[1].st_mtime):
            if total <= MAX_CACHE_BYTES:
                break
            try:
                os.unlink(p)
                total -= st.st_size
            except OSError:
                pass


class _Lock:
    def __enter__(self):
        os.makedirs(CACHE_DIR, exist_ok=True)
        self.f = open(LOCK_FILE, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def live_monitors():
    out = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True,
                         text=True, timeout=5)
    return mons_from_hyprctl(json.loads(out.stdout))


def _candidate_images():
    """Images that may be painted: unique ws-map lines, plus every valid
    sidecar's image (still-existing files only), keyed by listed path."""
    seen, out = set(), []

    def add(path):
        if path and path not in seen and os.path.isfile(path):
            seen.add(path)
            out.append(path)

    try:
        with open(WS_MAP_FILE) as f:
            for line in f:
                add(line.strip())
    except OSError:
        pass
    for _, layout in store.list_sidecars():
        add(layout.get("image", ""))
    return out


def render_images(image_paths, mons=None):
    """Render slices + rewrite index rows for the given images (other images'
    rows are preserved). Returns the written rows for those images."""
    if mons is None:
        mons = live_monitors()
    with _Lock():
        new_rows = []
        targets = set()
        for path in image_paths:
            targets.add(path)
            try:
                layout = store.load_layout(path)
            except store.LayoutError as e:
                log(f"skipping {path}: {e}")
                continue
            if layout is None:
                continue
            try:
                rows, jobs = slice_rows(path, layout, mons)
                os.makedirs(SLICES_DIR, exist_ok=True)
                _run_jobs(path, jobs)
                new_rows.extend(rows)
            except Exception as e:  # noqa: BLE001 — engine must not take down callers
                log(f"render failed for {path}: {e!r}")
        kept = [r for r in _read_index() if r[0] not in targets]
        all_rows = kept + new_rows
        _write_index(all_rows)
        _cleanup_slices(all_rows)
        return new_rows


def render_all(mons=None):
    """Render every needed slice; index rows for images no longer relevant
    are dropped (full rewrite)."""
    if mons is None:
        mons = live_monitors()
    images = _candidate_images()
    with _Lock():
        all_rows = []
        for path in images:
            try:
                layout = store.load_layout(path)
            except store.LayoutError as e:
                log(f"skipping {path}: {e}")
                continue
            if layout is None:
                continue
            try:
                rows, jobs = slice_rows(path, layout, mons)
                os.makedirs(SLICES_DIR, exist_ok=True)
                _run_jobs(path, jobs)
                all_rows.extend(rows)
            except Exception as e:  # noqa: BLE001
                log(f"render failed for {path}: {e!r}")
        _write_index(all_rows)
        _cleanup_slices(all_rows)
        return all_rows
