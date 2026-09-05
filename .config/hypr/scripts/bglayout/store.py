"""Layout and preset persistence for the background layout engine.

Per-image sidecars: ~/.config/omarchy/background-layouts/images/<basename>.<sha1_12>.json
  (sha1 of the image's realpath, so the symlinked current/theme path and the
   real theme path collapse to one sidecar — "per-image memory")
Presets:            ~/.config/omarchy/background-layouts/presets.json
  (image-agnostic: a preset is just a regions list + optional letterbox)

All writes are atomic (tmp + rename). Validation raises LayoutError with a
human-readable message; unknown keys are preserved on round-trip.
"""

import hashlib
import json
import os
import re
import tempfile

from .geometry import FALLBACKS, MODES

STORE_DIR = os.path.expanduser("~/.config/omarchy/background-layouts")
IMAGES_DIR = os.path.join(STORE_DIR, "images")
PRESETS_FILE = os.path.join(STORE_DIR, "presets.json")

# omarchy copies the active theme into CURRENT_THEME_DIR, so the same file
# path exists across themes. Sidecar identity substitutes the theme name so
# ethereal-extended's 00.jpg and another theme's 00.jpg key separately.
CURRENT_THEME_DIR = os.path.expanduser("~/.config/omarchy/current/theme")
THEME_NAME_FILE = os.path.expanduser("~/.config/omarchy/current/theme.name")
THEME_SOURCE_DIRS = (
    os.path.expanduser("~/.config/omarchy/themes"),
    os.path.expanduser("~/.local/share/omarchy/themes"),
)

ZOOM_MIN, ZOOM_MAX = 0.05, 10.0
PAN_MIN, PAN_MAX = -1.5, 1.5


class LayoutError(ValueError):
    pass


def _current_theme_name():
    try:
        with open(THEME_NAME_FILE) as f:
            return f.read().strip() or None
    except OSError:
        return None


def _canonical_identity(path):
    """Theme-aware identity string hashed into the sidecar key.

    current/theme/<rel>            -> theme:<active-theme-name>:<rel>
    <theme-source-dir>/<name>/<rel> -> theme:<name>:<rel>
    anything else                  -> its realpath

    So a theme's copied path and its source path collapse to one sidecar,
    while same-named files in different themes stay distinct."""
    real = os.path.realpath(path)
    cur = os.path.realpath(CURRENT_THEME_DIR)
    if real.startswith(cur + os.sep):
        name = _current_theme_name()
        if name:
            return f"theme:{name}:{real[len(cur) + 1:]}"
    for base in THEME_SOURCE_DIRS:
        b = os.path.realpath(base)
        if real.startswith(b + os.sep):
            return "theme:" + real[len(b) + 1:].replace(os.sep, ":", 1)
    return real


def image_key(path):
    identity = _canonical_identity(path)
    digest = hashlib.sha1(identity.encode()).hexdigest()[:12]
    return f"{os.path.basename(os.path.realpath(path))}.{digest}"


def sidecar_path(image_path):
    return os.path.join(IMAGES_DIR, image_key(image_path) + ".json")


def validate_regions(regions):
    if not isinstance(regions, list) or not regions:
        raise LayoutError("regions must be a non-empty list")
    seen = set()
    for i, r in enumerate(regions):
        where = f"regions[{i}]"
        mons = r.get("monitors")
        if not isinstance(mons, list) or not mons or \
                not all(isinstance(n, str) and n for n in mons):
            raise LayoutError(f"{where}: monitors must be a non-empty string list")
        overlap = seen.intersection(mons)
        if overlap:
            raise LayoutError(f"{where}: monitors {sorted(overlap)} appear in "
                              "more than one region")
        if len(set(mons)) != len(mons):
            raise LayoutError(f"{where}: duplicate monitor within region")
        seen.update(mons)
        mode = r.get("mode", "fill")
        if mode not in MODES:
            raise LayoutError(f"{where}: unknown mode {mode!r}")
        zoom = r.get("zoom", 1.0)
        if not isinstance(zoom, (int, float)) or not \
                (ZOOM_MIN <= zoom <= ZOOM_MAX):
            raise LayoutError(f"{where}: zoom must be in "
                              f"[{ZOOM_MIN}, {ZOOM_MAX}], got {zoom!r}")
        pan = r.get("pan", [0.0, 0.0])
        if (not isinstance(pan, (list, tuple)) or len(pan) != 2 or
                not all(isinstance(c, (int, float)) and
                        PAN_MIN <= c <= PAN_MAX for c in pan)):
            raise LayoutError(f"{where}: pan must be two numbers in "
                              f"[{PAN_MIN}, {PAN_MAX}], got {pan!r}")
        fallback = r.get("fallback", "fill")
        if fallback not in FALLBACKS:
            raise LayoutError(f"{where}: unknown fallback {fallback!r}")


def validate_layout(layout):
    if not isinstance(layout, dict):
        raise LayoutError("layout must be an object")
    if layout.get("version", 1) != 1:
        raise LayoutError(f"unsupported version {layout.get('version')!r}")
    lb = layout.get("letterbox", "#000000")
    if not (isinstance(lb, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", lb)):
        raise LayoutError(f"letterbox must be #rrggbb, got {lb!r}")
    validate_regions(layout["regions"] if "regions" in layout else None)


def _atomic_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.rename(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def load_layout(image_path):
    """Validated layout dict for an image, or None if absent. Raises
    LayoutError on a malformed sidecar (callers treat that as no layout but
    should surface the message)."""
    path = sidecar_path(image_path)
    if not os.path.isfile(path):
        return None
    try:
        with open(path) as f:
            layout = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise LayoutError(f"unreadable sidecar {path}: {e}") from e
    validate_layout(layout)
    return layout


def save_layout(image_path, layout):
    validate_layout(layout)
    layout = dict(layout)
    layout["version"] = 1
    layout["image"] = os.path.realpath(image_path)
    _atomic_write(sidecar_path(image_path), layout)
    return sidecar_path(image_path)


def delete_layout(image_path):
    try:
        os.unlink(sidecar_path(image_path))
        return True
    except FileNotFoundError:
        return False


def list_sidecars():
    """[(sidecar_path, layout_dict)] for every readable, valid sidecar."""
    out = []
    if not os.path.isdir(IMAGES_DIR):
        return out
    for name in sorted(os.listdir(IMAGES_DIR)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(IMAGES_DIR, name)
        try:
            with open(path) as f:
                layout = json.load(f)
            validate_layout(layout)
        except (OSError, json.JSONDecodeError, LayoutError):
            continue
        out.append((path, layout))
    return out


def load_presets():
    if not os.path.isfile(PRESETS_FILE):
        return {"version": 1, "presets": {}}
    try:
        with open(PRESETS_FILE) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise LayoutError(f"unreadable presets file: {e}") from e
    if not isinstance(data.get("presets"), dict):
        raise LayoutError("presets.json: 'presets' must be an object")
    return data


def save_presets(data):
    for name, preset in data.get("presets", {}).items():
        validate_regions(preset.get("regions"))
    _atomic_write(PRESETS_FILE, data)


def save_preset(name, layout):
    """Copy a layout's regions (+letterbox) into presets.json under `name`."""
    validate_layout(layout)
    data = load_presets()
    preset = {"regions": json.loads(json.dumps(layout["regions"]))}
    if "letterbox" in layout:
        preset["letterbox"] = layout["letterbox"]
    data["presets"][name] = preset
    save_presets(data)


def apply_preset(name, image_path):
    """Build (and save) a layout for image_path from a named preset.
    Pure region copy — presets are image-agnostic."""
    data = load_presets()
    if name not in data["presets"]:
        raise LayoutError(f"no preset named {name!r}")
    preset = data["presets"][name]
    layout = {"version": 1, "image": os.path.realpath(image_path),
              "regions": json.loads(json.dumps(preset["regions"]))}
    if "letterbox" in preset:
        layout["letterbox"] = preset["letterbox"]
    save_layout(image_path, layout)
    return layout
