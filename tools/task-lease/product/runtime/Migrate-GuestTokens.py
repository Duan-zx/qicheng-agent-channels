"""Offline, explicit migration of Windows guest channel token paths.

No token value is written to stdout or an exception. Run through the PowerShell
wrapper, which applies a private Windows ACL to DataRoot before --apply.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import secrets
import shutil
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

def fail(message: str) -> None:
    raise RuntimeError(message)


def token(path: Path) -> str:
    try:
        value = path.read_text(encoding="ascii").strip()
    except OSError:
        fail("A required channel token cannot be read.")
    if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        fail("A required channel token is invalid.")
    return value


def fingerprint(key: bytes, entry: dict, host_path: Path, project: str,
                binding: dict, broker_token_path: Path, channel_token: str | None = None) -> str:
    value = {
        "channel_id": entry["channel_id"], "endpoint_id": entry["endpoint_id"],
        "tool_id": entry["tool_id"], "project_id": entry["project_id"],
        "project_path": str(Path(entry["project_path"]).resolve()),
        "host_config_path": str(host_path), "guest_project": project,
        "vm_id": binding["vm_id"], "bios_uuid": binding["bios_uuid"],
        "channel_token_file": str(Path(binding["token_file"]).resolve()),
        "channel_token": channel_token or token(Path(binding["token_file"])),
        "broker_token_file": str(broker_token_path),
        "broker_token": token(broker_token_path),
    }
    encoded = json.dumps(value, ensure_ascii=True, sort_keys=True,
                         separators=(",", ":")).encode("utf-8")
    return hmac.new(key, encoded, hashlib.sha256).hexdigest()


def atomic_write(path: Path, content: bytes) -> None:
    temporary = path.with_name(path.name + ".pending-" + secrets.token_hex(8))
    try:
        with temporary.open("xb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def table_exists(db: sqlite3.Connection, table: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                      (table,)).fetchone() is not None


def migrate(data_root: Path, source_host: Path, apply: bool, broker_stopped: bool) -> dict:
    data_root = data_root.resolve()
    source_host = source_host.resolve()
    config_path = data_root / "config.json"
    target_host = data_root / "channels.json"
    db_path = data_root / "leases.db"
    key_path = data_root / "leases.db.key"
    for path in (config_path, source_host, db_path, key_path):
        if not path.is_file():
            fail("Required private config, host config, database or database key is missing.")
    if apply and not broker_stopped:
        fail("--apply requires --broker-stopped after stopping the broker.")
    key = key_path.read_bytes()
    if len(key) != 32:
        fail("Database key is invalid.")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    host = json.loads(source_host.read_text(encoding="utf-8"))
    if not isinstance(config.get("channels"), list) or not isinstance(host.get("projects"), dict):
        fail("Unsupported channel or host config.")
    # Use the exact validation and path normalization used by the packaged host.
    from guest_bridge import windows_host
    read_config, _ = windows_host()
    old_bindings = read_config(source_host)
    new_config = json.loads(json.dumps(config))
    new_host = json.loads(json.dumps(host))
    # Moving a host config changes the base for any relative paths. Preserve
    # unrelated projects' meaning even though this migration does not copy them.
    for project_name, binding in old_bindings.items():
        new_host["projects"][project_name]["token_file"] = str(binding["token_file"])
        if "human_token_file" in binding:
            new_host["projects"][project_name]["human_token_file"] = str(binding["human_token_file"])
    moves: dict[Path, Path] = {}
    changes: dict[str, tuple[str, str]] = {}
    seen: set[str] = set()
    for entry in new_config["channels"]:
        channel_id = entry.get("channel_id")
        if not isinstance(channel_id, str) or channel_id in seen:
            fail("Channel IDs must be unique.")
        seen.add(channel_id)
        guest = entry.get("guest")
        if not isinstance(guest, dict) or Path(guest["host_config_path"]).resolve() != source_host:
            continue
        project = guest["project"]
        if project not in old_bindings:
            fail("Guest project is absent from host config.")
        old_binding = old_bindings[project]
        source_token = Path(old_binding["token_file"]).resolve()
        destination = data_root / "guest-tokens" / (hashlib.sha256(project.encode("utf-8")).hexdigest()[:24] + ".token")
        if source_token != destination:
            if destination.exists() and token(destination) != token(source_token):
                fail("Existing private channel token differs from source.")
            moves[source_token] = destination
        new_host["projects"][project]["token_file"] = str(destination)
        guest["host_config_path"] = str(target_host)
        broker_token = Path(guest["broker_token_file"]).resolve()
        new_binding = dict(old_binding, token_file=destination)
        old_fp = fingerprint(key, entry, source_host, project, old_binding, broker_token)
        new_fp = fingerprint(key, entry, target_host, project, new_binding, broker_token,
                             token(source_token))
        changes[channel_id] = (old_fp, new_fp)
    if not changes:
        fail("No guest channel references the specified host config.")
    new_host_bytes = (json.dumps(new_host, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    new_config_bytes = (json.dumps(new_config, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if target_host.exists() and target_host != source_host and target_host.read_bytes() != new_host_bytes:
        fail("Target private channels.json already differs; resolve it manually.")
    db = sqlite3.connect("file:" + db_path.as_posix() + "?mode=rw", uri=True, isolation_level=None, timeout=2)
    backup_dir = None
    try:
        db.execute("PRAGMA busy_timeout=2000")
        for name in ("guest_bindings", "leases", "guest_dirty", "guest_input_attempts"):
            if not table_exists(db, name):
                fail("Guest database schema is incomplete; use offline manual reconciliation.")
        db.execute("BEGIN EXCLUSIVE" if apply else "BEGIN")
        if db.execute("SELECT 1 FROM leases LIMIT 1").fetchone():
            fail("Lease rows remain; release or reconcile them before migration.")
        if db.execute("SELECT 1 FROM guest_dirty LIMIT 1").fetchone():
            fail("Guest dirty state remains; reconcile it before migration.")
        if db.execute("SELECT 1 FROM guest_input_attempts WHERE status <> 'success' OR acked <> 1 LIMIT 1").fetchone():
            fail("An unconfirmed or uncertain guest input remains.")
        stored = dict(db.execute("SELECT channel_id, fingerprint FROM guest_bindings"))
        if not set(changes) <= set(stored):
            fail("Database lacks a migration target guest binding.")
        updates = {}
        for channel_id, (old_fp, new_fp) in changes.items():
            if not (hmac.compare_digest(stored[channel_id], old_fp) or
                    hmac.compare_digest(stored[channel_id], new_fp)):
                fail("Stored guest fingerprint does not match the current or target config.")
            if not hmac.compare_digest(stored[channel_id], new_fp):
                updates[channel_id] = new_fp
        result = {"status": "migration-plan", "channels": sorted(changes),
                  "tokenCopies": len(moves), "bindingUpdates": len(updates),
                  "applyRequested": apply, "backupDirectory": None}
        if not apply:
            db.rollback()
            return result
        # A stopped broker is required: SQLite locks cannot detect a process
        # that has opened the DB but is idle between requests.
        db.rollback()
        backup_dir = data_root / "migration-backups" / ("guest-tokens-" + secrets.token_hex(8))
        backup_dir.mkdir(parents=True, exist_ok=False)
        # The DB backup uses SQLite, so committed WAL pages are included.
        backup_db = sqlite3.connect(backup_dir / "leases.db")
        try:
            db.backup(backup_db)
        finally:
            backup_db.close()
        for original, name in ((key_path, "leases.db.key"), (config_path, "config.json"),
                               (source_host, "source-channels.json")):
            shutil.copy2(original, backup_dir / name)
        db.execute("BEGIN EXCLUSIVE")
        if (db.execute("SELECT 1 FROM leases LIMIT 1").fetchone() or
                db.execute("SELECT 1 FROM guest_dirty LIMIT 1").fetchone() or
                db.execute("SELECT 1 FROM guest_input_attempts WHERE status <> 'success' OR acked <> 1 LIMIT 1").fetchone() or
                dict(db.execute("SELECT channel_id, fingerprint FROM guest_bindings")) != stored):
            fail("Database changed during backup; migration rejected.")
        for source, destination in moves.items():
            destination.parent.mkdir(parents=True, exist_ok=True)
            if not destination.exists():
                atomic_write(destination, source.read_bytes())
            if token(destination) != token(source):
                fail("Copied channel token failed verification.")
        replaced_host = False
        replaced_config = False
        try:
            if ((target_host == source_host and target_host.read_bytes() != new_host_bytes) or
                    (target_host != source_host and not target_host.exists())):
                atomic_write(target_host, new_host_bytes)
                replaced_host = True
            for channel_id, new_fp in updates.items():
                db.execute("UPDATE guest_bindings SET fingerprint=? WHERE channel_id=?",
                           (new_fp, channel_id))
            if config_path.read_bytes() != new_config_bytes:
                atomic_write(config_path, new_config_bytes)
                replaced_config = True
            db.commit()
        except BaseException:
            db.rollback()
            if replaced_config:
                atomic_write(config_path, (backup_dir / "config.json").read_bytes())
            if replaced_host:
                if target_host == source_host:
                    atomic_write(source_host, (backup_dir / "source-channels.json").read_bytes())
                else:
                    target_host.unlink(missing_ok=True)
            raise
        result["status"] = "migrated"
        result["backupDirectory"] = str(backup_dir)
        return result
    finally:
        db.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--source-host-config", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--broker-stopped", action="store_true")
    args = parser.parse_args()
    try:
        print(json.dumps(migrate(args.data_root, args.source_host_config,
                                 args.apply, args.broker_stopped)))
    except Exception as error:
        # Avoid embedding paths or OS exception text; either may reveal private
        # information. The operator can inspect the saved backup separately.
        print(json.dumps({"status": "rejected", "reason": str(error) if isinstance(error, RuntimeError) else "Migration failed; inspect private files."}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
