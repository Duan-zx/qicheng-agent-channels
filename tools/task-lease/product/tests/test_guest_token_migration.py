import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "runtime" / "Migrate-GuestTokens.py"
spec = importlib.util.spec_from_file_location("guest_token_migration", SCRIPT)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class GuestTokenMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.data = self.root / "private"
        self.data.mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        self.channel_token = self.root / "source-channel.token"
        self.channel_token.write_text("1" * 64, encoding="ascii")
        self.broker_token = self.root / "broker-guest.token"
        self.broker_token.write_text("2" * 64, encoding="ascii")
        self.host_path = (self.data / "channels.json" if
                          self._testMethodName.startswith("test_in_place") else
                          self.root / "source-channels.json")
        self.host_path.write_text(json.dumps({"schema_version": 1, "projects": {
            "guest-a": {"vm_id": "11111111-1111-4111-8111-111111111111",
                        "bios_uuid": "22222222-2222-4222-8222-222222222222",
                        "token_file": str(self.channel_token)}}}), encoding="utf-8")
        self.entry = {"channel_id": "channel-a", "endpoint_id": "guest-a",
                      "tool_id": "windows-guest", "project_id": "project-a",
                      "project_path": str(self.project), "guest": {
                          "host_config_path": str(self.host_path), "project": "guest-a",
                          "broker_token_file": str(self.broker_token)}}
        (self.data / "config.json").write_text(json.dumps({"channels": [self.entry]}), encoding="utf-8")
        (self.data / "broker.token").write_text("3" * 64, encoding="ascii")
        from broker import Broker
        Broker(config_path=self.data / "config.json", credential_path=self.data / "broker.token",
               db_path=self.data / "leases.db")
        self.key = (self.data / "leases.db.key").read_bytes()
        self.db = sqlite3.connect(self.data / "leases.db")
        self.addCleanup(self.db.close)
        old = self.db.execute("SELECT fingerprint FROM guest_bindings WHERE channel_id='channel-a'").fetchone()[0]
        self.db.execute("""INSERT INTO guest_input_attempts
                        (channel_id, request_id, action_id, fingerprint, status, acked)
                        VALUES (?, ?, ?, ?, ?, ?)""",
                        ("channel-a", "request-1", "action-1", old, "success", 1))
        self.db.commit()

    def test_plan_and_apply_preserve_acked_history_and_backup(self):
        old_config = (self.data / "config.json").read_bytes()
        plan = migration.migrate(self.data, self.host_path, False, False)
        self.assertEqual(plan["bindingUpdates"], 1)
        self.assertEqual((self.data / "config.json").read_bytes(), old_config)
        self.assertFalse((self.data / "channels.json").exists())
        result = migration.migrate(self.data, self.host_path, True, True)
        self.assertEqual(result["status"], "migrated")
        backup = Path(result["backupDirectory"])
        self.assertEqual((backup / "config.json").read_bytes(), old_config)
        self.assertEqual((backup / "leases.db.key").read_bytes(), self.key)
        self.assertTrue((backup / "leases.db").is_file())
        new_config = json.loads((self.data / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(new_config["channels"][0]["guest"]["host_config_path"], str(self.data / "channels.json"))
        target = Path(json.loads((self.data / "channels.json").read_text(encoding="utf-8"))["projects"]["guest-a"]["token_file"])
        self.assertEqual(target.read_text(encoding="ascii"), "1" * 64)
        history = self.db.execute("SELECT fingerprint, status, acked FROM guest_input_attempts").fetchone()
        self.assertEqual(history[1:], ("success", 1))
        self.assertNotEqual(history[0], self.db.execute("SELECT fingerprint FROM guest_bindings").fetchone()[0])
        again = migration.migrate(self.data, self.data / "channels.json", True, True)
        self.assertEqual(again["bindingUpdates"], 0)
        self.assertEqual(again["tokenCopies"], 0)

    def test_refuses_dirty_and_unconfirmed_without_changes(self):
        config = (self.data / "config.json").read_bytes()
        self.db.execute("INSERT INTO guest_dirty VALUES ('guest-a', 'channel-a', 'request-1')")
        self.db.commit()
        with self.assertRaisesRegex(RuntimeError, "dirty"):
            migration.migrate(self.data, self.host_path, True, True)
        self.db.execute("DELETE FROM guest_dirty")
        self.db.execute("UPDATE guest_input_attempts SET acked=0")
        self.db.commit()
        with self.assertRaisesRegex(RuntimeError, "unconfirmed"):
            migration.migrate(self.data, self.host_path, True, True)
        self.assertEqual((self.data / "config.json").read_bytes(), config)
        self.assertFalse((self.data / "channels.json").exists())

    def test_refuses_remaining_lease_and_fingerprint_mismatch(self):
        self.db.execute("INSERT INTO leases(channel_id, generation, expires_at) VALUES ('channel-a', 1, 1)")
        self.db.commit()
        with self.assertRaisesRegex(RuntimeError, "Lease rows remain"):
            migration.migrate(self.data, self.host_path, True, True)
        self.db.execute("DELETE FROM leases")
        self.db.execute("UPDATE guest_bindings SET fingerprint=?", ("0" * 64,))
        self.db.commit()
        with self.assertRaisesRegex(RuntimeError, "fingerprint"):
            migration.migrate(self.data, self.host_path, True, True)
        self.assertFalse((self.data / "channels.json").exists())

    def test_cli_plan_never_prints_token(self):
        process = subprocess.run([sys.executable, "-B", str(SCRIPT), "--data-root",
                                  str(self.data), "--source-host-config", str(self.host_path)],
                                 text=True, capture_output=True, check=True)
        self.assertEqual(json.loads(process.stdout)["status"], "migration-plan")
        self.assertNotIn("1" * 64, process.stdout + process.stderr)
        self.assertNotIn("2" * 64, process.stdout + process.stderr)

    def test_in_place_host_update_and_exception_rollback(self):
        old_host = self.host_path.read_bytes()
        old_config = (self.data / "config.json").read_bytes()
        old_fp = self.db.execute("SELECT fingerprint FROM guest_bindings").fetchone()[0]
        original_write = migration.atomic_write

        def fail_config(path, content):
            if path == self.data / "config.json":
                raise RuntimeError("injected config write failure")
            return original_write(path, content)

        with mock.patch.object(migration, "atomic_write", side_effect=fail_config):
            with self.assertRaisesRegex(RuntimeError, "injected"):
                migration.migrate(self.data, self.host_path, True, True)
        self.assertEqual(self.host_path.read_bytes(), old_host)
        self.assertEqual((self.data / "config.json").read_bytes(), old_config)
        self.assertEqual(self.db.execute("SELECT fingerprint FROM guest_bindings").fetchone()[0], old_fp)

        result = migration.migrate(self.data, self.host_path, True, True)
        self.assertEqual(result["status"], "migrated")
        self.assertNotEqual(self.host_path.read_bytes(), old_host)
        host = json.loads(self.host_path.read_text(encoding="utf-8"))
        self.assertEqual(Path(host["projects"]["guest-a"]["token_file"]).parent,
                         self.data / "guest-tokens")
        self.assertNotEqual(self.db.execute("SELECT fingerprint FROM guest_bindings").fetchone()[0], old_fp)
        self.assertEqual(migration.migrate(self.data, self.host_path, False, False)["bindingUpdates"], 0)
        from broker import Broker
        restarted = Broker(config_path=self.data / "config.json",
                           credential_path=self.data / "broker.token",
                           db_path=self.data / "leases.db")
        self.assertEqual(restarted.channels["channel-a"].guest["binding"]["token_file"],
                         Path(host["projects"]["guest-a"]["token_file"]))


if __name__ == "__main__":
    unittest.main()
