"""The graphs page must actually draw.

Importing GTK or cairo here would break test_manager_pin.py, which proves the
security code stays importable on a host with no GUI. So the rendering checks
live in graphs_render.py and run in a child interpreter under a virtual display.
"""

import os
import shutil
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


class Rendered(unittest.TestCase):
    def test_the_page_renders_under_a_display(self):
        if not shutil.which("xvfb-run"):
            self.skipTest("no xvfb-run on this host")
        env = dict(os.environ, PYTHONPATH=os.path.join(ROOT, "src"))
        result = subprocess.run(
            ["xvfb-run", "-a", sys.executable,
             os.path.join(HERE, "graphs_render.py")],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
        self.assertEqual(result.returncode, 0,
                         (result.stdout + result.stderr)[-4000:])
        self.assertIn("OK", result.stderr)

    def test_the_rendered_chart_reached_disk(self):
        png = os.path.join(ROOT, "build", "unit-chart.png")
        self.assertTrue(os.path.exists(png), "graphs_render.py writes it")
        with open(png, "rb") as fh:
            head = fh.read(8)
        self.assertEqual(head, b"\x89PNG\r\n\x1a\n")


if __name__ == "__main__":
    unittest.main()
