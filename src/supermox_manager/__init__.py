"""SuperMox Manager: the local desktop app in front of the web interface.

`app.py` is the GTK 3 + WebKitGTK window (docs/ui-and-branding.md, "SuperMox
Manager"); `logic.py` is everything the window decides, kept free of GTK so
the tests (tests/py/test_manager_pin.py) can exercise it headless.
"""
