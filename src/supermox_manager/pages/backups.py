"""Backups: native scheduled backup jobs.

Scheduled jobs live under /cluster/backup and run on a systemd-calendar
schedule ("sun 03:00", "daily"). Every endpoint and parameter name was read
from the running node with `pvesh usage` (see .strata/notes-t75-manager-backup-
jobs-ha.md); nothing is guessed. A job's options (storage, mode, compression,
retention) come back flattened onto the job record, and retention (prune-
backups) is a map that travels back as "keep-all=1,keep-daily=2". "Run now"
replays a job's settings as a one-off vzdump on its node and reports the task
id, which the Tasks page then follows.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from ._view import deliver, table
from ._view import selected as _selected
from ..ops import jobs

TITLE = "Backups"
SUBTITLE = "Scheduled backup jobs across your cluster."

TABS = ("Jobs",)

RETENTION = ("keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly")


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _storages(manager):
    return [r["storage"] for r in manager.resources if r["type"] == "storage"]


def _yes(value):
    return str(value).strip().lower() in ("1", "yes", "true", "on")


def _retention(record):
    prune = record.get("prune-backups")
    if isinstance(prune, dict):
        return ", ".join("{}={}".format(k, prune[k]) for k in sorted(prune))
    return prune or "—"


def _jobs_rows(manager, box, rows):
    manager.job_map = {row["id"]: row for row in rows}
    manager.sel_job = None

    def pick(view, path, _c):
        manager.sel_job = manager.job_map.get(view.get_model()[path][0])

    if not rows:
        box.pack_start(Gtk.Label(label="No scheduled backup jobs. Create one below."),
                       False, False, 6)
        return
    table(box, ("Name", "Schedule", "Enabled", "Target", "Storage", "Mode",
                "Retention", "Last run", "Comment"),
          [(row["id"], row.get("schedule", ""),
           "yes" if _yes(row.get("enabled")) else "no",
           "all" if row.get("all") else "vm " + str(row.get("vmid", "")),
           row.get("storage", ""), row.get("mode", ""),
           _retention(row),
           "never" if not row.get("last_run") else str(row.get("last_run")),
           row.get("comment", ""))
           for row in rows],
          select=pick)


def _load_jobs(manager):
    manager.work(lambda: jobs.backup_jobs(manager.client),
                 deliver(manager, "backup_results", TITLE, "Jobs", _jobs_rows))


def _retention_form(values):
    prune = {}
    for key in RETENTION:
        if values.get(key, "").strip():
            prune[key] = int(values[key].strip())
    return prune or None


def _create_job(manager):
    names = _storages(manager)
    values = manager.form(
        "Create a backup job",
        [("id", "Job name", "nightly", False),
         ("schedule", "Schedule (e.g. 'sun 03:00' or 'daily')", "sun 03:00", False),
         ("all", "Back up all machines (1 or 0)", "0", False),
         ("vmid", "Machine to back up (blank if all)", "", False),
         ("storage", "Backup storage", names[0] if names else "", False),
         ("mode", "Mode (snapshot, stop, suspend)", "snapshot", False),
         ("compress", "Compression (0, gzip, bzip2, zstd)", "0", False),
         ("enabled", "Enabled (1 or 0)", "1", False),
         ("comment", "Comment", "", False),
         ("keep-last", "Keep last N backups", "8", False),
         ("keep-daily", "Keep daily backups", "7", False),
         ("keep-weekly", "Keep weekly backups", "4", False),
         ("keep-monthly", "Keep monthly backups", "6", False)],
        "Create",
        "Creates a job that runs on its schedule. Back up all machines, or name "
        "one. Retention controls how many backups are kept. The schedule uses "
        "systemd calendar events, for example 'sun 03:00' or 'daily'.")
    if values is None:
        return
    if not values["id"].strip():
        manager.message("Check the fields", "Give the job a name.")
        return
    all_machines = _yes(values["all"])
    vmid = values["vmid"].strip()
    if not all_machines and not vmid:
        manager.message("Check the fields",
                        "Back up all machines, or give one machine to back up.")
        return
    options = {"storage": values["storage"].strip() or None,
               "mode": values["mode"].strip(),
               "compress": values["compress"].strip(),
               "enabled": _yes(values["enabled"]),
               "comment": values["comment"].strip() or None,
               "prune_backups": _retention_form(values),
               "job_id": values["id"].strip()}
    if all_machines:
        options["all"] = True
    else:
        options["vmid"] = vmid
    client = manager.client
    manager.work(lambda: jobs.create_backup_job(client, values["schedule"].strip(),
                                                **options),
                 lambda _r: (manager.status.set_text("Created job " + values["id"].strip()),
                             _load_jobs(manager)))


def _change_job(manager):
    job = _selected(manager, "sel_job", "job", "Jobs")
    if not job:
        return
    values = manager.form(
        "Change job {}".format(job["id"]),
        [("schedule", "Schedule (e.g. 'sun 03:00')", job.get("schedule", ""), False),
         ("storage", "Backup storage", job.get("storage", ""), False),
         ("mode", "Mode (snapshot, stop, suspend)", job.get("mode", "snapshot"), False),
         ("compress", "Compression (0, gzip, bzip2, zstd)",
          str(job.get("compress", 0)), False),
         ("enabled", "Enabled (1 or 0)", "1" if _yes(job.get("enabled")) else "0", False),
         ("comment", "Comment", job.get("comment", ""), False),
         ("keep-last", "Keep last N backups", "", False),
         ("keep-daily", "Keep daily backups", "", False),
         ("keep-weekly", "Keep weekly backups", "", False),
         ("keep-monthly", "Keep monthly backups", "", False)],
        "Change",
        "Updates this job's schedule and options. The job name itself does not "
        "change. Leave a retention field blank to leave that rule alone.")
    if values is None:
        return
    options = {"schedule": values["schedule"].strip(),
               "storage": values["storage"].strip(),
               "mode": values["mode"].strip(),
               "compress": values["compress"].strip(),
               "enabled": _yes(values["enabled"]),
               "comment": values["comment"].strip()}
    prune = _retention_form(values)
    if prune:
        options["prune_backups"] = prune
    client = manager.client
    manager.work(lambda: jobs.update_backup_job(client, job["id"], **options),
                 lambda _r: (manager.status.set_text("Updated job " + job["id"]),
                             _load_jobs(manager)))


def _delete_job(manager):
    job = _selected(manager, "sel_job", "job", "Jobs")
    if not job:
        return
    if not manager.confirm("Delete job {}?".format(job["id"]),
                           "Stop scheduling this backup job. Backups already taken are kept. "
                           "This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: jobs.delete_backup_job(client, job["id"]),
                 lambda _r: (manager.status.set_text("Deleted job " + job["id"]),
                             _load_jobs(manager)))


def _run_now(manager):
    job = _selected(manager, "sel_job", "job", "Jobs")
    if not job:
        return
    client = manager.client

    def op():
        node = job.get("node") or _node(manager)
        return jobs.run_now(client, node, job)

    manager.work(op, lambda task: (manager.status.set_text("Started backup: " + str(task)),
                                   manager.reload()))


DESCRIPTIONS = {
    "Jobs": "Create, change, delete and run scheduled backup jobs. Double-click a "
            "row to select it for change, delete or run now.",
}

ACTIONS = {
    "Jobs": (("Jobs", lambda m: _load_jobs(m)),
             ("Create job", _create_job),
             ("Change job", _change_job),
             ("Delete job", _delete_job),
             ("Run now", _run_now)),
}


def render(manager, content):
    from ..app import label
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
    manager.backup_results = {}
    for name in TABS:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        page.set_hexpand(True)
        page.set_vexpand(True)
        page.pack_start(label(DESCRIPTIONS[name], "subtitle"), False, False, 4)
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for text, callback in ACTIONS[name]:
            actions.pack_start(Gtk.Button(label=text), False, False, 0)
        page.pack_start(actions, False, False, 0)
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        results.set_hexpand(True)
        results.set_vexpand(True)
        page.pack_start(results, True, True, 0)
        manager.backup_results[name] = results
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
