"""Optional GTK smoke check: xvfb-run -a python3 tests/gui-manager.py."""
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
(ROOT / "build").mkdir(exist_ok=True)
preferences = tempfile.TemporaryDirectory(prefix="manager-gui-", dir=ROOT / "build")
os.environ["XDG_CONFIG_HOME"] = preferences.name
sys.path.insert(0, str(ROOT / "src"))

from supermox_manager.app import Manager, GLib, Gtk
from gi.repository import Gdk

errors = []


def failed(kind, error, traceback):
    errors.append(error)
    sys.__excepthook__(kind, error, traceback)
    Gtk.main_quit()


sys.excepthook = failed
manager = Manager("https://127.0.0.1:8006/", demo=True)


def descendants(widget):
    yield widget
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            yield from descendants(child)


def check():
    if manager.busy:
        return True
    assert manager.resources, "Preview never loaded"
    for page in ("Machines", "Nodes", "Storage", "Full management", "Overview"):
        manager.navigate(None, page)
        assert manager.current == page
        assert manager.nav[page].get_active()
    manager.navigate(None, "Machines")
    tree = next(w for w in descendants(manager.content) if isinstance(w, Gtk.TreeView))
    tree.get_selection().select_path(Gtk.TreePath.new_from_string("0"))
    assert manager.selected is not None
    assert all(w.get_sensitive() for w in manager.action_buttons)
    selected_id = str(manager.selected["vmid"])
    search = next(w for w in descendants(manager.content) if isinstance(w, Gtk.SearchEntry))
    search.set_text(selected_id)
    search.emit("search-changed")
    assert len(tree.get_model()) == 1
    tree.get_selection().select_path(Gtk.TreePath.new_from_string("0"))
    assert str(manager.selected["vmid"]) == selected_id
    search.set_text("no matching machine")
    search.emit("search-changed")
    assert len(tree.get_model()) == 0
    assert manager.selected is None
    assert not any(w.get_sensitive() for w in manager.action_buttons)
    manager.navigate(None, "Tasks")
    GLib.timeout_add(100, finish)
    return False


def finish():
    if manager.busy:
        return True
    assert manager.current == "Tasks"
    manager.navigate(None, "Overview")
    GLib.timeout_add(250, screenshot)
    return False


def screenshot():
    pix = Gdk.pixbuf_get_from_window(manager.window.get_window(), 0, 0, *manager.window.get_size())
    pix.savev(str(ROOT / "build/supermox-manager-preview.png"), "png", [], [])
    manager.window.destroy()
    return False


def timeout():
    errors.append(RuntimeError("GUI smoke check timed out"))
    Gtk.main_quit()
    return False


GLib.timeout_add(150, check)
GLib.timeout_add_seconds(15, timeout)
try:
    Gtk.main()
finally:
    if not manager.closed:
        manager.window.destroy()
    preferences.cleanup()
if errors:
    raise SystemExit(1)
print("Native Manager GUI checks passed.")
