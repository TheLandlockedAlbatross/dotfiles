"""Pure crop math for the background layout engine.

Shared by the renderer (bglayout.render), the GUI preview (background-picker.py)
and the tests — one source of truth so preview always equals render.

Coordinate spaces:
  logical    — Hyprland layout coords (monitor position/size after scale+transform)
  region-phys — a region's logical bbox multiplied by Dref (the densest member's
               physical px per logical px); output slices are cut in this space
  image      — source image pixels

A "region" is one entry of a layout's regions[] list:
  {"monitors": [...], "mode": m, "zoom": z, "pan": [px, py], "fallback": f}
The image point at fraction (0.5+px, 0.5+py) of the image anchors at the
region-phys center. zoom multiplies the mode's base scale.
"""

import hashlib
import json
from dataclasses import dataclass

MODES = ("fill", "fit", "center", "tile", "stretch")
FALLBACKS = ("fill", "fit", "center", "tile", "hold")


@dataclass(frozen=True)
class Mon:
    name: str
    lx: float  # logical position
    ly: float
    lw: float  # logical size (post-scale, post-transform)
    lh: float
    pw: int    # output slice size in buffer px (transform-odd: native h,w)
    ph: int
    scale: float
    transform: int
    disabled: bool = False


@dataclass(frozen=True)
class CropSpec:
    """One monitor's slice: sample `box` (image px, floats, may exceed image
    bounds) and resample to `out_size`. tile=True means the image repeats with
    period (iw, ih) across the box; letterbox is the fill color for any part of
    the box outside the image (non-tile only)."""
    box: tuple  # (u0, v0, u1, v1) floats in image px
    out_size: tuple  # (w, h) ints
    mode: str
    letterbox: str = "#000000"

    @property
    def tile(self):
        return self.mode == "tile"


def mons_from_hyprctl(monitors_json):
    """Build Mon list from parsed `hyprctl monitors -j` output."""
    out = []
    for m in monitors_json:
        w, h = m["width"], m["height"]
        scale = m.get("scale", 1.0) or 1.0
        transform = m.get("transform", 0)
        if transform % 2 == 1:
            w, h = h, w
        out.append(Mon(
            name=m["name"],
            lx=float(m["x"]), ly=float(m["y"]),
            lw=w / scale, lh=h / scale,
            pw=w, ph=h,
            scale=scale, transform=transform,
            disabled=bool(m.get("disabled", False)),
        ))
    return out


def region_bbox(members):
    """Logical bounding box (Lx, Ly, Lw, Lh) of a list of Mons."""
    x0 = min(m.lx for m in members)
    y0 = min(m.ly for m in members)
    x1 = max(m.lx + m.lw for m in members)
    y1 = max(m.ly + m.lh for m in members)
    return (x0, y0, x1 - x0, y1 - y0)


def region_phys(members):
    """(Lx, Ly, Dref, Rw, Rh): logical origin, reference density, physical size."""
    lx, ly, lw, lh = region_bbox(members)
    dref = max(m.pw / m.lw for m in members)
    return (lx, ly, dref, lw * dref, lh * dref)


def base_scale(mode, iw, ih, rw, rh):
    """Per-axis base scale (region-phys px per image px) before zoom."""
    if mode == "fill":
        s = max(rw / iw, rh / ih)
        return (s, s)
    if mode == "fit":
        s = min(rw / iw, rh / ih)
        return (s, s)
    if mode == "stretch":
        return (rw / iw, rh / ih)
    # center / tile
    return (1.0, 1.0)


def region_scales(region_cfg, iw, ih, rw, rh):
    """Effective per-axis scale (region-phys px per image px) incl. zoom."""
    zoom = region_cfg.get("zoom", 1.0)
    sx, sy = base_scale(region_cfg.get("mode", "fill"), iw, ih, rw, rh)
    return (sx * zoom, sy * zoom)


_scales = region_scales


def member_crop(img_size, region_cfg, members, member, letterbox="#000000"):
    """CropSpec for one member of a region.

    Forward map: X = Rw/2 + (u - au)*sx  (image px -> region-phys px), where
    (au, av) is the pan anchor. Inverted at the member's sub-rect corners.
    """
    iw, ih = img_size
    lx, ly, dref, rw, rh = region_phys(members)
    sx, sy = _scales(region_cfg, iw, ih, rw, rh)
    px, py = region_cfg.get("pan", (0.0, 0.0))
    au, av = iw * (0.5 + px), ih * (0.5 + py)

    x0 = (member.lx - lx) * dref
    y0 = (member.ly - ly) * dref
    x1 = x0 + member.lw * dref
    y1 = y0 + member.lh * dref

    box = (
        au + (x0 - rw / 2) / sx,
        av + (y0 - rh / 2) / sy,
        au + (x1 - rw / 2) / sx,
        av + (y1 - rh / 2) / sy,
    )
    return CropSpec(box=box, out_size=(member.pw, member.ph),
                    mode=region_cfg.get("mode", "fill"), letterbox=letterbox)


def image_dest_in_out(spec, img_size):
    """Where the (single, untiled) image lands in output-slice px:
    float rect (dx0, dy0, dx1, dy1). Everything outside is letterbox."""
    iw, ih = img_size
    u0, v0, u1, v1 = spec.box
    ow, oh = spec.out_size
    kx = ow / (u1 - u0)
    ky = oh / (v1 - v0)
    return ((0 - u0) * kx, (0 - v0) * ky, (iw - u0) * kx, (ih - v0) * ky)


def tile_phase(spec, img_size):
    """For tile mode: output-px position of the top-left corner of the tile
    containing box origin, plus the scaled tile size (tw, th).
    Tiles repeat from (phase_x, phase_y) with period (tw, th)."""
    iw, ih = img_size
    u0, v0, u1, v1 = spec.box
    ow, oh = spec.out_size
    kx = ow / (u1 - u0)
    ky = oh / (v1 - v0)
    import math
    ustart = math.floor(u0 / iw) * iw
    vstart = math.floor(v0 / ih) * ih
    return ((ustart - u0) * kx, (vstart - v0) * ky, iw * kx, ih * ky)


def _live_members(region_cfg, mons_by_name):
    out = []
    for name in region_cfg["monitors"]:
        m = mons_by_name.get(name)
        if m is not None and not m.disabled:
            out.append(m)
    return out


def compute_slices(layout, mons, img_size):
    """{monitor_name: (span_spec, solo_spec_or_None)} for every live monitor
    covered by the layout's regions.

    solo_spec is the fallback slice a member of a multi-monitor region shows
    when the span is broken (other members' workspaces show a different image).
    fallback "hold" -> solo_spec is None (keep showing the span slice).
    Single-monitor regions -> solo_spec is None (nothing to break).
    """
    mons_by_name = {m.name: m for m in mons if not m.disabled}
    letterbox = layout.get("letterbox", "#000000")
    result = {}
    for region_cfg in layout.get("regions", []):
        members = _live_members(region_cfg, mons_by_name)
        if not members:
            continue
        multi = len(region_cfg["monitors"]) > 1 and len(members) > 1
        fallback = region_cfg.get("fallback", "fill")
        for m in members:
            span = member_crop(img_size, region_cfg, members, m, letterbox)
            solo = None
            if multi and fallback != "hold":
                solo_cfg = {"monitors": [m.name], "mode": fallback,
                            "zoom": 1.0, "pan": (0.0, 0.0)}
                solo = member_crop(img_size, solo_cfg, [m], m, letterbox)
            result[m.name] = (span, solo)
    return result


def span_members(layout, mon_name):
    """Names of the other monitors sharing a multi-monitor region with mon_name
    (empty list if none)."""
    for region_cfg in layout.get("regions", []):
        if mon_name in region_cfg["monitors"] and len(region_cfg["monitors"]) > 1:
            return [n for n in region_cfg["monitors"] if n != mon_name]
    return []


def cache_key(image_path, mtime_ns, size, mon_name, spec, kind):
    """Stable 16-hex-char key for one rendered slice. Any change to image
    content, layout params, monitor geometry, or slice kind changes the key."""
    canonical = json.dumps({
        "image": image_path, "mtime_ns": mtime_ns, "size": size,
        "monitor": mon_name, "out": list(spec.out_size),
        "box": [round(c, 6) for c in spec.box],
        "mode": spec.mode, "letterbox": spec.letterbox, "kind": kind,
    }, sort_keys=True)
    return hashlib.sha1(canonical.encode()).hexdigest()[:16]
