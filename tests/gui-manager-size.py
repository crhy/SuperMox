"""Headless size check: every Manager page must fit a small laptop screen.

Run by the gate the same way tests/gui-manager.py is:
    timeout 120 xvfb-run -a python3 tests/gui-manager-size.py
"""
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
(ROOT / "build").mkdir(exist_ok=True)
preferences = tempfile.TemporaryDirectory(prefix="manager-size-", dir=ROOT / "build")
os.environ["XDG_CONFIG_HOME"] = preferences.name
sys.path.insert(0, str(ROOT / "src"))

from supermox_manager.app import Manager, GLib, Gtk

errors = []
stage = {"i": -1, "pages": [], "alloc": None}


def failed(kind, error, traceback):
    errors.append(error)
    sys.__excepthook__(kind, error, traceback)
    Gtk.main_quit()


sys.excepthook = failed
manager = Manager("https://127.0.0.1:8006/", demo=True)


def step():
    if not manager.resources:
        return True
    if not stage["pages"]:
        stage["pages"] = ["Overview", "Machines", "Nodes", "Storage", "Tasks",
                          *manager.pages, "Full management"]
    if stage["i"] >= 0:
        name = stage["pages"][stage["i"]]
        minimum, natural = manager.window.get_preferred_size()
        alloc = manager.window.get_size()
        print("%-16s min=%dx%d natural=%dx%d alloc=%dx%d" % (
            name, minimum.width, minimum.height, natural.width, natural.height,
            alloc.width, alloc.height))
        assert minimum.width <= 1024, "%s: minimum width %d > 1024" % (name, minimum.width)
        assert minimum.height <= 700, "%s: minimum height %d > 700" % (name, minimum.height)
        if stage["alloc"] is None:
            stage["alloc"] = (alloc.width, alloc.height)
        else:
            assert (alloc.width, alloc.height) == stage["alloc"], (
                "window allocated size changed: %s -> %s" % (stage["alloc"], (alloc.width, alloc.height)))
    stage["i"] += 1
    if stage["i"] >= len(stage["pages"]):
        manager.window.destroy()
        return False
    manager.navigate(None, stage["pages"][stage["i"]])
    return True


def timeout():
    errors.append(RuntimeError("Manager size check timed out"))
    Gtk.main_quit()
    return False


GLib.timeout_add(120, step)
GLib.timeout_add_seconds(60, timeout)
try:
    Gtk.main()
finally:
    if not manager.closed:
        manager.window.destroy()
    preferences.cleanup()
if errors:
    raise SystemExit(1)
print("Manager fits the screen on every page.")
