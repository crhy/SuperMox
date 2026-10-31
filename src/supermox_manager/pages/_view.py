"""Shared view helpers for Manager pages that fetch data on demand.

These pages show a table per tab, filled in after an operation finishes off
the GTK thread. A reply only paints into the page that is currently open, so
navigating away mid-flight never draws into a destroyed widget. Selection is
by double-click (row-activated), mirroring the Permissions page.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk


def clear(box):
    for child in box.get_children():
        box.remove(child)
        child.destroy()


def table(box, columns, rows, select=None):
    """Build a tree view and pack it into a tab's results box (GTK thread)."""
    model = Gtk.ListStore(*([str] * len(columns)))
    for row in rows:
        model.append([str(v) for v in row])
    tree = Gtk.TreeView(model=model)
    tree.set_headers_visible(True)
    for index, name in enumerate(columns):
        renderer = Gtk.CellRendererText()
        renderer.set_property("ypad", 10)
        renderer.set_property("xpad", 8)
        column = Gtk.TreeViewColumn(name, renderer, text=index)
        column.set_expand(True)
        tree.append_column(column)
    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    scroll.add(tree)
    box.pack_start(scroll, True, True, 0)
    if select:
        tree.connect("row-activated", select)
    return tree


def results(manager, store, name):
    """Return the live results box for a tab, or None if the page was redrawn."""
    box = getattr(manager, store, {}).get(name)
    if box is None:
        return None
    try:
        if box.get_parent() is None:
            return None
    except Exception:
        return None
    return box


def deliver(manager, store, title, name, builder):
    """Wrap a table builder so it only paints into the current page."""
    def show(rows):
        if manager.current != title:
            return
        box = results(manager, store, name)
        if box is None:
            return
        clear(box)
        builder(manager, box, rows)
        box.show_all()
    return show


def selected(manager, attr, what, tab):
    found = getattr(manager, attr, None)
    if not found:
        manager.message("Select a {} first".format(what),
                        "Open the {} tab and double-click the {} you want to change."
                        .format(tab, what))
    return found
