"""RRD history drawn with cairo: `graphs_box` plus the `Chart` widget.

ops/metrics.py fetches and shapes the archived samples; this module only draws
them. A Chart is a Gtk.DrawingArea: GTK hands the `draw` signal a cairo context
and everything on it is painted with cairo paths and text, never with child
widgets. Colours are read out of the app's own stylesheet (app.CSS) so the
graphs match the theme instead of inventing a palette.

`graphs_box(manager, node, kind, vmid=..., storage=...)` returns the widgets
and starts the fetch through manager.work, so the network work never runs on
the GTK thread. A reply paints only while its own page is still the open one.
"""

import gi
import re

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

import cairo

from ..ops import metrics

# Fallbacks; each one is replaced by the matching colour from app.CSS below.
FALLBACK = {
    "panel": "#0d323a",
    "ink": "#eef5ef",
    "muted": "#a4bcb9",
    "grid": "#24474c",
    "accent": "#35d8b0",
    "amber": "#ffdfa4",
    "extra": "#7fb2c8",
}
HEX = r"(#[0-9a-fA-F]{6})"


def _rule(css, selector):
    """The body of the stylesheet rule whose selector is exactly `selector`."""
    for chunk in css.split("}"):
        head, brace, body = chunk.partition("{")
        if brace and head.strip() == selector:
            return body
    return ""


def _theme():
    """Pick the chart palette out of the app's own stylesheet, once."""
    from ..app import CSS
    css = CSS.decode()
    wanted = (("panel", "treeview", r"background\s*:\s*" + HEX),
              ("ink", ".window, dialog", r"color\s*:\s*" + HEX),
              ("muted", ".subtitle", r"color\s*:\s*" + HEX),
              ("grid", ".sidebar", r"solid\s+" + HEX),
              ("accent", ".brand", r"color\s*:\s*" + HEX),
              ("amber", ".preview", r"color\s*:\s*" + HEX))
    found = dict(FALLBACK)
    for key, selector, pattern in wanted:
        match = re.search(pattern, _rule(css, selector))
        if match:
            found[key] = match.group(1)
    return found


def _rgb(color):
    """'#35d8b0' -> (r, g, b) floats for cairo."""
    digits = color.lstrip("#")
    return tuple(int(digits[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def _number(value):
    """Axis label: enough digits to be useful, never scientific."""
    if abs(value) < 0.01:
        return "0"
    for limit, spec in ((1000, "{:.0f}"), (100, "{:.0f}"), (10, "{:.1f}")):
        if abs(value) >= limit:
            return spec.format(value)
    return "{:.2f}".format(value)


def _clock(seconds, span):
    """Time axis label; the format follows how wide the window is."""
    import time as _time
    if span <= 26 * 3600:
        return _time.strftime("%H:%M", _time.localtime(seconds))
    if span <= 200 * 86400:
        return _time.strftime("%d %b", _time.localtime(seconds))
    return _time.strftime("%b %Y", _time.localtime(seconds))


class Chart(Gtk.DrawingArea):
    """One graph: title, legend, value axis, time axis, one line per field.

    Call `set_data(lines, unit, start, end)` where lines is
    [(series label, [(epoch seconds, value in `unit`), ...])]. Gaps are kept
    as gaps: a series with holes is drawn as separate strokes, never bridged.
    """

    def __init__(self, title):
        super().__init__()
        self.title = title
        self.lines = []
        self.unit = ""
        self.start = self.end = None
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.set_size_request(300, 190)
        self.connect("draw", self._draw)

    def set_data(self, lines, unit, start, end):
        self.lines = lines
        self.unit = unit
        self.start, self.end = start, end
        self.queue_draw()

    def _draw(self, area, ctx):
        width = area.get_allocated_width()
        height = area.get_allocated_height()
        if width < 60 or height < 60:
            return
        colors = _theme()
        ctx.set_source_rgb(*_rgb(colors["panel"]))
        ctx.rectangle(0, 0, width, height)
        ctx.fill()

        left, right = 52.0, float(width - 12)
        top, bottom = 46.0, float(height - 22)
        values = [value for _name, points in self.lines for _when, value in points]
        peak = max([abs(value) for value in values] + [0.0]) or 1.0
        span = (self.end - self.start) if (self.start is not None and
                                           self.end is not None and self.end > self.start) else 0

        ctx.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        ctx.set_font_size(12)
        ctx.set_source_rgb(*_rgb(colors["ink"]))
        ctx.move_to(10, 18)
        ctx.show_text(self.title)
        ctx.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        ctx.set_source_rgb(*_rgb(colors["muted"]))
        note = "peak {} {}".format(_number(peak), self.unit) if values else "no samples"
        extents = ctx.text_extents(note)
        ctx.move_to(right - extents.x_advance, 18)
        ctx.show_text(note)

        x = 12.0
        for index, (name, _points) in enumerate(self.lines):
            ctx.set_source_rgb(*_rgb(_series_color(colors, index)))
            ctx.set_line_width(2.0)
            ctx.move_to(x, 32)
            ctx.line_to(x + 14, 32)
            ctx.stroke()
            ctx.set_source_rgb(*_rgb(colors["ink"]))
            ctx.move_to(x + 19, 36)
            ctx.show_text(name)
            x += 19 + ctx.text_extents(name).x_advance + 14

        ctx.set_line_width(1.0)
        for step in (0.0, 0.5, 1.0):
            y = bottom - (bottom - top) * step
            ctx.set_source_rgb(*_rgb(colors["grid"]))
            ctx.move_to(left, y)
            ctx.line_to(right, y)
            ctx.stroke()
            ctx.set_source_rgb(*_rgb(colors["muted"]))
            text = _number(peak * step)
            extents = ctx.text_extents(text)
            ctx.move_to(left - 6 - extents.x_advance, y + 4)
            ctx.show_text(text)
            if span:
                when = self.start + span * step
                text = _clock(when, span)
                extents = ctx.text_extents(text)
                place = left + (right - left) * step - extents.x_advance / 2
                place = min(max(place, left), right - extents.x_advance)
                ctx.move_to(place, bottom + 15)
                ctx.show_text(text)

        if not values:
            ctx.set_source_rgb(*_rgb(colors["muted"]))
            ctx.move_to(left + 8, (top + bottom) / 2)
            ctx.show_text("Nothing archived in this window")
            return

        for index, (name, points) in enumerate(self.lines):
            color = _series_color(colors, index)
            red, green, blue = _rgb(color)
            if span:
                self._paint_area(ctx, points, left, right, top, bottom, span,
                                 self.start, peak)
                ctx.set_source_rgba(red, green, blue, 0.14)
                ctx.fill()
            else:
                ctx.set_source_rgba(red, green, blue, 0.14)
                ctx.rectangle(self._x(points[0][0], left, right, 1, self.start) - 3,
                              self._y(points[0][1], top, bottom, peak) - 3, 6, 6)
                ctx.fill()
            ctx.set_source_rgb(red, green, blue)
            ctx.set_line_width(1.8)
            ctx.set_line_join(cairo.LINE_JOIN_ROUND)
            self._paint_line(ctx, points, left, right, top, bottom, span,
                             self.start, peak)
            ctx.stroke()
            if len(points) == 1:
                when, value = points[0]
                ctx.arc(self._x(when, left, right, span, self.start),
                        self._y(value, top, bottom, peak), 2.4, 0, 6.3)
                ctx.fill()

    def _x(self, when, left, right, span, start):
        """A window with no width puts every sample in the middle."""
        if span <= 0:
            return left + (right - left) / 2
        return left + (right - left) * (when - start) / span

    def _y(self, value, top, bottom, peak):
        return bottom - (bottom - top) * (value / peak)

    def _paint_area(self, ctx, points, left, right, top, bottom, span, start, peak):
        """Fill between the line and the baseline."""
        first, last = points[0], points[-1]
        ctx.new_sub_path()
        ctx.move_to(self._x(first[0], left, right, span, start), bottom)
        for when, value in points:
            ctx.line_to(self._x(when, left, right, span, start),
                        self._y(value, top, bottom, peak))
        ctx.line_to(self._x(last[0], left, right, span, start), bottom)
        ctx.close_path()

    def _paint_line(self, ctx, points, left, right, top, bottom, span, start, peak):
        """Stroke the series, breaking the path where the archive has a gap."""
        gaps = [points[index][0] - points[index - 1][0]
                for index in range(1, len(points))]
        gap = sorted(gaps)[len(gaps) // 2] if gaps else 0
        ctx.new_sub_path()
        for index, (when, value) in enumerate(points):
            x = self._x(when, left, right, span, start)
            y = self._y(value, top, bottom, peak)
            if index == 0 or (gaps and when - points[index - 1][0] > gap * 2.5):
                ctx.move_to(x, y)
            else:
                ctx.line_to(x, y)


def _series_color(colors, index):
    """Series colours, taken from the theme where the stylesheet has them."""
    order = ("accent", "amber", "muted", "extra")
    return colors[order[index % len(order)]]


def graphs_box(manager, node=None, kind=None, vmid=None, storage=None, owner="Node",
               pick=None):
    """A timeframe combo plus one Chart per metric, filled in off-thread.

    `owner` is the title of the page that hosts the box: a reply paints only
    while that page is still open, and only while the box has not been taken
    off the page. `pick`, when given, is called for every fetch and returns
    (node, kind, vmid, storage) for whatever is selected where the box lives,
    or None when nothing is selected yet.
    """
    from ..app import label
    definitions = metrics.charts_for(kind)
    allowed = metrics.NODE_TIMEFRAMES if kind in (None, "node") else metrics.TIMEFRAMES

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
    box.set_hexpand(True)
    box.set_vexpand(True)

    picker = Gtk.ComboBoxText()
    for name in allowed:
        picker.append_text(name)
    picker.set_active(0)
    controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    controls.pack_start(label("History window"), False, False, 0)
    controls.pack_start(picker, False, False, 0)
    box.pack_start(controls, False, False, 0)

    charts = [Chart(title) for title, _fields, _names, _scale in definitions]
    for start in range(0, len(charts), 2):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        for chart in charts[start:start + 2]:
            row.pack_start(chart, True, True, 0)
        box.pack_start(row, True, True, 0)

    def timeframe():
        index = picker.get_active()
        return allowed[index] if 0 <= index < len(allowed) else allowed[0]

    mounted = [False]

    def show(rows):
        if manager.current != owner:
            return
        if box.get_parent() is not None:
            mounted[0] = True
        elif mounted[0]:
            return          # it was on a page and has since been taken away
        for chart, (title, fields, names, scale_kind) in zip(charts, definitions):
            points = [metrics.series(rows, field) for field in fields]
            values = [value for series in points for _when, value in series]
            peak = max([abs(value) for value in values] + [0.0])
            lines = []
            unit = ""
            for name, series in zip(names, points):
                if not series:
                    continue
                scaled, unit = metrics.scale([value for _when, value in series],
                                             scale_kind, peak=peak)
                lines.append((name, list(zip([when for when, _value in series], scaled))))
            first = rows[0].get("time") if rows else None
            last = rows[-1].get("time") if rows else None
            chart.set_data(lines, unit, first, last)
        box.show_all()

    def load():
        window = timeframe()
        target = pick() if pick else (node, kind, vmid, storage)
        if target is None:
            show([])
            return
        target_node, target_kind, target_vmid, target_storage = target
        manager.work(lambda: metrics.rrd(manager.client, target_node, kind=target_kind,
                                        vmid=target_vmid, storage=target_storage,
                                        timeframe=window),
                     lambda rows: show(rows))

    picker.connect("changed", lambda *_: load())
    load()
    box.reload = load
    return box
