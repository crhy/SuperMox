"""Pure-Python API operations for SuperMox Manager.

One module per feature. No GTK here: pages call these and the live tests call
the same functions, so a feature is proven against the real server, not only
against a fake. Every call goes through the client's request(), which pins TLS.
"""
