"""Pure (GTK-free) state logic for background-picker.py.

Groups are the picker's working model of a layout: every live monitor belongs
to exactly one group; a group is {"monitors": set[str], "region": region_cfg}.
Multi-monitor groups and solo groups with non-default placement serialize back
to layout regions; untouched solo monitors stay out of the sidecar so the
engine leaves them on the plain-awww path.

All pan/zoom transitions delegate scale math to bglayout.geometry so the
picker preview, the renderer, and these transitions can never disagree.
"""

import copy
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bglayout.geometry import base_scale, region_phys, region_scales  # noqa: E402
from bglayout.store import PAN_MAX, PAN_MIN, ZOOM_MAX, ZOOM_MIN  # noqa: E402

MODE_RING = ("fill", "fit", "center", "tile", "stretch")

_QUERY_RE = re.compile(r"^:?\s*(\S+?):\s.*currently displaying:\s*image:\s*(.+)$")


def parse_awww_query(text):
    """{monitor: image_path} from `awww query` output."""
    out = {}
    for line in text.splitlines():
        m = _QUERY_RE.match(line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def default_region():
    return {"mode": "fill", "zoom": 1.0, "pan": [0.0, 0.0], "fallback": "fill"}


def is_default_region(region_cfg):
    d = default_region()
    return (region_cfg.get("mode", "fill") == d["mode"]
            and abs(region_cfg.get("zoom", 1.0) - 1.0) < 1e-9
            and all(abs(c) < 1e-9 for c in region_cfg.get("pan", [0, 0]))
            and region_cfg.get("fallback", "fill") == d["fallback"])


def _region_params(region_cfg):
    """Placement-only copy of a region config (no monitors key)."""
    out = copy.deepcopy(region_cfg)
    out.pop("monitors", None)
    out.setdefault("mode", "fill")
    out.setdefault("zoom", 1.0)
    out.setdefault("pan", [0.0, 0.0])
    out.setdefault("fallback", "fill")
    return out


def group(monitors, region_cfg=None):
    return {"monitors": set(monitors),
            "region": _region_params(region_cfg or default_region())}


def layout_groups_for(layout, live_monitors):
    """Materialize a layout dict (or None) against live monitor names.
    Regions whose members are all live become groups; anything else falls to
    implicit default solo groups. Every live monitor lands in exactly one
    group."""
    live = set(live_monitors)
    groups, claimed = [], set()
    for region_cfg in (layout or {}).get("regions", []):
        members = set(region_cfg.get("monitors", []))
        if members and members <= live and not (members & claimed):
            groups.append(group(members, region_cfg))
            claimed |= members
    for name in sorted(live - claimed):
        groups.append(group([name]))
    return groups


def serialize_layout(image_path, groups, letterbox=None):
    """Inverse of layout_groups_for. Returns a layout dict, or None when
    nothing differs from engine-default behavior (caller deletes the
    sidecar)."""
    regions = []
    for g in groups:
        if len(g["monitors"]) > 1 or not is_default_region(g["region"]):
            region_cfg = copy.deepcopy(g["region"])
            region_cfg["monitors"] = sorted(g["monitors"])
            regions.append(region_cfg)
    if not regions:
        return None
    layout = {"version": 1, "image": os.path.realpath(image_path),
              "regions": regions}
    if letterbox:
        layout["letterbox"] = letterbox
    return layout


def _check_invariant(groups):
    seen = set()
    for g in groups:
        overlap = seen & g["monitors"]
        assert not overlap, f"monitor(s) {overlap} in more than one group"
        seen |= g["monitors"]


def make_group(groups, members):
    """Merge `members` (>= 2 monitor names) into one span group. The new group
    inherits the region of the largest contributing group; groups losing
    members keep going if >= 2 members remain, else fall back to solos that
    keep their placement."""
    members = set(members)
    donors = [g for g in groups if g["monitors"] & members]
    inherit = max(donors, key=lambda g: len(g["monitors"] & members))
    out = []
    for g in groups:
        remaining = g["monitors"] - members
        if not remaining:
            continue
        if len(remaining) == len(g["monitors"]):
            out.append(g)
        elif len(remaining) >= 2:
            out.append({"monitors": remaining,
                        "region": copy.deepcopy(g["region"])})
        else:
            out.extend({"monitors": {n},
                        "region": copy.deepcopy(g["region"])}
                       for n in sorted(remaining))
    out.append({"monitors": members,
                "region": copy.deepcopy(inherit["region"])})
    _check_invariant(out)
    return out


def split_group(groups, target):
    """Dissolve one group into solo groups that keep its placement."""
    out = []
    for g in groups:
        if g is target or g["monitors"] == set(target["monitors"]):
            out.extend({"monitors": {n}, "region": copy.deepcopy(g["region"])}
                       for n in sorted(g["monitors"]))
        else:
            out.append(g)
    _check_invariant(out)
    return out


def group_of(groups, monitor):
    for g in groups:
        if monitor in g["monitors"]:
            return g
    return None


def _clamp_pan(v):
    return max(PAN_MIN, min(PAN_MAX, v))


def _clamp_zoom(v):
    return max(ZOOM_MIN, min(ZOOM_MAX, v))


def pan_by(region_cfg, dpx, dpy, img_size, rw, rh):
    """Pan by a drag delta of (dpx, dpy) region-phys px: the image follows the
    cursor, so the center-anchor moves opposite in image space."""
    iw, ih = img_size
    sx, sy = region_scales(region_cfg, iw, ih, rw, rh)
    out = copy.deepcopy(region_cfg)
    px, py = out.get("pan", [0.0, 0.0])
    out["pan"] = [_clamp_pan(px - dpx / (sx * iw)),
                  _clamp_pan(py - dpy / (sy * ih))]
    return out


def zoom_about(region_cfg, factor, anchor_phys, img_size, rw, rh):
    """Zoom by `factor` keeping the image point under `anchor_phys` (region-
    phys coords) stationary."""
    iw, ih = img_size
    ax, ay = anchor_phys
    sx, sy = region_scales(region_cfg, iw, ih, rw, rh)
    out = copy.deepcopy(region_cfg)
    new_zoom = _clamp_zoom(out.get("zoom", 1.0) * factor)
    real_factor = new_zoom / out.get("zoom", 1.0)
    out["zoom"] = new_zoom
    px, py = out.get("pan", [0.0, 0.0])
    au, av = iw * (0.5 + px), ih * (0.5 + py)
    ua = au + (ax - rw / 2) / sx           # image pt under the anchor
    va = av + (ay - rh / 2) / sy
    au2 = ua - (ax - rw / 2) / (sx * real_factor)
    av2 = va - (ay - rh / 2) / (sy * real_factor)
    out["pan"] = [_clamp_pan(au2 / iw - 0.5), _clamp_pan(av2 / ih - 0.5)]
    return out


def snap_pan(region_cfg, img_size, rw, rh, threshold_phys):
    """Snap pan to the centered / edge-flush positions within threshold_phys
    region-phys px. Returns (region_cfg, set of snapped axis names).

    Edge-flush pan for the low edge (image edge on region edge): the anchor
    lands at au = span/(2*scale), i.e. pan = span/(2*scale*size) - 0.5; the
    high edge mirrors it."""
    iw, ih = img_size
    sx, sy = region_scales(region_cfg, iw, ih, rw, rh)
    out = copy.deepcopy(region_cfg)
    pan = list(out.get("pan", [0.0, 0.0]))
    snapped = set()
    for axis, name, span, scale, size in ((0, "x", rw, sx, iw),
                                          (1, "y", rh, sy, ih)):
        flush = span / (2 * scale * size) - 0.5
        candidates = (0.0, flush, -flush)
        thr = threshold_phys / (scale * size)
        best = min(candidates, key=lambda c: abs(pan[axis] - c))
        if 1e-12 < abs(pan[axis] - best) <= thr:
            pan[axis] = best
            snapped.add(name)
    out["pan"] = [_clamp_pan(pan[0]), _clamp_pan(pan[1])]
    return out, snapped


def cycle_mode(region_cfg, step=1):
    """Next/prev fit mode; zoom and pan reset because mode baselines differ."""
    out = copy.deepcopy(region_cfg)
    idx = MODE_RING.index(out.get("mode", "fill"))
    out["mode"] = MODE_RING[(idx + step) % len(MODE_RING)]
    out["zoom"] = 1.0
    out["pan"] = [0.0, 0.0]
    return out


def group_region_phys(mons_by_name, g):
    """(rw, rh) region-phys size for a group given Mon objects by name."""
    members = [mons_by_name[n] for n in g["monitors"] if n in mons_by_name]
    _, _, _, rw, rh = region_phys(members)
    return rw, rh


# ── images added from outside the theme ───────────────────────────────
#
# The editor can pull in an image the theme has never heard of. Those live in
# a plain list under /tmp and are only ever read back, never copied into the
# theme. Sniffing the header rather than trusting the extension keeps a
# renamed text file out of the strip; GdkPixbuf still has the final say in the
# GUI, because a format this recognises is not necessarily one it can decode.

_IMAGE_MAGIC = (
    b"\x89PNG\r\n\x1a\n",       # PNG
    b"\xff\xd8\xff",            # JPEG
    b"GIF87a", b"GIF89a",       # GIF
    b"BM",                      # BMP
    b"II*\x00", b"MM\x00*",     # TIFF
    b"\xff\x0a",                # JPEG XL (raw codestream)
    b"\x00\x00\x00\x0cJXL \r\n\x87\n",  # JPEG XL (container)
    b"qoif",                    # QOI
)
# ISO-BMFF brands at offset 8, after the ftyp box: AVIF and HEIF.
_FTYP_BRANDS = (b"avif", b"avis", b"heic", b"heix", b"heif", b"mif1", b"msf1")


def is_image_file(path):
    """True if the file's header looks like an image format worth offering."""
    try:
        with open(path, "rb") as f:
            head = f.read(32)
    except OSError:
        return False
    if any(head.startswith(sig) for sig in _IMAGE_MAGIC):
        return True
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return True
    if head[4:8] == b"ftyp" and head[8:12] in _FTYP_BRANDS:
        return True
    return False


def merge_extras(existing, candidates, known=()):
    """(kept, rejected) for images added by hand.

    `existing` is the current extras list, `known` everything already in the
    strip (theme images included). Order is preserved and duplicates collapse,
    so re-picking the same file is a no-op rather than a second thumbnail."""
    kept = list(existing)
    seen = set(kept) | set(known)
    rejected = []
    for path in candidates:
        real = os.path.realpath(path)
        if real in seen:
            continue
        if not os.path.isfile(real) or not is_image_file(real):
            rejected.append(path)
            continue
        seen.add(real)
        kept.append(real)
    return kept, rejected


def extras_in_use(shown, extras):
    """Added images that are on a screen right now.

    `shown` is {monitor: image} for what will be on the screens once the
    editor exits. Anything here is invisible to the per-workspace map, so
    confirming has to freeze it rather than let the map paint over it on the
    next workspace switch."""
    known = set(extras)
    return sorted({img for img in shown.values() if img in known})


def arrangement(mon_names, mon_image, live_state):
    """{monitor: image} for what confirming should leave on screen: whatever
    the per-workspace map says, overridden by what live-apply painted."""
    out = dict(mon_image)
    out.update(live_state)
    return {name: out[name] for name in mon_names if out.get(name)}


def apply_commands(dirty, engine, ws_bg_script, locking):
    """The commands the caller runs after the editor exits.

    Locking replaces the usual repaint: `apply-all` would redraw every monitor
    from the per-workspace map, which is exactly what must not happen when an
    added image is on screen."""
    cmds = [f'python3 {engine} render "{image}"' for image in sorted(dirty)]
    if locking:
        cmds.append(f"{ws_bg_script} lock")
        cmds.append(f"{ws_bg_script} paint-arrangement")
    elif dirty:
        cmds.append(f"{ws_bg_script} apply-all")
    return cmds


def regroup(groups, live_names):
    """Groups reshaped for a changed set of live monitors.

    Members that are gone drop out and a group left empty disappears; a monitor
    that has arrived joins as its own default group. Placement of the groups
    that survive is untouched, because unplugging a second screen is not a
    reason to forget how the first one was framed."""
    out, seen = [], set()
    live = list(live_names)
    for g in groups:
        members = [n for n in g["monitors"] if n in live]
        if not members:
            continue
        out.append({"monitors": members,
                    "region": copy.deepcopy(g.get("region", default_region()))})
        seen.update(members)
    for name in live:
        if name not in seen:
            out.append({"monitors": [name], "region": default_region()})
    return out
