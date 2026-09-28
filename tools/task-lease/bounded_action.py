"""Run a fixed local action with bounded output and a process deadline.

This module does not sandbox the action or guarantee that deliberately detached
descendants stop running. A timeout makes the action's external effects unknown.
"""

from __future__ import annotations

import json
import math
import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


OUTPUT_LIMIT = 16 * 1024
_CLEANUP_SECONDS = 0.75


@dataclass(frozen=True)
class ActionResult:
    exit_code: int | None
    timed_out: bool
    stdout: bytes
    stderr: bytes
    stdout_truncated: bool
    stderr_truncated: bool
    termination_uncertain: bool


class _Capture:
    def __init__(self, pipe):
        self.pipe = pipe
        self.data = bytearray()
        self.truncated = False
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        try:
            while True:
                chunk = self.pipe.read(4096)
                if not chunk:
                    break
                room = OUTPUT_LIMIT - len(self.data)
                if len(chunk) > room:
                    self.truncated = True
                if room:
                    self.data.extend(chunk[:room])
        except OSError:
            # A pipe may be forcibly closed during timeout cleanup.
            pass
        finally:
            self.done.set()
            self.pipe.close()


class _WindowsJob:
    """A new job containing the waiting worker and all ordinary descendants."""

    def __init__(self, process):
        import ctypes

        api = ctypes.WinDLL("kernel32", use_last_error=True)
        api.CreateJobObjectW.argtypes = (ctypes.c_void_p, ctypes.c_wchar_p)
        api.CreateJobObjectW.restype = ctypes.c_void_p
        api.AssignProcessToJobObject.argtypes = (ctypes.c_void_p, ctypes.c_void_p)
        api.AssignProcessToJobObject.restype = ctypes.c_int
        api.SetInformationJobObject.argtypes = (ctypes.c_void_p, ctypes.c_int,
                                                ctypes.c_void_p, ctypes.c_uint)
        api.SetInformationJobObject.restype = ctypes.c_int
        api.TerminateJobObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
        api.TerminateJobObject.restype = ctypes.c_int
        api.CloseHandle.argtypes = (ctypes.c_void_p,)
        api.CloseHandle.restype = ctypes.c_int
        self.api = api
        self.handle = api.CreateJobObjectW(None, None)
        if not self.handle:
            raise OSError(ctypes.get_last_error(), "CreateJobObjectW failed")
        if not self._set_kill_on_close():
            error = ctypes.get_last_error()
            self.close()
            raise OSError(error, "SetInformationJobObject failed")
        if not api.AssignProcessToJobObject(self.handle, int(process._handle)):
            error = ctypes.get_last_error()
            self.close()
            raise OSError(error, "AssignProcessToJobObject failed")

    def _set_kill_on_close(self):
        import ctypes

        class BasicLimit(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64),
                        ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", ctypes.c_uint32),
                        ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", ctypes.c_uint32),
                        ("Affinity", ctypes.c_size_t),
                        ("PriorityClass", ctypes.c_uint32),
                        ("SchedulingClass", ctypes.c_uint32)]

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class ExtendedLimit(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", BasicLimit),
                        ("IoInfo", IoCounters),
                        ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        info = ExtendedLimit()
        info.BasicLimitInformation.LimitFlags = 0x00002000  # KILL_ON_JOB_CLOSE
        return bool(self.api.SetInformationJobObject(
            self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)))

    def terminate(self):
        return bool(self.handle and self.api.TerminateJobObject(self.handle, 1))

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def _terminate_tree(process, job):
    if os.name == "nt":
        terminated = bool(job is not None and job.terminate())
        if process.poll() is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        return terminated
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        return True


def _worker():
    """Wait for parent authorization before creating the action process."""
    request = sys.stdin.buffer.readline()
    if not request:
        return 1
    spec = json.loads(request)
    child = subprocess.Popen(spec["argv"], cwd=spec["cwd"], env=spec["env"],
                             stdin=subprocess.DEVNULL, shell=False)
    return child.wait()


def run_action(argv: Sequence[str], *, cwd: str | os.PathLike[str],
               env: Mapping[str, str] | None, timeout_seconds: float) -> ActionResult:
    """Execute a fixed argv without a shell; return bytes capped per stream.

    The deadline covers process exit and pipe closure after worker startup;
    operating-system process creation itself cannot be strictly timed. Cleanup
    may take up to another 0.75 seconds. ``termination_uncertain`` means a process
    or pipe was still observed after cleanup; even when false, a timed-out
    action's external effects cannot be inferred from its exit code.
    """
    if (not argv or isinstance(argv, (str, bytes))
            or any(not isinstance(arg, str) or not arg for arg in argv)):
        raise ValueError("argv must be a nonempty sequence of nonempty strings")
    if (isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float))
            or not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= 8):
        raise ValueError("timeout_seconds must be finite and in (0, 8]")
    if env is not None and (any(not isinstance(k, str) or not isinstance(v, str)
                                for k, v in env.items())):
        raise ValueError("env must map strings to strings")

    fixed_argv = tuple(argv)
    fixed_env = None if env is None else dict(env)
    deadline = time.monotonic() + timeout_seconds
    process = subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__),
                                "--worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, shell=False, bufsize=0,
                               start_new_session=(os.name != "nt"))
    job = None
    cleanup_attempted = False
    try:
        if os.name == "nt":
            try:
                job = _WindowsJob(process)
            except OSError:
                # The worker is still waiting on stdin; never run uncontained.
                process.stdin.close()
                try:
                    process.kill()
                    process.wait(timeout=_CLEANUP_SECONDS)
                finally:
                    process.stdout.close()
                    process.stderr.close()
                raise
        stdout = _Capture(process.stdout)
        stderr = _Capture(process.stderr)
        request = json.dumps({"argv": fixed_argv, "cwd": os.fspath(Path(cwd)),
                              "env": fixed_env}).encode("utf-8") + b"\n"
        try:
            process.stdin.write(request)
            process.stdin.close()
        except BrokenPipeError:
            pass
        while time.monotonic() < deadline:
            if process.poll() is not None and stdout.done.is_set() and stderr.done.is_set():
                break
            time.sleep(min(0.01, max(0, deadline - time.monotonic())))
        timed_out = not (process.poll() is not None and stdout.done.is_set()
                         and stderr.done.is_set())
        # Also clear descendants which closed their streams before returning.
        cleanup_attempted = True
        tree_terminated = _terminate_tree(process, job)
        if timed_out:
            cleanup_end = time.monotonic() + _CLEANUP_SECONDS
            while time.monotonic() < cleanup_end:
                if process.poll() is not None and stdout.done.is_set() and stderr.done.is_set():
                    break
                time.sleep(0.01)
        # Never join an unbounded pipe reader; detached descendants may retain it.
        return ActionResult(process.poll(), timed_out, bytes(stdout.data),
                            bytes(stderr.data), stdout.truncated, stderr.truncated,
                            not tree_terminated or process.poll() is None or not stdout.done.is_set()
                            or not stderr.done.is_set())
    finally:
        if not cleanup_attempted:
            _terminate_tree(process, job)
        if job is not None:
            job.close()


if __name__ == "__main__" and sys.argv[1:] == ["--worker"]:
    sys.exit(_worker())
