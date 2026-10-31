"""Offline unit tests for ops/containers.py: a fake client records every call."""

import unittest

from supermox_manager.ops import containers as ct


class FakeClient:
    """Records (method, path, params) and returns canned data per call."""

    def __init__(self, responses=None):
        self.calls = []
        self.responses = list(responses or [])

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        if self.responses:
            return self.responses.pop(0)
        return {}


class TemplateOps(unittest.TestCase):
    def test_template_storages_filters_on_content(self):
        client = FakeClient([[{"storage": "local", "content": "rootdir,backup,vztmpl"},
                             {"storage": "backups", "content": "backup"},
                             {"storage": "secondary", "content": "vztmpl, iso"}]])
        self.assertEqual(ct.template_storages(client, "pve"), ["local", "secondary"])
        self.assertEqual(client.calls[-1][:2], ("GET", "/nodes/pve/storage"))

    def test_available_templates_path_and_fields(self):
        client = FakeClient([[{"template": "alpine-3.24-default_20260714_amd64.tar.xz",
                               "os": "alpine", "architecture": "amd64", "section": "system",
                               "headline": "Alpine Linux 3.24", "package": "appliance-alpine-3.24",
                               "sha512sum": "deadbeef"}]])
        rows = ct.available_templates(client, "pve")
        self.assertEqual(client.calls[-1][:2], ("GET", "/nodes/pve/aplinfo"))
        self.assertEqual(rows, [{"template": "alpine-3.24-default_20260714_amd64.tar.xz",
                                 "os": "alpine", "architecture": "amd64", "section": "system",
                                 "headline": "Alpine Linux 3.24", "package": "appliance-alpine-3.24"}])

    def test_available_templates_skips_nameless_rows(self):
        client = FakeClient([[{"os": "alpine"}, {"template": "debian-12.tar.xz"}]])
        self.assertEqual([r["template"] for r in ct.available_templates(client, "pve")],
                         ["debian-12.tar.xz"])

    def test_download_template_path_and_params(self):
        client = FakeClient(["UPID:pve:0000:aplinfo"])
        self.assertEqual(
            ct.download_template(client, "pve", "local",
                                 "alpine-3.24-default_20260714_amd64.tar.xz"),
            "UPID:pve:0000:aplinfo")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/pve/aplinfo"))
        self.assertEqual(params, {"storage": "local",
                                  "template": "alpine-3.24-default_20260714_amd64.tar.xz"})

    def test_download_template_refuses_bad_names(self):
        for storage, template in (("local", ""), ("", "x.tar.xz"),
                                  ("local", "../etc/passwd"), ("a b", "x.tar.xz"),
                                  ("local", "sub/dir/x.tar.xz")):
            with self.subTest(storage=storage, template=template):
                with self.assertRaises(ValueError):
                    ct.download_template(FakeClient(), "pve", storage, template)

    def test_templates_reads_vztmpl_from_every_allowed_storage(self):
        client = FakeClient([[{"storage": "local", "content": "rootdir,backup,vztmpl"},
                             {"storage": "onlybackup", "content": "backup"},
                             {"storage": "secondary", "content": "vztmpl"}],
                            [{"volid": "local:vztmpl/b.tar.xz"}],
                            [{"volid": "secondary:vztmpl/a.tar.xz"}]])
        self.assertEqual(ct.templates(client, "pve"),
                         ["local:vztmpl/b.tar.xz", "secondary:vztmpl/a.tar.xz"])
        self.assertEqual(client.calls[1][:2], ("GET", "/nodes/pve/storage/local/content"))
        self.assertEqual(client.calls[1][2], {"content": "vztmpl"})
        self.assertEqual(client.calls[2][:2], ("GET", "/nodes/pve/storage/secondary/content"))
        self.assertEqual(len(client.calls), 3)


class CtParams(unittest.TestCase):
    ANSWERS = {"hostname": "t67ct", "template": "local:vztmpl/alpine-3.24.tar.xz",
               "storage": "local", "size": 1, "memory": 64, "cores": 1,
               "bridge": "vmbr0", "password": "s3cret-pw", "ssh_keys": "ssh-ed25519 AAAA key"}

    def test_full_answer_builds_the_exact_body(self):
        params = ct.ct_params(self.ANSWERS)
        self.assertEqual(params, {
            "hostname": "t67ct",
            "ostemplate": "local:vztmpl/alpine-3.24.tar.xz",
            "rootfs": "local:1",
            "memory": 64,
            "cores": 1,
            "unprivileged": 1,
            "net0": "name=eth0,bridge=vmbr0,ip=dhcp",
            "password": "s3cret-pw",
            "ssh-public-keys": "ssh-ed25519 AAAA key",
        })

    def test_rootfs_is_storage_colon_gigabytes(self):
        answers = dict(self.ANSWERS, size=4)
        self.assertEqual(ct.ct_params(answers)["rootfs"], "local:4")

    def test_no_bridge_means_no_net0(self):
        params = ct.ct_params(dict(self.ANSWERS, bridge=""))
        self.assertNotIn("net0", params)

    def test_password_only_when_given(self):
        answers = dict(self.ANSWERS)
        answers.pop("password")
        answers.pop("ssh_keys")
        params = ct.ct_params(answers)
        self.assertNotIn("password", params)
        self.assertNotIn("ssh-public-keys", params)

    def test_password_travels_only_in_the_body(self):
        params = ct.ct_params(self.ANSWERS)
        self.assertEqual(params["password"], "s3cret-pw")
        # nothing else in the request carries it
        others = [value for key, value in params.items() if key != "password"]
        self.assertFalse([value for value in others if "s3cret-pw" in str(value)])

    def test_host_name_rules(self):
        for hostname in ("", "  ", "-bad", "bad-", "a b", "x" * 64):
            with self.subTest(hostname=hostname):
                with self.assertRaises(ValueError):
                    ct.ct_params(dict(self.ANSWERS, hostname=hostname))

    def test_template_must_be_a_vztmpl_volid_or_path(self):
        for template in ("", "alpine.tar.xz", "local:iso/x.iso", "local:vztmpl/"):
            with self.subTest(template=template):
                with self.assertRaises(ValueError):
                    ct.ct_params(dict(self.ANSWERS, template=template))
        params = ct.ct_params(dict(self.ANSWERS, template="/var/cache/pve/appliances/x.tar.xz"))
        self.assertEqual(params["ostemplate"], "/var/cache/pve/appliances/x.tar.xz")

    def test_storage_bridge_and_number_rules(self):
        bad = [dict(self.ANSWERS, storage="a b"), dict(self.ANSWERS, bridge="a b"),
               dict(self.ANSWERS, size=0), dict(self.ANSWERS, memory=1),
               dict(self.ANSWERS, cores=0), dict(self.ANSWERS, cores=9000)]
        for answers in bad:
            with self.subTest(answers=sorted(answers)):
                with self.assertRaises(ValueError):
                    ct.ct_params(answers)

    def test_numbers_accept_strings(self):
        params = ct.ct_params(dict(self.ANSWERS, size="2", memory="512", cores="4"))
        self.assertEqual((params["rootfs"], params["memory"], params["cores"]),
                         ("local:2", 512, 4))


class CtApi(unittest.TestCase):
    def test_create_ct_path_and_vmid(self):
        client = FakeClient(["UPID:pve:0000:vzcreate"])
        upid = ct.create_ct(client, "pve", 9920, ct.ct_params(CtParams.ANSWERS))
        self.assertEqual(upid, "UPID:pve:0000:vzcreate")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/pve/lxc"))
        self.assertEqual(params["vmid"], 9920)
        self.assertEqual(params["rootfs"], "local:1")

    def test_create_ct_refuses_out_of_range_vmid(self):
        for vmid in (99, 1000000000):
            with self.subTest(vmid=vmid):
                with self.assertRaises(ValueError):
                    ct.create_ct(FakeClient(), "pve", vmid, {"hostname": "x"})

    def test_start_and_stop_paths(self):
        client = FakeClient(["UPID:s", "UPID:t"])
        ct.start_ct(client, "pve", 9920)
        ct.stop_ct(client, "pve", 9920)
        self.assertEqual([call[:2] for call in client.calls],
                         [("POST", "/nodes/pve/lxc/9920/status/start"),
                          ("POST", "/nodes/pve/lxc/9920/status/stop")])
        self.assertEqual(client.calls[0][2], {})


if __name__ == "__main__":
    unittest.main()
