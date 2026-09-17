"""Bounded request protocol and serialized guest-channel state."""
import base64
import hmac
import json
import re
import struct
import threading
import time

MAX_REQUEST_BYTES = 64 * 1024
MAX_PNG_BYTES = 8 * 1024 * 1024
MAX_RESPONSE_BYTES = 12 * 1024 * 1024
TOKEN_RE = re.compile(r"[a-f0-9]{64}")
ID_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")
KEYS = {
    "Return", "BackSpace", "Tab", "Escape", "Delete", "Left", "Right",
    "Up", "Down", "Home", "End", "Page_Up", "Page_Down", "space",
    "ctrl+a", "ctrl+c", "ctrl+v", "ctrl+x", "ctrl+z", "ctrl+f", "ctrl+l",
}


class RequestError(ValueError):
    def __init__(self, code, message="Invalid request"):
        super().__init__(message)
        self.code = code
        self.public_message = message


class OperationFailure(RuntimeError):
    def __init__(self, diagnostic):
        super().__init__("Guest desktop operation failed")
        self.diagnostic = diagnostic


def diagnostic_for(exc, stage, started):
    if isinstance(exc, OperationFailure):
        return dict(exc.diagnostic)
    category = "operation_failed"
    exit_code = None
    if isinstance(exc, TimeoutError):
        category = "timeout"
    elif isinstance(exc, OSError):
        category = "os_error"
        value = getattr(exc, "winerror", None)
        exit_code = value if type(value) is int else None
    return {
        "category": category,
        "exception_type": type(exc).__name__,
        "stage": stage,
        "duration_ms": max(0, round((time.monotonic() - started) * 1000)),
        "exit_code": exit_code,
    }


def _object_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RequestError("duplicate_field")
        result[key] = value
    return result


def decode_request(data):
    if not isinstance(data, bytes) or not 0 < len(data) <= MAX_REQUEST_BYTES:
        raise RequestError("invalid_size")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_object_no_duplicates)
    except RequestError:
        raise
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise RequestError("invalid_json") from exc
    if not isinstance(value, dict):
        raise RequestError("invalid_shape")
    request_id = value.get("id")
    if not isinstance(request_id, str) or not ID_RE.fullmatch(request_id):
        raise RequestError("invalid_id")
    token = value.get("token")
    if not isinstance(token, str) or not 1 <= len(token) <= 512:
        raise RequestError("authentication_failed", "Authentication failed")
    if not isinstance(value.get("op"), str) or not 1 <= len(value["op"]) <= 32:
        raise RequestError("invalid_operation")
    return value


def validate_request(request, width, height):
    op = request["op"]
    common = {"id", "token", "op"}
    if op not in {"state", "control", "input", "screenshot"}:
        raise RequestError("unsupported_operation")
    if op in {"state", "screenshot"}:
        if set(request) != common:
            raise RequestError("unexpected_field")
        return request
    if op == "control":
        if set(request) != common | {"mode"} or request.get("mode") not in {"paused", "human", "agent"}:
            raise RequestError("invalid_control")
        return request

    action = request.get("action")
    actor = request.get("actor")
    if actor not in {"agent", "human"}:
        raise RequestError("invalid_actor")
    if action in {"click", "move"}:
        allowed = common | {"actor", "action", "x", "y"}
        if action == "click":
            allowed.add("button")
        if set(request) - allowed:
            raise RequestError("unexpected_field")
        x, y = request.get("x"), request.get("y")
        if type(x) is not int or type(y) is not int or not (0 <= x < width and 0 <= y < height):
            raise RequestError("invalid_coordinates")
        if action == "click" and (type(request.get("button", 1)) is not int or request.get("button", 1) not in {1, 2, 3}):
            raise RequestError("invalid_button")
    elif action == "key":
        if set(request) != common | {"actor", "action", "key"} or request.get("key") not in KEYS:
            raise RequestError("invalid_key")
    elif action == "type":
        text = request.get("text")
        if set(request) != common | {"actor", "action", "text"} or not isinstance(text, str) or not text or len(text) > 2000 or "\x00" in text:
            raise RequestError("invalid_text")
    else:
        raise RequestError("unsupported_action")
    return request


def response_ok(request_id, result):
    return {"id": request_id, "ok": True, "result": result}


def response_error(request_id, code, message="Request failed", diagnostic=None):
    error = {"code": code, "message": message}
    if diagnostic is not None:
        error["diagnostic"] = diagnostic
    return {"id": request_id, "ok": False, "error": error}


def encode_response(response):
    data = json.dumps(response, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_RESPONSE_BYTES:
        raise OperationFailure({
            "category": "response_too_large", "exception_type": "SizeLimit",
            "stage": "response_encode", "duration_ms": 0, "exit_code": None,
        })
    return struct.pack("!I", len(data)) + data


def _recv_exact(connection, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RequestError("truncated_frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_request(connection):
    size = struct.unpack("!I", _recv_exact(connection, 4))[0]
    if not 0 < size <= MAX_REQUEST_BYTES:
        raise RequestError("invalid_size")
    return decode_request(_recv_exact(connection, size))


def send_response(connection, response):
    connection.sendall(encode_response(response))


class GuestChannel:
    def __init__(self, backend, identity):
        self.backend = backend
        self.identity = dict(identity)
        self.lock = threading.RLock()
        self.mode = "paused"
        self.action_count = 0
        self.last_action_at = None
        self.last_error = None

    def _probe_locked(self):
        try:
            ready, status = self.backend.probe_ready()
        except Exception:
            ready, status = False, "desktop_unavailable"
        if not ready:
            self.mode = "paused"
        return bool(ready), status if isinstance(status, str) else "desktop_unavailable"

    def state(self):
        with self.lock:
            ready, status = self._probe_locked()
            started = time.monotonic()
            try:
                width, height = self.backend.dimensions()
            except Exception as exc:
                self.mode = "paused"
                self.last_error = diagnostic_for(exc, "desktop_dimensions", started)
                raise OperationFailure(self.last_error) from exc
            return {
                "identity": dict(self.identity),
                "mode": self.mode,
                "width": width,
                "height": height,
                "actions": self.action_count,
                "last_action_at": self.last_action_at,
                "last_error": self.last_error,
                "desktop_ready": ready,
                "desktop_status": status,
                "input_target": "private-windows-guest",
                "host_input_supported": False,
            }

    def control(self, mode):
        with self.lock:
            if mode == "paused":
                self.mode = "paused"
                return self.state()
            started = time.monotonic()
            ready, status = self._probe_locked()
            if not ready:
                diagnostic = {
                    "category": "desktop_not_ready", "exception_type": "DesktopGuard",
                    "stage": "control", "duration_ms": max(0, round((time.monotonic() - started) * 1000)),
                    "exit_code": None,
                }
                self.last_error = diagnostic
                raise OperationFailure(diagnostic)
            self.mode = mode
            self.last_error = None
            return self.state()

    def input(self, request):
        with self.lock:
            width, height = self.backend.dimensions()
            validate_request(request, width, height)
            if self.mode != request["actor"]:
                raise RequestError("input_disabled", "Input disabled for this actor")
            started = time.monotonic()
            try:
                ready, _ = self._probe_locked()
                if not ready:
                    raise OperationFailure({
                        "category": "desktop_not_ready", "exception_type": "DesktopGuard",
                        "stage": "input_guard", "duration_ms": 0, "exit_code": None,
                    })
                self.backend.perform(request)
            except Exception as exc:
                self.mode = "paused"
                stage = {"click": "pointer_click", "move": "pointer_move", "key": "key", "type": "text_type"}.get(request.get("action"), "input")
                self.last_error = diagnostic_for(exc, stage, started)
                raise OperationFailure(self.last_error) from exc
            self.action_count += 1
            self.last_action_at = time.time()
            self.last_error = None
            return self.state()

    def screenshot(self):
        with self.lock:
            started = time.monotonic()
            try:
                ready, _ = self._probe_locked()
                if not ready:
                    raise OperationFailure({
                        "category": "desktop_not_ready", "exception_type": "DesktopGuard",
                        "stage": "screenshot_guard", "duration_ms": 0, "exit_code": None,
                    })
                png = self.backend.screenshot_png()
                if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise ValueError("invalid png")
                if len(png) > MAX_PNG_BYTES:
                    raise OperationFailure({
                        "category": "image_too_large", "exception_type": "SizeLimit",
                        "stage": "screenshot_encode", "duration_ms": 0, "exit_code": None,
                    })
                if len(png) < 24:
                    raise ValueError("invalid png")
                width, height = struct.unpack("!II", png[16:24])
                if width <= 0 or height <= 0:
                    raise ValueError("invalid png dimensions")
            except Exception as exc:
                self.mode = "paused"
                self.last_error = diagnostic_for(exc, "screenshot", started)
                raise OperationFailure(self.last_error) from exc
            self.last_error = None
            return {"mime_type": "image/png", "data": base64.b64encode(png).decode("ascii"),
                    "width": width, "height": height}


def dispatch(request, expected_token, channel):
    request_id = request.get("id") if isinstance(request, dict) else None
    supplied = request.get("token", "") if isinstance(request, dict) else ""
    if not isinstance(supplied, str) or not hmac.compare_digest(supplied, expected_token):
        return response_error(request_id, "authentication_failed", "Authentication failed")
    try:
        state = channel.state()
        request = validate_request(request, state["width"], state["height"])
        op = request["op"]
        if op == "state":
            result = state
        elif op == "control":
            result = channel.control(request["mode"])
        elif op == "input":
            result = channel.input(request)
        else:
            result = channel.screenshot()
        return response_ok(request_id, result)
    except RequestError as exc:
        return response_error(request_id, exc.code, exc.public_message)
    except OperationFailure as exc:
        return response_error(request_id, "desktop_operation_failed", "Guest desktop operation failed", exc.diagnostic)
    except Exception as exc:
        diagnostic = diagnostic_for(exc, "dispatch", time.monotonic())
        return response_error(request_id, "internal_error", "Guest agent failed", diagnostic)
