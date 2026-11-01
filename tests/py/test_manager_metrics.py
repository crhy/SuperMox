"""Unit tests for the RRD metric operations.

The row fixtures are the shapes the running node actually returns (see
.strata/notes-t77-manager-graphs.md: cpu 0.0068, memtotal 2064580608,
roottotal 20957446144, netin 107.81, storage total/used). A recording client
proves each call hits the endpoint and parameter set the node advertises.
"""

import unittest

from supermox_manager.ops import metrics

NODE_ROWS = [
    {"time": 1778046720, "cpu": None, "iowait": None, "loadavg": None,
     "maxcpu": None, "memtotal": None, "memused": None, "netin": None,
     "netout": None, "roottotal": None, "rootused": None},
    {"time": 1778046780, "cpu": 0.0068, "iowait": 0.0, "loadavg": 0.0,
     "maxcpu": 0.0068, "memtotal": 2064580608, "memused": 1491778736.55,
     "netin": 107.81, "netout": 139.40, "roottotal": 20957446144,
     "rootused": 6508381431.17},
]
GUEST_ROWS = [
    {"time": 1778046720, "maxcpu": None, "cpu": None, "maxmem": None,
     "mem": None, "memhost": None, "netin": None, "netout": None,
     "diskread": None, "diskwrite": None},
    {"time": 1778046780, "maxcpu": 0.0, "cpu": 0.0, "maxmem": 0.0,
     "mem": 0.0, "memhost": 0.0, "netin": 0.0, "netout": 0.0,
     "diskread": 0.0, "diskwrite": 0.0},
]
STORAGE_ROWS = [
    {"time": 1778046720, "total": None, "used": None},
    {"time": 1778046780, "total": 20957446144, "used": 6508381431.17},
]


class Recorder:
    def __init__(self, rows=None):
        self.calls = []
        self.rows = rows if rows is not None else []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return self.rows


class RrdCalls(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_node(self):
        self.client.rows = NODE_ROWS
        rows = metrics.rrd(self.client, "supermox")
        self.assertEqual(len(rows), 2)
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/rrddata",
                           {"timeframe": "hour", "cf": "AVERAGE"})])

    def test_qemu_and_lxc(self):
        metrics.rrd(self.client, "supermox", kind="qemu", vmid=9950,
                    timeframe="day")
        metrics.rrd(self.client, "supermox", kind="lxc", vmid=9951,
                    timeframe="day")
        self.assertEqual([call[1] for call in self.client.calls],
                         ["/nodes/supermox/qemu/9950/rrddata",
                          "/nodes/supermox/lxc/9951/rrddata"])
        self.assertEqual(self.client.calls[0][2],
                         {"timeframe": "day", "cf": "AVERAGE"})

    def test_storage(self):
        metrics.rrd(self.client, "supermox", kind="storage", storage="local",
                    timeframe="week", cf="MAX")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/storage/local/rrddata",
                           {"timeframe": "week", "cf": "MAX"})])

    def test_timeframe_is_required_and_enumerated(self):
        for bad in (None, "", "5min", "10min", "decennium"):
            with self.assertRaises(ValueError):
                metrics.rrd(self.client, "supermox", timeframe=bad)

    def test_decade_only_for_nodes(self):
        metrics.rrd(self.client, "supermox", timeframe="decade")
        with self.assertRaises(ValueError):
            metrics.rrd(self.client, "supermox", kind="qemu", vmid=9950,
                        timeframe="decade")

    def test_cf_enumerated(self):
        for bad in ("average", "MIN", ""):
            with self.assertRaises(ValueError):
                metrics.rrd(self.client, "supermox", cf=bad)

    def test_target_required(self):
        with self.assertRaises(ValueError):
            metrics.rrd(self.client, "supermox", kind="qemu")
        with self.assertRaises(ValueError):
            metrics.rrd(self.client, "supermox", kind="storage")
        with self.assertRaises(ValueError):
            metrics.rrd(self.client, "supermox", kind="disk")

    def test_names_are_url_segmented(self):
        metrics.rrd(self.client, "n od", kind="storage", storage="l ocal")
        self.assertEqual(self.client.calls[-1][1],
                         "/nodes/n%20od/storage/l%20ocal/rrddata")

    def test_missing_rows_are_empty(self):
        self.client.rows = None
        self.assertEqual(metrics.rrd(self.client, "supermox"), [])


class Series(unittest.TestCase):
    def test_gaps_are_dropped_not_zeroed(self):
        points = metrics.series(NODE_ROWS, "cpu")
        self.assertEqual(points, [(1778046780, 0.0068)])

    def test_all_fields_of_a_real_row(self):
        for field, value in (("memtotal", 2064580608), ("netin", 107.81),
                             ("roottotal", 20957446144)):
            self.assertEqual(metrics.series(NODE_ROWS, field),
                             [(1778046780, float(value))])

    def test_unknown_field_is_empty(self):
        self.assertEqual(metrics.series(NODE_ROWS, "nonesuch"), [])

    def test_non_numeric_and_infinite_values_are_dropped(self):
        rows = [{"time": 1, "cpu": "x"}, {"time": 2, "cpu": None},
                {"time": 3, "cpu": float("nan")}, {"time": 4, "cpu": 1.5}]
        self.assertEqual(metrics.series(rows, "cpu"), [(4, 1.5)])

    def test_guest_zero_values_survive(self):
        self.assertEqual(metrics.series(GUEST_ROWS, "cpu"),
                         [(1778046780, 0.0)])


class Scale(unittest.TestCase):
    def test_percent(self):
        values, unit = metrics.scale([0.0068, 0.0], "percent")
        self.assertEqual(unit, "%")
        self.assertAlmostEqual(values[0], 0.68)
        self.assertAlmostEqual(values[1], 0.0)

    def test_bytes_pick_one_unit_for_the_whole_series(self):
        values, unit = metrics.scale([20957446144, 6508381431.17], "bytes")
        self.assertEqual(unit, "GiB")
        self.assertAlmostEqual(values[0], 19.52, places=2)
        self.assertAlmostEqual(values[1], 6.06, places=2)

    def test_rate_appends_per_second(self):
        values, unit = metrics.scale([107.81, 139.40], "rate")
        self.assertEqual(unit, "B/s")
        self.assertEqual(values, [107.81, 139.40])
        values, unit = metrics.scale([2048.0], "rate")
        self.assertEqual(unit, "KiB/s")
        self.assertEqual(values, [2.0])

    def test_small_values_stay_in_bytes(self):
        values, unit = metrics.scale([0, 512], "bytes")
        self.assertEqual(unit, "B")
        self.assertEqual(values, [0.0, 512.0])

    def test_empty_series(self):
        values, unit = metrics.scale([], "bytes")
        self.assertEqual((values, unit), ([], "B"))

    def test_unknown_kind(self):
        with self.assertRaises(ValueError):
            metrics.scale([1], "meh")


class Charts(unittest.TestCase):
    def test_node_and_guest_charts(self):
        self.assertEqual([c[0] for c in metrics.NODE_CHARTS],
                         ["CPU usage", "Memory usage", "Network traffic",
                          "Disk usage"])
        self.assertEqual([c[0] for c in metrics.GUEST_CHARTS],
                         ["CPU usage", "Memory usage", "Network traffic",
                          "Disk IO"])

    def test_every_field_is_archived_on_the_real_node(self):
        for chart in metrics.NODE_CHARTS:
            for field in chart[1]:
                self.assertIn(field, NODE_ROWS[1])

    def test_charts_for(self):
        self.assertIs(metrics.charts_for(None), metrics.NODE_CHARTS)
        self.assertIs(metrics.charts_for("qemu"), metrics.GUEST_CHARTS)
        self.assertIs(metrics.charts_for("lxc"), metrics.GUEST_CHARTS)
        self.assertIs(metrics.charts_for("storage"), metrics.STORAGE_CHARTS)
        with self.assertRaises(ValueError):
            metrics.charts_for("disk")


if __name__ == "__main__":
    unittest.main()
