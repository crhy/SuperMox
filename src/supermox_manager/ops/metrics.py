"""RRD history for the graph views (no GTK).

Four endpoints serve the archived statistics: /nodes/{node}/rrddata,
/nodes/{node}/qemu/{vmid}/rrddata, /nodes/{node}/lxc/{vmid}/rrddata and
/nodes/{node}/storage/{storage}/rrddata. Every path, parameter name and enum
value was read from the running node with `pvesh usage` and from the upstream
method definitions (see .strata/notes-t77-manager-graphs.md); nothing is guessed.

The rows come back as a fixed-length series: one entry per sample interval,
with `null` for every field that was not sampled in that interval. `series`
drops those gaps, `scale` turns raw values into display units.
"""

from .. import api

# `timeframe` is required; the enums differ per endpoint (node also allows
# 'decade'). `cf` is the RRD consolidation function and is optional.
TIMEFRAMES = ("hour", "day", "week", "month", "year")
NODE_TIMEFRAMES = TIMEFRAMES + ("decade",)
CONSOLIDATION = ("AVERAGE", "MAX")

# What each graph draws: (title, fields, series labels, scale kind).
# The node archive has no diskread/diskwrite columns, so the node page graphs
# root filesystem capacity/usage instead; guests have both.
NODE_CHARTS = (
    ("CPU usage", ("cpu", "iowait"), ("CPU", "IO delay"), "percent"),
    ("Memory usage", ("memtotal", "memused"), ("Total", "Used"), "bytes"),
    ("Network traffic", ("netin", "netout"), ("Incoming", "Outgoing"), "rate"),
    ("Disk usage", ("roottotal", "rootused"), ("Capacity", "Used"), "bytes"),
)
GUEST_CHARTS = (
    ("CPU usage", ("cpu",), ("CPU",), "percent"),
    ("Memory usage", ("maxmem", "mem"), ("Total", "Used"), "bytes"),
    ("Network traffic", ("netin", "netout"), ("Incoming", "Outgoing"), "rate"),
    ("Disk IO", ("diskread", "diskwrite"), ("Reads", "Writes"), "rate"),
)
STORAGE_CHARTS = (
    ("Storage usage", ("total", "used"), ("Capacity", "Used"), "bytes"),
)


def charts_for(kind):
    """Chart definitions for a target kind: node, qemu, lxc or storage."""
    if kind in (None, "node"):
        return NODE_CHARTS
    if kind in ("qemu", "lxc"):
        return GUEST_CHARTS
    if kind == "storage":
        return STORAGE_CHARTS
    raise ValueError("Unknown metric kind: {}".format(kind))


def rrd(client, node, kind=None, vmid=None, storage=None, timeframe="hour",
        cf="AVERAGE"):
    """GET the rrddata endpoint; returns the list of row dicts.

    kind None/'node' -> /nodes/{node}/rrddata
    kind 'qemu'/'lxc' -> /nodes/{node}/{kind}/{vmid}/rrddata
    kind 'storage'   -> /nodes/{node}/storage/{storage}/rrddata

    timeframe must be one of TIMEFRAMES ('decade' only for a node), cf one of
    CONSOLIDATION. Rows are ordered oldest -> newest; each row carries 'time'
    (epoch seconds) plus the archived fields, which are None where unsampled.
    """
    if kind in (None, "node"):
        path = "/nodes/{}/rrddata".format(api.segment(node))
        allowed = NODE_TIMEFRAMES
    elif kind in ("qemu", "lxc"):
        if vmid is None:
            raise ValueError("A guest needs a vmid.")
        path = "/nodes/{}/{}/{}/rrddata".format(
            api.segment(node), kind, api.segment(vmid))
        allowed = TIMEFRAMES
    elif kind == "storage":
        if not storage:
            raise ValueError("A storage graph needs a storage id.")
        path = "/nodes/{}/storage/{}/rrddata".format(
            api.segment(node), api.segment(storage))
        allowed = TIMEFRAMES
    else:
        raise ValueError("Unknown metric kind: {}".format(kind))
    if timeframe not in allowed:
        raise ValueError("Unknown timeframe: {} (expected {})".format(
            timeframe, ", ".join(allowed)))
    if cf not in CONSOLIDATION:
        raise ValueError("Unknown consolidation function: {}".format(cf))
    try:
        rows = client.request("GET", path, {"timeframe": timeframe, "cf": cf})
    except api.APIError as exc:
        # A node or guest with no archive yet (a brand-new node before
        # pvestatd's first cycle, a guest that never ran) is answered with
        # HTTP 500 by the server: that is "no history yet", not a failure.
        if exc.status == 500:
            return []
        raise
    return list(rows or [])


def series(rows, field):
    """[(time, value)] for one field, skipping rows where it was not sampled.

    Null, missing, non-numeric and non-finite values are dropped rather than
    read as zero, so a gap in the archive stays a gap on the graph.
    """
    points = []
    for row in rows:
        value = row.get(field)
        if value is None:
            continue
        try:
            value = float(value)
        except (TypeError, ValueError):
            continue
        if value != value or value in (float("inf"), float("-inf")):
            continue
        points.append((row.get("time"), value))
    return points


def scale(values, kind, peak=None):
    """Return (values, unit) converted to one display unit for the whole series.

    kind 'percent': the archived value is a fraction of 1, so 0.0068 -> 0.68
    with unit '%'. 'bytes' and 'rate' pick the largest power-of-two unit that
    still leaves the peak at or above 1 (B, KiB, MiB, GiB, TiB, PiB); 'rate'
    appends '/s' because those columns are already bytes per second.

    `peak` overrides the value the unit is chosen for. Two series drawn on one
    axis must share a unit, so the caller passes the peak of both series.
    """
    values = [float(v) for v in values if v is not None]
    if kind == "percent":
        return [v * 100.0 for v in values], "%"
    if kind not in ("bytes", "rate"):
        raise ValueError("Unknown scale: {}".format(kind))
    suffix = "" if kind == "bytes" else "/s"
    divisor = 1.0
    unit = "B" + suffix
    top = float(peak) if peak is not None else max((abs(v) for v in values), default=0.0)
    for name in ("KiB", "MiB", "GiB", "TiB", "PiB"):
        if top < divisor * 1024:
            break
        divisor *= 1024
        unit = name + suffix
    return [v / divisor for v in values], unit
