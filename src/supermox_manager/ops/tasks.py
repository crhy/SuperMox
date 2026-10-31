"""Task polling for SuperMox Manager operations (no GTK)."""

import time

from .. import api


def wait_task(client, node, upid, timeout=300, allow_warnings=False):
    """Poll a submitted task until it stops; return its exitstatus.

    Raises api.APIError if the task did not finish successfully or timed out.
    With allow_warnings, a task that stopped with a WARNINGS exitstatus (for
    example the networking reload warning on a node without SDN) is treated as
    finished rather than failed.
    """
    path = "/nodes/{}/tasks/{}".format(api.segment(node), api.segment(upid))
    deadline = time.monotonic() + timeout
    while True:
        status = client.request("GET", path + "/status")
        if status.get("status") == "stopped":
            exitstatus = status.get("exitstatus", "")
            if exitstatus == "OK":
                return exitstatus
            if allow_warnings and exitstatus.startswith("WARNINGS"):
                return exitstatus
            raise api.APIError("Task failed (exitstatus {}).".format(exitstatus or "unknown"))
        if time.monotonic() >= deadline:
            raise api.APIError("Task did not finish within {} seconds.".format(timeout))
        time.sleep(1)
