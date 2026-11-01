#!/usr/bin/env python3
"""GUI proof for the RRD graphs: xvfb-run -a python3 tests/graphs-proof.py

Runs the real Manager in demo mode, opens the node Summary tab, then the
Machines page with a machine selected, waits for the history fetch each time,
and asserts the Chart widgets really hold samples before writing
build/screenshots/manager-graphs.png: both views side by side, so the cairo
drawing is visible in the proof.
"""
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
SHOTS = ROOT / "build" / "screenshots"
SHOTS.mkdir(parents=True, exist_ok=True)
preferences = tempfile.TemporaryDirectory(prefix="graphs-gui-", dir=ROOT / "build")
os.environ["XDG_CONFIG_HOME"] = preferences.name
sys.path.insert(0, str(ROOT / "src"))

import cairo
from supermox_manager.app import Manager, GLib, Gtk
from gi.repository import Gdk
from supermox_manager.ops import metrics
from supermox_manager.pages import graphs

errors = []
manager = Manager("https://127.0.0.1:8006/", demo=True)
shots = []
stage = [0]


def failed(kind, error, traceback):
    errors.append(error)
    sys.__excepthook__(kind, error, traceback)
    Gtk.main_quit()


sys.excepthook = failed


def descendants(widget):
    yield widget
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            yield from descendants(child)


def charts():
    return [w for w in descendants(manager.content) if isinstance(w, graphs.Chart)]


def sample_count(boxes):
    return sum(len(points) for chart in boxes for _name, points in chart.lines)


def shot(name):
    pix = Gdk.pixbuf_get_from_window(manager.window.get_window(), 0, 0,
                                     *manager.window.get_size())
    path = SHOTS / name
    pix.savev(str(path), "png", [], [])
    return path


def step():
    """One state machine: 0 load, 1 node graphs, 2 machines, 3 machine graphs."""
    if manager.busy:
        return True
    if stage[0] == 0:
        if not manager.resources:
            return True
        manager.navigate(None, "Node")
        stage[0] = 1
        return True
    if stage[0] == 1:
        boxes = charts()
        assert boxes, "no Chart widget on the node Summary tab"
        assert len(boxes) == len(metrics.charts_for("node")), \
            "expected one chart per node metric"
        assert all(chart.unit for chart in boxes), "a chart has no display unit"
        assert sample_count(boxes), "the node graphs hold no samples"
        shots.append(("Node Summary tab", shot("graphs-node.png")))
        manager.navigate(None, "Machines")
        stage[0] = 2
        return True
    if stage[0] == 2:
        tree = next(w for w in descendants(manager.content) if isinstance(w, Gtk.TreeView))
        tree.get_selection().select_path(Gtk.TreePath.new_from_string("0"))
        assert manager.selected is not None, "could not select a machine"
        stage[0] = 3
        return True
    if stage[0] == 3:
        boxes = charts()
        assert boxes, "no Chart widget on the Machines page"
        assert len(boxes) == len(metrics.charts_for(manager.selected["type"])), \
            "expected one chart per guest metric"
        assert sample_count(boxes), "the selected machine has no samples"
        shots.append(("Machines", shot("graphs-machines.png")))
        manager.window.destroy()
        return False
    return False


def finish(*_args):
    errors.append(RuntimeError("graphs proof timed out"))
    Gtk.main_quit()


GLib.timeout_add(150, step)
GLib.timeout_add_seconds(30, finish)
try:
    Gtk.main()
finally:
    if not manager.closed:
        manager.window.destroy()
    preferences.cleanup()
if errors:
    raise SystemExit(1)


def compose():
    """Paste both screenshots into one PNG with cairo."""
    images = [(title, cairo.ImageSurface.create_from_png(open(path, "rb")))
              for title, path in shots]
    gap, head = 24, 56
    width = sum(image.get_width() for _t, image in images) + gap * (len(images) + 1)
    height = max(image.get_height() for _t, image in images) + head + gap
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    ctx = cairo.Context(surface)
    ctx.set_source_rgb(0x07 / 255, 0x25 / 255, 0x2c / 255)
    ctx.rectangle(0, 0, width, height)
    ctx.fill()
    ctx.set_source_rgb(0x35 / 255, 0xd8 / 255, 0xb0 / 255)
    ctx.set_font_size(20)
    ctx.move_to(gap, 34)
    ctx.show_text("RRD history drawn with cairo - graphs_box on the node Summary tab and the Machines page")
    x = gap
    for title, image in images:
        ctx.set_source_surface(image, x, head)
        ctx.rectangle(x, head, image.get_width(), image.get_height())
        ctx.paint()
        ctx.set_source_rgb(0xa4 / 255, 0xbc / 255, 0xb9 / 255)
        ctx.set_font_size(14)
        ctx.move_to(x, head - 12)
        ctx.show_text(title)
        x += image.get_width() + gap
    surface.write_to_png(str(SHOTS / "manager-graphs.png"))


compose()
print("Graphs proof written to build/screenshots/manager-graphs.png")
