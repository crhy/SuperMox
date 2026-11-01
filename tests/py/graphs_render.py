"""Renders the graphs page for real: cairo pixels and GTK widgets.

This runs under a display (see test_manager_graphs.py, which starts it under
xvfb-run). It lives in its own file because importing GTK or cairo in the
test process would break test_manager_pin.py, which proves the security code
stays importable on a host with no GUI at all.
"""

import os
import sys
import unittest

import gi

import cairo

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))

from supermox_manager.ops import metrics
from supermox_manager.pages import graphs

BUILD = os.path.join(os.path.dirname(__file__), "..", "..", "build")


class Area:
    """Stands in for the DrawingArea GTK hands to the draw signal."""

    def __init__(self, width, height):
        self.width, self.height = width, height

    def get_allocated_width(self):
        return self.width

    def get_allocated_height(self):
        return self.height


def render(chart, width=620, height=210):
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    chart._draw(Area(width, height), cairo.Context(surface))
    return surface


def painted(surface):
    """(non-transparent pixels, distinct colours) of the rendered surface."""
    data, stride = surface.get_data(), surface.get_stride()
    seen, count = set(), 0
    for y in range(surface.get_height()):
        row = data[y * stride:y * stride + surface.get_width() * 4]
        for x in range(surface.get_width()):
            pixel = bytes(row[x * 4:x * 4 + 4])
            if pixel != b"\x00\x00\x00\x00":
                count += 1
                seen.add(pixel)
    return count, len(seen)


def fill(chart, rows, fields, names, kind, start=None, end=None):
    """Hand the chart what graphs_box would hand it."""
    points = [metrics.series(rows, field) for field in fields]
    values = [value for series in points for _when, value in series]
    peak = max([abs(value) for value in values] + [0.0])
    lines, unit = [], ""
    for name, series in zip(names, points):
        if not series:
            continue
        scaled, unit = metrics.scale([v for _when, v in series], kind, peak=peak)
        lines.append((name, list(zip([when for when, _v in series], scaled))))
    chart.set_data(lines, unit,
                   start if start is not None else (rows[0]["time"] if rows else None),
                   end if end is not None else (rows[-1]["time"] if rows else None))
    return lines


def node_rows(count=60, gap=False):
    gib = 1024 ** 3
    rows = []
    for i in range(count):
        sampled = not (gap and i % 7)
        rows.append({"time": 1793541120 + 60 * i,
                     "cpu": 0.004 + 0.0001 * i if sampled else None,
                     "iowait": 0.001 if sampled else None,
                     "memtotal": 2 * gib, "memused": 1.4 * gib,
                     "netin": 107.8, "netout": 139.4,
                     "roottotal": 19.5 * gib, "rootused": 6.06 * gib})
    return rows


class Theme(unittest.TestCase):
    def test_colours_come_from_the_app_stylesheet(self):
        theme = graphs._theme()
        self.assertEqual(theme["accent"], "#35d8b0")   # .brand
        self.assertEqual(theme["ink"], "#eef5ef")      # .window, dialog
        self.assertEqual(theme["panel"], "#0d323a")    # treeview
        self.assertEqual(theme["grid"], "#24474c")     # .sidebar border

    def test_rgb_conversion(self):
        self.assertEqual(graphs._rgb("#35d8b0"),
                         (0x35 / 255, 0xd8 / 255, 0xb0 / 255))

    def test_axis_labels_are_never_scientific(self):
        self.assertEqual(graphs._number(0), "0")
        self.assertEqual(graphs._number(0.004), "0")
        self.assertEqual(graphs._number(19.5), "19.5")
        self.assertEqual(graphs._number(2064.0), "2064")

    def test_time_labels_follow_the_window(self):
        self.assertIn(":", graphs._clock(1793541120, 3600))
        self.assertIn(" ", graphs._clock(1793541120, 7 * 86400))
        self.assertIn(" ", graphs._clock(1793541120, 400 * 86400))


class Chart(unittest.TestCase):
    def test_a_real_series_is_painted(self):
        chart = graphs.Chart("CPU usage")
        rows = node_rows()
        lines = fill(chart, rows, ("cpu", "iowait"), ("CPU", "IO delay"), "percent")
        self.assertEqual(len(lines), 2)
        self.assertEqual([name for name, _pts in lines], ["CPU", "IO delay"])
        surface = render(chart)
        count, colours = painted(surface)
        self.assertGreater(count, 1000, "the panel and the line must be on it")
        self.assertGreater(colours, 8, "title, legend, axes, fill and line")
        os.makedirs(BUILD, exist_ok=True)
        surface.write_to_png(os.path.join(BUILD, "unit-chart.png"))

    def test_two_series_share_one_unit(self):
        chart = graphs.Chart("Memory usage")
        rows = node_rows()
        lines = fill(chart, rows, ("memtotal", "memused"), ("Total", "Used"), "bytes")
        self.assertEqual(chart.unit, "GiB")
        for _name, points in lines:
            self.assertLess(max(abs(v) for _t, v in points), 64)

    def test_a_gap_stays_a_gap(self):
        chart = graphs.Chart("Disk IO")
        rows = [{"time": 1793541120 + 60 * i,
                 "diskread": 4096.0 if i % 7 else None,
                 "diskwrite": 8192.0 if i % 7 else None} for i in range(40)]
        lines = fill(chart, rows, ("diskread", "diskwrite"), ("Reads", "Writes"), "rate")
        self.assertEqual(chart.unit, "KiB/s")
        self.assertEqual(len(lines[0][1]), 34)
        surface = render(chart)
        count, _colours = painted(surface)
        self.assertGreater(count, 1000)

    def test_an_empty_window_says_so_without_crashing(self):
        chart = graphs.Chart("Network traffic")
        rows = [{"time": 1793541120 + 60 * i} for i in range(60)]
        self.assertEqual(fill(chart, rows, ("netin", "netout"),
                              ("Incoming", "Outgoing"), "rate"), [])
        surface = render(chart)
        count, colours = painted(surface)
        self.assertGreater(count, 1000)
        self.assertGreaterEqual(colours, 3)

    def test_one_sample_becomes_a_dot(self):
        chart = graphs.Chart("Storage usage")
        rows = [{"time": 1793541120, "total": 19.5 * 1024 ** 3, "used": 6.06 * 1024 ** 3}]
        fill(chart, rows, ("total", "used"), ("Capacity", "Used"), "bytes")
        surface = render(chart)
        count, _colours = painted(surface)
        self.assertGreater(count, 1000)

    def test_a_tiny_box_is_ignored_rather_than_mangled(self):
        chart = graphs.Chart("CPU usage")
        fill(chart, node_rows(), ("cpu",), ("CPU",), "percent")
        surface = render(chart, 40, 30)
        self.assertEqual(painted(surface), (0, 0))


class Stub:
    """A Manager that runs the operation inline: no thread, no network."""

    def __init__(self, rows, current="Node"):
        self.current = current
        self.calls = []
        self.client = self
        self.rows = rows

    def request(self, method, path, params=None):
        self.calls.append((path, params))
        return self.rows

    def work(self, operation, done):
        done(operation())


class Deferred(Stub):
    """A Manager whose reply lands later, the way a real one does."""

    def work(self, operation, done):
        self.pending = (operation, done)

    def land(self):
        operation, done = self.pending
        self.calls.append(("landed", None))
        done(operation())



def walk(widget):
    yield widget
    for child in (widget.get_children() if hasattr(widget, "get_children") else []):
        for item in walk(child):
            yield item


class Box(unittest.TestCase):
    def test_it_holds_a_timeframe_picker_and_one_chart_per_metric(self):
        manager = Stub(node_rows())
        box = graphs.graphs_box(manager, "supermox", owner="Node")
        charts = [w for w in walk(box) if isinstance(w, graphs.Chart)]
        pickers = [w for w in walk(box) if isinstance(w, Gtk.ComboBoxText)]
        self.assertEqual(len(charts), len(metrics.charts_for("node")))
        self.assertEqual(len(pickers), 1)
        self.assertEqual(pickers[0].get_active(), 0)

    def test_the_fetch_goes_through_work_and_paints_the_charts(self):
        manager = Stub(node_rows())
        box = graphs.graphs_box(manager, "supermox", owner="Node")
        self.assertEqual(len(manager.calls), 1)
        path, params = manager.calls[0]
        self.assertEqual(path, "/nodes/supermox/rrddata")
        self.assertEqual(params, {"timeframe": "hour", "cf": "AVERAGE"})
        charts = [w for w in walk(box) if isinstance(w, graphs.Chart)]
        self.assertTrue(charts[0].lines, "the reply filled the first chart")
        self.assertEqual(charts[0].unit, "%")

    def test_a_reply_for_another_page_is_dropped(self):
        manager = Stub(node_rows(), current="Tasks")
        box = graphs.graphs_box(manager, "supermox", owner="Node")
        charts = [w for w in walk(box) if isinstance(w, graphs.Chart)]
        self.assertEqual([chart.lines for chart in charts], [[]] * len(charts))

    def test_a_reply_that_lands_after_the_box_left_is_ignored(self):
        manager = Deferred(node_rows())
        page = Gtk.Box()
        box = graphs.graphs_box(manager, "supermox", owner="Node")
        page.pack_start(box, True, True, 0)
        manager.land()
        charts = [w for w in walk(box) if isinstance(w, graphs.Chart)]
        self.assertTrue(charts[0].lines, "the first reply painted")
        page.remove(box)                       # the page moved on
        manager.rows = []                      # a reply that would blank them
        picker = [w for w in walk(box) if isinstance(w, Gtk.ComboBoxText)][0]
        picker.set_active(1)
        manager.land()
        self.assertTrue(charts[0].lines, "the late reply was dropped")

    def test_changing_the_timeframe_refetches(self):
        manager = Stub(node_rows())
        box = graphs.graphs_box(manager, "supermox", owner="Node")
        picker = [w for w in walk(box) if isinstance(w, Gtk.ComboBoxText)][0]
        picker.set_active(1)
        self.assertEqual(len(manager.calls), 2)
        self.assertEqual(manager.calls[1][1]["timeframe"], "day")

    def test_a_box_without_a_selection_fetches_nothing(self):
        manager = Stub(node_rows())
        picked = [None]
        box = graphs.graphs_box(manager, owner="Machines", pick=lambda: picked[0])
        self.assertEqual(manager.calls, [])
        charts = [w for w in walk(box) if isinstance(w, graphs.Chart)]
        self.assertEqual([chart.lines for chart in charts], [[]] * len(charts))

    def test_selecting_a_machine_points_the_box_at_its_node(self):
        manager = Stub(node_rows())
        picked = [None]
        box = graphs.graphs_box(manager, owner="Machines", pick=lambda: picked[0])
        picked[0] = ("orbit", "lxc", 101, None)
        box.reload()
        path, params = manager.calls[0]
        self.assertEqual(path, "/nodes/orbit/lxc/101/rrddata")

    def test_a_guest_box_asks_for_its_own_endpoint(self):
        manager = Stub([{"time": 1793541120, "maxcpu": 4, "maxmem": 512 * 1024 ** 2}])
        box = graphs.graphs_box(manager, "supermox", kind="qemu", vmid=9950,
                                owner="Machines")
        path, params = manager.calls[0]
        self.assertEqual(path, "/nodes/supermox/qemu/9950/rrddata")
        self.assertEqual(params["timeframe"], "hour")
        charts = [w for w in walk(box) if isinstance(w, graphs.Chart)]
        self.assertEqual(len(charts), len(metrics.charts_for("qemu")))


if __name__ == "__main__":
    unittest.main()
