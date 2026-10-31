"""Native pages beyond the first five screens.

Each page is a module in this package that defines:
  TITLE     sidebar and page title
  SUBTITLE  one line under the title
  render(manager, content)  packs the page's widgets into the Gtk.Box `content`;
            use manager.client for API calls (through manager.work, never on the GTK thread)
List the module in PAGES below, in sidebar order, and in config/shipped-scripts.txt.
"""
from importlib import import_module

PAGES = ("create", "containers", "storage", "network", "disks")


def load():
    """Return the page modules in sidebar order."""
    return [import_module("." + name, __name__) for name in PAGES]
