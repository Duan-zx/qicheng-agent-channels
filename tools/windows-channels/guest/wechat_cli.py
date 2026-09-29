"""Fixed WeChat DevTools CLI adapter for a trusted Windows guest.

The host must load the configuration from a protected local source. Request data
may select only the configured project ID and a fixed action. This module is not
itself a remote entry point; a future transport must enforce a guest lease.
"""

from dataclasses import dataclass
import hashlib
import json
import ntpath
import re
import subprocess
import threading
import time
from typing import Mapping


# Reserve up to three seconds for bounded cleanup under an eight-second budget.
TIMEOUT_SECONDS = 5
MAX_OUTPUT_BYTES = 4096
PROJECT_ID_RE = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")


def _drive_absolute(path):
    if (not isinstance(path, str) or not path
            or any(char in path for char in '\x00"&|<>^%!\r\n')):
        return False
    drive, tail = ntpath.splitdrive(path)
    return bool(re.fullmatch(r"[A-Za-z]:", drive) and tail.startswith("\\")
                and not path.startswith(("\\\\", "\\\\?\\", "\\\\.\\"))
                and ntpath.normpath(path) == path)


@dataclass(frozen=True)
class TrustedWechatConfig:
    project_id: str
    guest_project_path: str
    cli_bat_path: str
    service_port: int

    def __post_init__(self):
        if (not isinstance(self.project_id, str)
                or not PROJECT_ID_RE.fullmatch(self.project_id)
                or not _drive_absolute(self.guest_project_path)
                or not _drive_absolute(self.cli_bat_path)
                or not self.cli_bat_path.lower().endswith("\\cli.bat")
                or type(self.service_port) is not int
                or not 1 <= self.service_port <= 65535):
            raise ValueError("invalid_config")

    @classmethod
    def from_mapping(cls, value):
        if not isinstance(value, Mapping) or set(value) != {
            "project_id", "guest_project_path", "cli_bat_path", "service_port"
        }:
            raise ValueError("invalid_config")
        return cls(value["project_id"], value["guest_project_path"],
                   value["cli_bat_path"], value["service_port"])


def load_trusted_config(path):
    """Load one startup-only config path supplied by the guest operator."""
    return load_trusted_config_and_digest(path)[0]


def load_trusted_config_and_digest(path):
    """Parse and hash the same bounded raw JSON bytes in one startup read."""
    with open(path, "rb") as source:
        raw = source.read(4097)
    if len(raw) > 4096:
        raise ValueError("invalid_config")
    try:
        config = TrustedWechatConfig.from_mapping(json.loads(raw.decode("utf-8")))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid_config") from exc
    return config, hashlib.sha256(raw).hexdigest()


def _error(code):
    return {"ok": False, "error": {"code": code}}


def _kill_tree(process):
    """Best-effort Windows process-tree stop; caller reports cleanup uncertainty."""
    try:
        subprocess.run(
            ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
            shell=False, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=2, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass
    if process.poll() is None:
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.wait(timeout=1)
    except (OSError, subprocess.TimeoutExpired):
        pass


def check_login(config, request):
    """Return only login status or a fixed error code; never CLI output."""
    failure = _validate(config, request, "check-login")
    if failure:
        return failure
    output, failure = _run_cli(config, ["islogin", "--port", str(config.service_port)])
    if failure:
        return failure
    try:
        # The official CLI may print fixed startup lines before its JSON result.
        lines = output.decode("utf-8").splitlines()
        matches = [json.loads(line) for line in lines if line.lstrip().startswith("{")]
        values = [item["login"] for item in matches
                  if isinstance(item, dict) and set(item) == {"login"}
                  and type(item["login"]) is bool]
    except (UnicodeError, json.JSONDecodeError):
        return _error("invalid_output")
    if len(values) != 1:
        return _error("invalid_output")
    return {"ok": True, "result": {"login": values[0]}}


def open_project(config, request):
    """Attempt the configured project; require verified CLI receipt for success."""
    failure = _validate(config, request, "open")
    if failure:
        return failure
    _, failure = _run_cli(config, ["open", "--project", config.guest_project_path,
                                   "--port", str(config.service_port)])
    if failure:
        return failure
    # The observed installation has supplied only a failure response so far.
    # A zero exit (including empty output or an unverified "success" string)
    # cannot establish that the IDE accepted the project. Add an allowlisted
    # success parser only after a real CLI receipt has been retained and tested.
    return _error("indeterminate_output")


def _validate(config, request, action):
    if not isinstance(config, TrustedWechatConfig):
        return _error("invalid_config")
    if (not isinstance(request, dict) or set(request) != {"project_id", "action"}
            or request.get("project_id") != config.project_id
            or request.get("action") != action):
        return _error("invalid_request")
    return None


def _reported_cli_error(output):
    for line in output.splitlines():
        if re.search(rb"(?i)^\s*\[error\](?:\s|$)", line):
            return True
        stripped = line.strip()
        if stripped.startswith(b"{"):
            code = re.search(rb"(?:^|[,\s{])(?:[\"']?code[\"']?)\s*:\s*[\"']?([0-9]+)[\"']?",
                             stripped, re.IGNORECASE)
            if code and int(code.group(1)) != 0:
                return True
    return False


def _run_cli(config, arguments):
    argv = [config.cli_bat_path, *arguments]
    try:
        process = subprocess.Popen(
            argv, cwd=config.guest_project_path, shell=False,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except OSError:
        return None, _error("start_failed")

    output = bytearray()
    overflow = threading.Event()

    def read_output():
        try:
            while True:
                chunk = process.stdout.read(min(1024, MAX_OUTPUT_BYTES + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > MAX_OUTPUT_BYTES:
                    overflow.set()
                    break
        except OSError:
            overflow.set()

    reader = threading.Thread(target=read_output, daemon=True)
    reader.start()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    try:
        while reader.is_alive() and not overflow.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_tree(process)
                return None, _error("timeout")
            reader.join(min(remaining, 0.05))
        if overflow.is_set():
            _kill_tree(process)
            return None, _error("output_too_large")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            _kill_tree(process)
            return None, _error("timeout")
        exit_code = process.wait(timeout=remaining)
    except (OSError, subprocess.TimeoutExpired):
        _kill_tree(process)
        return None, _error("timeout")
    finally:
        # Closing a pipe while a descendant still owns its write handle may
        # block. The daemon reader is intentionally left alone in that case.
        if process.stdout is not None and not reader.is_alive():
            process.stdout.close()

    if exit_code != 0:
        return None, _error("cli_failed")
    # cli.bat can exit 0 even when its own response starts with
    # "[error] {code:10,...}". Keep diagnostics fixed; never return CLI text.
    if _reported_cli_error(output):
        return None, _error("cli_reported_error")
    return bytes(output), None
