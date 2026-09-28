"""Preview or clear one uncertain fixed-action gate after offline inspection."""

from __future__ import annotations

import argparse
import json
import sqlite3
import time
from pathlib import Path

from lease import LeaseStore


def reconcile(db_path: str, endpoint_id: str, *, apply: bool = False,
              broker_stopped: bool = False,
              action_stopped_verified: bool = False) -> dict:
    LeaseStore._id(endpoint_id, "endpoint_id")
    path = Path(db_path)
    if not path.is_absolute() or not path.is_file() or not path.with_name(
            path.name + ".key").is_file():
        raise ValueError("existing absolute lease database and key are required")
    if apply and not (broker_stopped and action_stopped_verified):
        raise ValueError("apply requires broker-stopped and action-stopped verification")
    connection = sqlite3.connect(path.as_uri() + ("" if apply else "?mode=ro"),
                                 uri=True, isolation_level=None, timeout=5)
    connection.row_factory = sqlite3.Row
    try:
        if apply:
            connection.execute("BEGIN IMMEDIATE")
        columns = {row["name"] for row in connection.execute(
            "PRAGMA table_info(action_dirty)")}
        if columns != {"endpoint_id", "channel_id", "request_id", "fingerprint"}:
            raise RuntimeError("action dirty schema is unavailable")
        row = connection.execute("SELECT channel_id, request_id FROM action_dirty "
                                 "WHERE endpoint_id=?", (endpoint_id,)).fetchone()
        if row is None:
            return {"status": "already-clear", "endpoint_id": endpoint_id}
        active = connection.execute("""SELECT 1 FROM leases
            JOIN requests USING(generation)
            WHERE requests.endpoint_id=? AND leases.expires_at>? LIMIT 1""",
            (endpoint_id, time.time())).fetchone()
        if active is not None:
            raise RuntimeError("active lease must finish before reconciliation")
        if apply:
            connection.execute("DELETE FROM action_dirty WHERE endpoint_id=?",
                               (endpoint_id,))
            connection.commit()
        return {"status": "cleared" if apply else "reconcile-plan",
                "endpoint_id": endpoint_id, "channel_id": row["channel_id"],
                "request_id": row["request_id"]}
    finally:
        connection.close()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True)
    parser.add_argument("--endpoint-id", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--broker-stopped", action="store_true")
    parser.add_argument("--action-stopped-verified", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = reconcile(args.db, args.endpoint_id, apply=args.apply,
                           broker_stopped=args.broker_stopped,
                           action_stopped_verified=args.action_stopped_verified)
    except (ValueError, RuntimeError, sqlite3.Error, OSError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1
    print(json.dumps({"ok": True, **result}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
