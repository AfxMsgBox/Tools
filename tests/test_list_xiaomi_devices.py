"""本地模拟 SSH 执行远端只读采集脚本；不需要网络或真实 HA。"""
import hashlib
import csv
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import unicodedata


SCRIPT = Path(__file__).resolve().parents[1] / "list_xiaomi_devices.sh"


class DeviceListTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # 验证远端 shell 引号处理，不允许路径中的 shell 字符被解释。
        self.config = self.root / "ha 'config; $literal"
        self.storage = self.config / ".storage"
        self.cache_dir = self.storage / "xiaomi_home" / "miot_devices"
        self.cache_dir.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.executable("ssh", '''#!/usr/bin/env bash
printf '%s\\n' "$@" > "$TEST_ARGS"
remote="${!#}"
exec sh -c "$remote"
''')
        self.executable("ip", '''#!/bin/sh
printf '%s\\n' '192.168.1.2 dev eth0 lladdr aa:bb:cc:dd:ee:02 REACHABLE'
printf '%s\\n' '192.168.1.3 dev eth0 lladdr aa:bb:cc:dd:ee:03 FAILED'
''')
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_ARGS=str(self.root / "args"), TEST_ROOT=str(self.root))
        # 默认不允许意外联网；响应由各测试提供。真实远端逻辑仍由 sh 执行。
        self.executable("curl", f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["TEST_ROOT"])
args = sys.argv[1:]
assert args[0] == "-q"
assert "TEST_ACCESS_TOKEN" not in " ".join(args)
config = sys.stdin.read().splitlines()
headers = [json.loads(line.split(" = ", 1)[1]) for line in config if line.startswith("header = ")]
assert "Authorization: BearerTEST_ACCESS_TOKEN" in headers
assert "X-Client-BizId: haapi" in headers
request = next(json.loads(json.loads(line.split(" = ", 1)[1])) for line in config if line.startswith("data = "))
with (root / "requests").open("a") as f:
    f.write(json.dumps({"url": args[-1], "data": request}) + "\\n")
if os.environ.get("CURL_FAIL"):
    sys.exit(22)
counter = root / "counter"
n = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(n + 1))
pages = json.loads((root / "pages.json").read_text())
print(json.dumps(pages[n]))
''')
        self.registry([])
        self.entries([])

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def registry(self, devices):
        (self.storage / "core.device_registry").write_text(json.dumps(
            {"data": {"devices": devices}}))

    def entries(self, entries):
        (self.storage / "core.config_entries").write_text(json.dumps({"data": {"entries": entries}}))

    def device(self, did, name, **extra):
        device = dict(id=did, name=name, name_by_user=None, config_entry_id="entry_100_cn",
                      identifiers=[["xiaomi_home", f"cn_{did}"]], connections=[])
        device.update(extra)
        return device

    def cache(self, devices, filename="100_cn.dict"):
        data = json.dumps(devices).encode()
        path = self.cache_dir / filename
        path.write_bytes(data + hashlib.sha256(data).digest())
        key = filename.removesuffix(".dict")
        uid, region = key.rsplit("_", 1)
        entries = json.loads((self.storage / "core.config_entries").read_text())["data"]["entries"]
        if not any(e["entry_id"] == "entry_" + key for e in entries):
            entries.append({"entry_id": "entry_" + key, "domain": "xiaomi_home", "title": "账号 " + uid,
                            "data": {"uid": uid, "cloud_server": region, "nick_name": "用户 " + uid}})
            self.entries(entries)
        return path

    def cloud(self, pages, filename="100_cn.dict"):
        directory = self.storage / "xiaomi_home" / "miot_config"
        directory.mkdir(exist_ok=True)
        data = json.dumps({"auth_info": {"access_token": "TEST_ACCESS_TOKEN"}}).encode()
        (directory / filename).write_bytes(data + hashlib.sha256(data).digest())
        (self.root / "pages.json").write_text(json.dumps(pages))

    def page(self, devices, **extra):
        return {"code": 0, "result": {"list": devices, "has_more": False, **extra}}

    def run_script(self, *extra, cloud=False):
        return subprocess.run(["bash", str(SCRIPT), "--host", "fixture",
                               "--user", "root", "--config-dir", str(self.config),
                               "--format", "tsv", *([] if cloud else ["--cached-only"]),
                               *extra], env=self.env, input="", text=True,
                              capture_output=True, timeout=15)

    def rows(self, result):
        return [[r["名称"], r["MAC"], r["IP"]] for r in self.records(result)]

    def records(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        reader = csv.DictReader(io.StringIO(result.stdout), delimiter="\t")
        self.assertEqual(reader.fieldnames, ["账号", "账号ID", "地区", "家庭", "家庭ID", "名称", "房间", "设备类型", "MAC", "IP"])
        return list(reader)

    def test_sort_scope_names_mac_and_empty_fields(self):
        devices = [self.device("1", "原名称"), self.device("2", "地址2"),
                   self.device("3", "无地址")]
        devices[0]["name_by_user"] = "自定义名称"
        devices[2]["connections"] = [["mac", "AA-BB-CC-DD-EE-33"]]
        devices.append(dict(id="other", name="非小米", identifiers=[["other", "x"]]))
        self.registry(devices)
        self.cache({"1": {"name": "缓存名称", "local_ip": "192.168.1.10", "mac": "AABBCCDDEE10"},
                    "2": {"local_ip": "192.168.1.2", "bssid": "11:22:33:44:55:66", "token": "SECRET"},
                    "3": {"local_ip": None}, "4": {"name": "旧设备", "local_ip": "192.168.1.1"}})
        result = self.run_script()
        self.assertEqual(self.rows(result), [["地址2", "aa:bb:cc:dd:ee:02", "192.168.1.2"],
                                            ["自定义名称", "aa:bb:cc:dd:ee:10", "192.168.1.10"],
                                            ["无地址", "aa:bb:cc:dd:ee:33", ""]])
        self.assertNotIn("SECRET", result.stdout + result.stderr)
        self.assertIn("BatchMode=yes", (self.root / "args").read_text())

    def test_empty_password_uses_key(self):
        self.rows(self.run_script("--password", ""))
        self.assertIn("BatchMode=yes", (self.root / "args").read_text())

    def test_password_passed_through_fd(self):
        self.executable("sshpass", '''#!/usr/bin/env bash
[[ "$1" == -d && "$2" == 3 ]] || exit 90
IFS= read -r actual <&3
[[ "$actual" == 'special $pass `word`' ]] || exit 91
shift 2
exec "$@"
''')
        result = self.run_script("--password", 'special $pass `word`')
        self.rows(result)
        args = (self.root / "args").read_text()
        self.assertIn("PubkeyAuthentication=no", args)
        self.assertNotIn("$pass", args + result.stdout + result.stderr)

    def test_corrupt_cache_fails_without_partial_stdout(self):
        path = self.cache({"1": {"name": "设备"}})
        path.write_bytes(path.read_bytes()[:-1] + b"!")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("校验失败", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_missing_cache_keeps_registered_device(self):
        self.registry([self.device("1", "仅注册")])
        self.assertEqual(self.rows(self.run_script()), [["仅注册", "", ""]])

    def test_nested_subdevice_and_invalid_ip(self):
        self.registry([self.device("123_s2", "子设备"), self.device("3", "无效邻居"),
                       self.device("4", "无效地址")])
        self.cache({"123": {"sub_devices": {"s2": {"did": "123.s2", "local_ip": "10.0.0.2"}}},
                    "3": {"local_ip": "192.168.1.3", "bssid": "aa:bb:cc:dd:ee:ff"},
                    "4": {"local_ip": "999.1.1.1"}})
        self.assertEqual(self.rows(self.run_script()), [["子设备", "", "10.0.0.2"],
                                                       ["无效邻居", "", "192.168.1.3"],
                                                       ["无效地址", "", ""]])

    def test_accounts_keep_independent_addresses(self):
        self.registry([self.device("1", "同一设备", config_entry_id=None,
                                   config_entries=["entry_100_cn", "entry_200_cn"])])
        self.cache({"1": {"local_ip": "10.0.0.2"}})
        self.cache({"1": {"local_ip": "10.0.0.3"}}, "200_cn.dict")
        records = self.records(self.run_script())
        self.assertEqual([(r["账号ID"], r["IP"]) for r in records], [("100", "10.0.0.2"), ("200", "10.0.0.3")])

    def test_ssh_failure(self):
        self.executable("ssh", "#!/bin/sh\nexit 255\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_invalid_registry(self):
        (self.storage / "core.device_registry").write_text('{}')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_invalid_port(self):
        for port in ("0", "65536", "not-a-port"):
            result = self.run_script("--port", port)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / "args").exists())

    def test_cloud_localip_mac_and_bluetooth_filter(self):
        self.registry([self.device("1", "WiFi设备"), self.device("blt_2", "蓝牙"),
                       self.device("3", "Mesh")])
        self.cache({"1": {"local_ip": "192.168.1.99", "mac": "aabbccddee99", "pid": 0},
                    "blt.2": {"pid": 6}, "3": {"pid": 16}, "old": {"pid": 0}})
        self.cloud([self.page([
            {"did": "1", "pid": 0, "localip": "192.168.1.2", "mac": "AA:BB:CC:DD:EE:01", "token": "DEVICE_SECRET"},
            {"did": "blt.2", "pid": 6, "localip": "113.1.2.3", "mac": "AA:BB:CC:DD:EE:02"},
            {"did": "3", "pid": 16, "localip": "192.168.1.3", "mac": "AA:BB:CC:DD:EE:03"},
            {"did": "old", "pid": 0, "localip": "192.168.1.1", "mac": "AA:BB:CC:DD:EE:04"}])])
        result = self.run_script(cloud=True)
        rows = self.rows(result)
        self.assertEqual(rows[0], ["WiFi设备", "aa:bb:cc:dd:ee:01", "192.168.1.2"])
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(row[2] == "" for row in rows[1:]))
        self.assertTrue(all(row[1] for row in rows))
        self.assertNotIn("DEVICE_SECRET", result.stdout + result.stderr)
        self.assertNotIn("TEST_ACCESS_TOKEN", result.stdout + result.stderr)
        request = json.loads((self.root / "requests").read_text())
        self.assertEqual(set(request["data"]["dids"]), {"1", "blt.2", "3"})

    def test_cloud_pagination(self):
        self.registry([self.device("1", "一"), self.device("2", "二")])
        self.cache({"1": {}, "2": {}})
        self.cloud([self.page([{"did": "1", "localip": "10.0.0.10"}], has_more=True, next_start_did="cursor1"),
                    self.page([{"did": "2", "localip": "10.0.0.2"}])])
        self.assertEqual([r[2] for r in self.rows(self.run_script(cloud=True))], ["10.0.0.2", "10.0.0.10"])
        requests = [json.loads(s) for s in (self.root / "requests").read_text().splitlines()]
        self.assertEqual(requests[1]["data"]["start_did"], "cursor1")

    def test_cloud_batches_and_region(self):
        devices = [self.device(str(i), str(i)) for i in range(151)]
        for device in devices:
            device["identifiers"][0][1] = "de_" + device["id"]
            device["config_entry_id"] = "entry_100_de"
        self.registry(devices)
        self.cache({str(i): {} for i in range(151)}, "100_de.dict")
        self.cloud([self.page([]), self.page([])], "100_de.dict")
        self.assertEqual(len(self.rows(self.run_script(cloud=True))), 151)
        requests = [json.loads(s) for s in (self.root / "requests").read_text().splitlines()]
        self.assertEqual([len(r["data"]["dids"]) for r in requests], [150, 1])
        self.assertTrue(all(r["url"].startswith("https://de.ha.api.io.mi.com/") for r in requests))

    def test_cloud_error_and_expired_auth(self):
        self.registry([self.device("1", "设备")])
        self.cache({"1": {}})
        self.cloud([{"code": -1}])
        for http_failure in (False, True):
            if http_failure:
                self.env["CURL_FAIL"] = "1"
            result = self.run_script(cloud=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("TEST_ACCESS_TOKEN", result.stderr)

    def test_repeated_cloud_cursor_fails(self):
        self.registry([self.device("1", "设备")])
        self.cache({"1": {}})
        page = self.page([], has_more=True, next_start_did="again")
        self.cloud([page, page])
        result = self.run_script(cloud=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("游标重复", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_pretty_table_alignment_and_truncation(self):
        self.registry([self.device("1", "很长的中文名称" * 12), self.device("2", "ASCII 名称"),
                       self.device("3", "温度计 e\u0301\t测试\n名称\x1b")])
        self.cache({"1": {}, "2": {}, "3": {}})
        self.env["COLUMNS"] = "80"
        result = self.run_script("--format", "table", "--no-color")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("小米 Home · 设备清单", result.stdout)
        self.assertIn("…", result.stdout)
        self.assertNotIn("\x1b", result.stdout)
        lines = [s for s in result.stdout.splitlines() if s.startswith(("│", "┌", "├", "└"))]
        def width(s):
            return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
        self.assertEqual({width(s) for s in lines}, {80})

    def test_shared_device_cloud_accounts_and_homes(self):
        self.registry([
            self.device("1", "共享设备", config_entry_id=None, config_entries=["entry_100_cn", "entry_200_cn"]),
            self.device("2", "单独设备"), self.device("3", "同名家庭设备")])
        self.cache({"1": {"home_id": "h1", "home_name": "家", "room_name": "客厅", "urn": "urn:miot-spec-v2:device:outlet:0001", "uid": "OWNER"},
                    "2": {"home_id": "h1", "home_name": "家", "room_name": "卧室"},
                    "3": {"home_id": "h2", "home_name": "家", "room_name": "书房"}})
        self.cache({"1": {"home_id": "h1", "home_name": "共享的家", "room_name": "客厅", "uid": "OWNER"},
                    "2": {"home_id": "h1", "local_ip": "10.0.0.250"}}, "200_cn.dict")
        self.cloud([self.page([{"did": "1", "localip": "10.0.0.10", "mac": "aabbccddee01", "pid": 0, "spec_type": "urn:miot-spec-v2:device:switch:0001"},
                               {"did": "2", "localip": "10.0.0.2", "pid": 0},
                               {"did": "3", "localip": "10.0.0.1", "pid": 0}]),
                    self.page([{"did": "1", "localip": "10.0.0.20", "mac": "aabbccddee02", "pid": 0}])])
        # 同一假令牌用于两个模拟账号；数据必须按来源而不是 DID 混合。
        auth = self.storage / "xiaomi_home" / "miot_config"
        (auth / "200_cn.dict").write_bytes((auth / "100_cn.dict").read_bytes())
        records = self.records(self.run_script(cloud=True))
        self.assertEqual(len(records), 4)
        self.assertEqual([(r["账号ID"], r["家庭ID"], r["IP"]) for r in records],
                         [("100", "h1", "10.0.0.2"), ("100", "h1", "10.0.0.10"),
                          ("100", "h2", "10.0.0.1"), ("200", "h1", "10.0.0.20")])
        self.assertEqual(records[1]["房间"], "客厅")
        self.assertEqual(records[1]["设备类型"], "开关")
        self.assertEqual(records[1]["MAC"], "aa:bb:cc:dd:ee:01")
        self.assertEqual(records[3]["MAC"], "aa:bb:cc:dd:ee:02")
        requests = [json.loads(s) for s in (self.root / "requests").read_text().splitlines()]
        self.assertEqual(requests[1]["data"]["dids"], ["1"])

    def test_room_inheritance_and_type_fallback(self):
        self.registry([self.device("1_s2", "子设备"), self.device("2", "未知类别"), self.device("3", "缺失字段")])
        self.cache({"1": {"home_id": "h1", "home_name": "家", "room_name": "客厅",
                          "sub_devices": {"s2": {"did": "1.s2", "urn": "urn:miot-spec-v2:device:temperature-humidity-sensor:0001"}}},
                    "2": {"urn": "urn:miot-spec-v2:device:new-widget:0001"}, "3": {}})
        records = {r["名称"]: r for r in self.records(self.run_script())}
        self.assertEqual(records["子设备"]["房间"], "客厅")
        self.assertEqual(records["子设备"]["家庭ID"], "h1")
        self.assertEqual(records["子设备"]["设备类型"], "温湿度计")
        self.assertEqual(records["未知类别"]["设备类型"], "new-widget")
        self.assertEqual(records["缺失字段"]["房间"], "")
        self.assertEqual(records["缺失字段"]["设备类型"], "")

    def test_removed_account_cache_is_ignored(self):
        self.registry([self.device("1", "设备")])
        self.cache({"1": {"local_ip": "10.0.0.2"}})
        path = self.cache({"1": {"local_ip": "10.0.0.3"}}, "200_cn.dict")
        entries = json.loads((self.storage / "core.config_entries").read_text())["data"]["entries"]
        self.entries([e for e in entries if e["data"]["uid"] == "100"])
        path.write_bytes(b"corrupt stale cache")
        records = self.records(self.run_script())
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["账号ID"], "100")
        self.assertEqual(records[0]["IP"], "10.0.0.2")

    def test_table_separates_homonymous_accounts_and_homes(self):
        self.registry([self.device("1", "共享", config_entry_id=None, config_entries=["entry_100_cn", "entry_200_cn"]),
                       self.device("2", "单独")])
        self.cache({"1": {"home_id": "h1", "home_name": "家", "room_name": "客厅", "urn": "urn:miot-spec-v2:device:lock:0001"},
                    "2": {"home_id": "h2", "home_name": "家"}})
        self.cache({"1": {"home_id": "h1", "home_name": "家"}}, "200_cn.dict")
        entries = json.loads((self.storage / "core.config_entries").read_text())["data"]["entries"]
        for entry in entries:
            entry["data"]["nick_name"] = "同名账号"
        self.entries(entries)
        result = self.run_script("--format", "table", "--no-color")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("账号：同名账号"), 2)
        self.assertEqual(result.stdout.count("家庭：家"), 3)
        self.assertEqual(result.stdout.count("┌"), 3)
        self.assertIn("客厅", result.stdout)
        self.assertIn("门锁", result.stdout)


if __name__ == "__main__":
    unittest.main()
