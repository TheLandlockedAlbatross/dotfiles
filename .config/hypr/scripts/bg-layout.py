#!/usr/bin/env python3
"""Background layout engine CLI.

Slices live in /tmp/hypr-bg-layout (never touching original images); layouts
persist in ~/.config/omarchy/background-layouts/. See bglayout/ for the guts.

  bg-layout.py render-all                      re-render everything needed, rewrite index
  bg-layout.py render <image>                  re-render one image, merge index
  bg-layout.py get-layout <image>              -> {"layout":..|null,"error":..,"image":{w,h},"monitors":[..]}
  bg-layout.py set-layout <image> [--repaint]  layout JSON on stdin -> save + render (+ repaint)
  bg-layout.py delete-layout <image> [--repaint]
  bg-layout.py apply-preset <name> <image> [--repaint]
  bg-layout.py save-preset <name> <image>
  bg-layout.py list-presets                    -> presets JSON
  bg-layout.py compute <image>                 -> per-monitor crop specs (debug)
"""

import argparse
import dataclasses
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bglayout import render, store  # noqa: E402
from bglayout.geometry import compute_slices  # noqa: E402

WS_BG_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "workspace-backgrounds.sh")
TOGGLE_FILE = os.path.expanduser(
    "~/.local/state/omarchy/toggles/workspace-backgrounds")


def repaint():
    if os.path.isfile(TOGGLE_FILE):
        subprocess.run([WS_BG_SCRIPT, "apply-all"], check=False, timeout=30)


def image_size(path):
    from PIL import Image
    with Image.open(os.path.realpath(path)) as img:
        return img.size


def cmd_get_layout(args):
    result = {"layout": None, "error": None}
    try:
        result["layout"] = store.load_layout(args.image)
    except store.LayoutError as e:
        result["error"] = str(e)
    w, h = image_size(args.image)
    result["image"] = {"path": args.image, "w": w, "h": h}
    result["monitors"] = [dataclasses.asdict(m) for m in render.live_monitors()]
    print(json.dumps(result, indent=2))


def cmd_set_layout(args):
    layout = json.load(sys.stdin)
    store.save_layout(args.image, layout)
    render.render_images([args.image])
    if args.repaint:
        repaint()


def cmd_delete_layout(args):
    store.delete_layout(args.image)
    render.render_images([args.image])  # drops its index rows
    if args.repaint:
        repaint()


def cmd_apply_preset(args):
    store.apply_preset(args.name, args.image)
    render.render_images([args.image])
    if args.repaint:
        repaint()


def cmd_compute(args):
    layout = store.load_layout(args.image)
    if layout is None:
        print(json.dumps({}))
        return
    slices = compute_slices(layout, render.live_monitors(),
                            image_size(args.image))
    print(json.dumps({
        mon: {"span": dataclasses.asdict(span),
              "solo": dataclasses.asdict(solo) if solo else None}
        for mon, (span, solo) in sorted(slices.items())
    }, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("render-all")
    sp = sub.add_parser("render")
    sp.add_argument("image")
    sp = sub.add_parser("get-layout")
    sp.add_argument("image")
    for name in ("set-layout", "delete-layout"):
        sp = sub.add_parser(name)
        sp.add_argument("image")
        sp.add_argument("--repaint", action="store_true")
    sp = sub.add_parser("apply-preset")
    sp.add_argument("name")
    sp.add_argument("image")
    sp.add_argument("--repaint", action="store_true")
    sp = sub.add_parser("save-preset")
    sp.add_argument("name")
    sp.add_argument("image")
    sub.add_parser("list-presets")
    sp = sub.add_parser("compute")
    sp.add_argument("image")

    args = p.parse_args()
    try:
        if args.cmd == "render-all":
            render.render_all()
        elif args.cmd == "render":
            render.render_images([args.image])
        elif args.cmd == "get-layout":
            cmd_get_layout(args)
        elif args.cmd == "set-layout":
            cmd_set_layout(args)
        elif args.cmd == "delete-layout":
            cmd_delete_layout(args)
        elif args.cmd == "apply-preset":
            cmd_apply_preset(args)
        elif args.cmd == "save-preset":
            layout = store.load_layout(args.image)
            if layout is None:
                sys.exit(f"no layout saved for {args.image}")
            store.save_preset(args.name, layout)
        elif args.cmd == "list-presets":
            print(json.dumps(store.load_presets(), indent=2))
        elif args.cmd == "compute":
            cmd_compute(args)
    except store.LayoutError as e:
        sys.exit(f"bg-layout: {e}")


if __name__ == "__main__":
    main()
