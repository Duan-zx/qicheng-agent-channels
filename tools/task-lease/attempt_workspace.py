"""Prepare a detached Git worktree and separate build directory per attempt.

This is a standalone local CLI and an optional lease-broker component.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

if os.name == "nt":
    import msvcrt
else:
    import fcntl


_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
_REF = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}\Z")
_MARKER = ".qicheng-attempt.json"


class PreparationError(Exception):
    pass


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, timeout=60, check=False)
    if result.returncode:
        raise PreparationError(f"git {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _plain_path(value: str, label: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise PreparationError(f"{label} must be absolute")
    # Reject links, including Windows junctions, before resolving them.
    for part in (path, *path.parents):
        if part.is_symlink() or (part.exists() and
                bool(getattr(part.lstat(), "st_file_attributes", 0) & 0x400)):
            raise PreparationError(f"{label} contains a link or junction")
    return path.resolve()


def _separate(a: Path, b: Path) -> bool:
    return a != b and a not in b.parents and b not in a.parents


@contextmanager
def _lock(root: Path):
    path = root / ".qicheng-prepare.lock"
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise PreparationError("unsafe lock path")
    with path.open("a+b") as stream:
        if stream.tell() == 0 and path.stat().st_size == 0:
            stream.write(b"\0")
            stream.flush()
        deadline = time.monotonic() + 30
        while True:
            try:
                stream.seek(0)
                if os.name == "nt":
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise PreparationError("workspace lock timed out") from None
                time.sleep(0.05)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def prepare(source: str, worktree_root: str, build_root: str,
            task_id: str, attempt_id: str, ref: str = "HEAD") -> dict:
    for label, value in (("task_id", task_id), ("attempt_id", attempt_id)):
        if not isinstance(value, str) or not _ID.fullmatch(value):
            raise PreparationError(f"invalid {label}")
    source_path = _plain_path(source, "source")
    work_root = _plain_path(worktree_root, "worktree_root")
    output_root = _plain_path(build_root, "build_root")
    if not all(path.is_dir() for path in (source_path, work_root, output_root)):
        raise PreparationError("source and both roots must already exist")
    if not (_separate(source_path, work_root) and
            _separate(source_path, output_root) and
            _separate(work_root, output_root)):
        raise PreparationError("source and roots must not overlap")
    if Path(_git(source_path, "rev-parse", "--show-toplevel")).resolve() != source_path:
        raise PreparationError("source must be a Git checkout root")
    if not isinstance(ref, str) or not _REF.fullmatch(ref):
        raise PreparationError("invalid ref")
    commit = _git(source_path, "rev-parse", "--verify", f"{ref}^{{commit}}")
    work = work_root / task_id / attempt_id
    build = output_root / task_id / attempt_id
    marker = build / _MARKER
    record = dict(task_id=task_id, attempt_id=attempt_id,
                  source=str(source_path), commit=commit,
                  worktree=str(work), build_output=str(build))
    with _lock(work_root):
        # Recheck inside the lock; a sibling caller may just have created these.
        for path in (work.parent, work, build.parent, build, marker):
            if path.is_symlink() or (path.exists() and
                    bool(getattr(path.lstat(), "st_file_attributes", 0) & 0x400)):
                raise PreparationError("attempt path contains a link or junction")
        if work.exists() or build.exists():
            if not (work.is_dir() and build.is_dir() and marker.is_file()):
                raise PreparationError("attempt path exists without a complete record")
            try:
                existing = json.loads(marker.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise PreparationError("attempt record is unreadable") from exc
            if existing != record:
                raise PreparationError("attempt ID conflicts with an existing binding")
            if (_git(work, "rev-parse", "--is-inside-work-tree") != "true" or
                    _git(work, "rev-parse", "HEAD") != commit or
                    _git(work, "rev-parse", "--abbrev-ref", "HEAD") != "HEAD"):
                raise PreparationError("existing worktree differs from the record")
            listed = _git(source_path, "worktree", "list", "--porcelain")
            entries = (block.splitlines() for block in listed.split("\n\n"))
            registered = any(
                len(lines) >= 3 and lines[0].startswith("worktree ") and
                Path(lines[0][9:]).resolve() == work and
                lines[1] == f"HEAD {commit}" and "detached" in lines[2:]
                for lines in entries)
            if not registered:
                raise PreparationError("existing detached worktree is not registered")
            return record
        work.parent.mkdir(exist_ok=True)
        build.parent.mkdir(exist_ok=True)
        add_started = False
        try:
            add_started = True
            _git(source_path, "worktree", "add", "--detach", "--", str(work), commit)
            build.mkdir()
            marker.write_text(json.dumps(record, ensure_ascii=True, sort_keys=True), encoding="utf-8")
            return record
        except Exception:
            # Git refuses to remove a dirty worktree. Preserve any new user data,
            # including partial files left by Git or a concurrent local writer.
            if add_started and work.exists():
                try:
                    _git(source_path, "worktree", "remove", "--", str(work))
                except PreparationError:
                    pass
            if build.exists() and not any(build.iterdir()):
                build.rmdir()
            raise


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--worktree-root", required=True)
    parser.add_argument("--build-root", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--attempt-id", required=True)
    parser.add_argument("--ref", default="HEAD")
    args = parser.parse_args(argv)
    try:
        result = prepare(args.source, args.worktree_root, args.build_root,
                         args.task_id, args.attempt_id, args.ref)
    except (PreparationError, OSError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, **result}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
