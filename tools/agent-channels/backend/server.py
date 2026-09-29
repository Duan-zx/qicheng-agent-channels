"""Input/screenshot endpoint for one private Linux X11 display, never host input.
Prototype: not a hostile-code sandbox; application network egress is unrestricted.
"""
import hmac
import json
import os
import re
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 16384
KEYS = {"Return", "BackSpace", "Tab", "Escape", "Delete", "Left", "Right",
        "Up", "Down", "Home", "End", "Page_Up", "Page_Down", "space",
        "ctrl+a", "ctrl+c", "ctrl+v", "ctrl+x", "ctrl+z", "ctrl+f", "ctrl+l",
        "ctrl+r", "ctrl+t", "ctrl+w", "ctrl+shift+t"}

class Invalid(ValueError): pass
class Conflict(RuntimeError): pass

def _lease_request(data, *, ttl):
    owner, generation, nonce = data.get("owner"), data.get("generation"), data.get("nonce")
    if not isinstance(owner, str) or not owner or len(owner) > 128:
        raise Invalid("Invalid lease owner")
    if type(generation) is not int or generation < 1:
        raise Invalid("Invalid lease generation")
    if not isinstance(nonce, str) or not nonce or len(nonce) > 256:
        raise Invalid("Invalid lease nonce")
    if ttl:
        seconds = data.get("ttl_seconds")
        if type(seconds) is not int or not 1 <= seconds <= 300:
            raise Invalid("Invalid lease TTL")
        return owner, generation, nonce, seconds
    return owner, generation, nonce

class InputFailure(RuntimeError):
    """An input failure whose public details contain no user-controlled text."""
    def __init__(self, diagnostic):
        super().__init__("Private desktop input failed")
        self.diagnostic = diagnostic

def _input_diagnostic(exc, stage, started):
    if isinstance(exc, InputFailure):
        return exc.diagnostic
    category = "unexpected_error"
    exit_code = None
    if isinstance(exc, (subprocess.TimeoutExpired, TimeoutError)):
        category = "timeout"
    elif isinstance(exc, subprocess.CalledProcessError):
        category = "process_exit"
        exit_code = exc.returncode if type(exc.returncode) is int else None
    elif isinstance(exc, OSError):
        category = "process_start"
    return {
        "category": category,
        "exception_type": type(exc).__name__,
        "stage": stage,
        "duration_ms": max(0, round((time.monotonic() - started) * 1000)),
        "exit_code": exit_code,
    }

def validate_action(data, width, height):
    if not isinstance(data, dict): raise Invalid("Expected an object")
    actor = data.get("actor")
    if actor not in ("agent", "human"): raise Invalid("Invalid actor")
    action = data.get("action")
    if action in ("click", "move"):
        x, y = data.get("x"), data.get("y")
        if type(x) is not int or type(y) is not int or not (0 <= x < width and 0 <= y < height):
            raise Invalid("Coordinates outside desktop")
        # xdotool --sync waits for an actual movement event. At the current
        # coordinates there is no event, so a repeated click can wait forever.
        # Commands in this one xdotool invocation retain X request ordering.
        args = ["mousemove", str(x), str(y)]
        if action == "click":
            button = data.get("button", 1)
            if type(button) is not int or button not in (1, 2, 3, 4, 5): raise Invalid("Invalid button")
            args += ["click", str(button)]
        return actor, args, None
    if action == "type":
        text = data.get("text")
        if not isinstance(text, str) or not text or len(text) > 2000 or "\x00" in text:
            raise Invalid("Expected 1..2000 characters without NUL")
        return actor, ["type", "--clearmodifiers", "--delay", "1", "--file", "-"], text.encode("utf-8")
    if action == "key" and isinstance(data.get("key"), str) and data["key"] in KEYS:
        return actor, ["key", "--clearmodifiers", data["key"]], None
    raise Invalid("Unsupported action or key; no shell API")

class XDisplay:
    def __init__(self):
        if os.name == "nt" or os.environ.get("DISPLAY") != ":99":
            raise RuntimeError("Backend requires private Linux DISPLAY=:99")
        self.env = dict(os.environ, DISPLAY=":99")
    def _run(self, command, stage, timeout, *, stdin=None, stdout=None):
        started = time.monotonic()
        try:
            return subprocess.run(command, input=stdin, env=self.env, stdout=stdout,
                                  stderr=subprocess.DEVNULL, timeout=timeout, check=True,
                                  shell=False)
        except Exception as exc:
            raise InputFailure(_input_diagnostic(exc, stage, started)) from exc
    def input(self, args, stdin):
        if args and args[0] == 'type' and stdin and not stdin.isascii():
            # X11 key synthesis does not reliably deliver CJK text in Firefox.
            # Clipboard ownership is inside this private DISPLAY, never Windows.
            self._run(['xclip','-selection','clipboard','-in'], 'clipboard_write', 2,
                      stdin=stdin, stdout=subprocess.DEVNULL)
            started = time.monotonic()
            copied = self._run(['xclip','-selection','clipboard','-out'],
                               'clipboard_verify', 2, stdout=subprocess.PIPE)
            if copied.stdout != stdin:
                mismatch = RuntimeError('clipboard mismatch')
                diagnostic = _input_diagnostic(mismatch, 'clipboard_verify', started)
                diagnostic['category'] = 'verification_failed'
                raise InputFailure(diagnostic) from mismatch
            self._run(['xdotool','key','--clearmodifiers','ctrl+v'], 'clipboard_paste', 3,
                      stdout=subprocess.DEVNULL)
            return
        stage = ('pointer_click' if args and args[0] == 'mousemove' and 'click' in args
                 else {'mousemove': 'pointer_move', 'type': 'text_type', 'key': 'key'}.get(
                     args[0] if args else None, 'input'))
        self._run(["xdotool"] + args, stage, 8, stdin=stdin,
                  stdout=subprocess.DEVNULL)
    def _capture(self, encoding, signature):
        command = ["import", "-display", ":99", "-window", "root"]
        if encoding == "jpeg":
            command += ["-quality", "72"]
        command.append(encoding + ":-")
        result = subprocess.run(command,
                                capture_output=True, timeout=8, check=True, env=self.env, shell=False)
        if not result.stdout.startswith(signature): raise RuntimeError("Invalid screenshot")
        return result.stdout
    def screenshot(self):
        return self._capture("png", b"\x89PNG\r\n\x1a\n")
    def frame_jpeg(self):
        return self._capture("jpeg", b"\xff\xd8\xff")

def wechat_gui_alive():
    try:
        result = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--class", "wechat"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=1,
            check=False)
        return result.returncode == 0 and bool(result.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


class Channel:
    def __init__(self, display, width=1600, height=900, *, broker_enabled=False, channel_id=None):
        self.display, self.width, self.height = display, width, height
        self.lock = threading.Lock()
        self.mode = "paused"
        self.broker_enabled = broker_enabled
        self.channel_id = channel_id or uuid.uuid4().hex
        self.lease = None
        self.last_generation = 0
        self.last_owner = None
        self.used_nonces = set()
        self.action_count = 0
        self.last_action_at = None
        self.last_input_error = None
    def status(self):
        with self.lock:
            self._expire_locked()
            result = self._status_locked()
        result["desktop_app"] = os.environ.get("QICHENG_DESKTOP_APP", "firefox")
        if result["desktop_app"] == "wechat":
            result["gui_alive"] = wechat_gui_alive()
        return result
    def _status_locked(self):
        lease = self.lease
        return {"channel_id": self.channel_id,
                "input_auth": "broker-v2" if self.broker_enabled else "direct-v1",
                "lease": None if lease is None else {
                    "owner": lease["owner"], "generation": lease["generation"],
                    "expires_at": lease["expires_at"]},
                "mode": self.mode, "width": self.width, "height": self.height,
                "actions": self.action_count, "last_action_at": self.last_action_at,
                "last_input_error": self.last_input_error,
                "input_target": "private-linux-display", "host_input_supported": False}
    def _expire_locked(self):
        if self.lease is not None and time.monotonic() >= self.lease["deadline"]:
            self.lease = None
    def _matches_locked(self, identity):
        return self.lease is not None and identity == tuple(self.lease[k] for k in ("owner", "generation", "nonce"))
    def claim(self, data):
        owner, generation, nonce, ttl = _lease_request(data, ttl=True)
        with self.lock:
            self._expire_locked()
            identity = owner, generation, nonce
            if self.mode != "agent": raise Conflict("Agent mode is not enabled")
            if self.lease is not None and not self._matches_locked(identity):
                raise Conflict("Lease already held")
            if self.lease is None:
                if generation < self.last_generation:
                    raise Conflict("Stale lease generation")
                if generation == self.last_generation:
                    if owner != self.last_owner or nonce in self.used_nonces:
                        raise Conflict("Stale lease identity")
                else:
                    self.last_generation = generation
                    self.last_owner = owner
                    self.used_nonces.clear()
                self.used_nonces.add(nonce)
            self.lease = {"owner": owner, "generation": generation, "nonce": nonce,
                          "deadline": time.monotonic() + ttl, "expires_at": time.time() + ttl}
            return self._status_locked()
    def renew(self, data):
        owner, generation, nonce, ttl = _lease_request(data, ttl=True)
        with self.lock:
            self._expire_locked()
            if self.mode != "agent" or not self._matches_locked((owner, generation, nonce)):
                raise Conflict("Lease unavailable")
            self.lease["deadline"] = time.monotonic() + ttl
            self.lease["expires_at"] = time.time() + ttl
            return self._status_locked()
    def release(self, data):
        identity = _lease_request(data, ttl=False)
        with self.lock:
            self._expire_locked()
            if not self._matches_locked(identity): raise Conflict("Lease unavailable")
            self.lease = None
            return self._status_locked()
    def control(self, mode):
        if mode not in ("paused", "human", "agent"): raise Invalid("Unknown mode")
        # Serialize takeover with input; already delivered input cannot be undone.
        with self.lock:
            self.mode = mode
            if mode in ("human", "paused"): self.lease = None
    def act(self, data):
        actor, args, stdin = validate_action(data, self.width, self.height)
        with self.lock:
            self._expire_locked()
            if self.mode != actor: raise Conflict("Input disabled for this actor")
            if self.broker_enabled and actor == "agent":
                lease = data.get("lease")
                if not isinstance(lease, dict) or not self._matches_locked(_lease_request(lease, ttl=False)):
                    raise Conflict("Broker lease required")
            started = time.monotonic()
            try:
                self.display.input(args, stdin)
            except Exception as exc:
                self.mode = "paused"
                self.lease = None
                stage = {'click': 'pointer_click', 'move': 'pointer_move',
                         'type': 'text_type', 'key': 'key'}.get(data.get('action'), 'input')
                self.last_input_error = _input_diagnostic(exc, stage, started)
                raise InputFailure(self.last_input_error) from exc
            self.action_count += 1
            self.last_action_at = time.time()
            self.last_input_error = None
    def screenshot(self):
        with self.lock: return self.display.screenshot()
    def frame_jpeg(self):
        with self.lock: return self.display.frame_jpeg()

def handler_for(channel, token, broker_token=None, viewer_token=None):
    if broker_token is not None:
        if not re.fullmatch(r"[a-f0-9]{64}", broker_token) or hmac.compare_digest(token, broker_token):
            raise ValueError("Invalid separate broker token")
        if (viewer_token is None or not re.fullmatch(r"[a-f0-9]{64}", viewer_token)
                or hmac.compare_digest(token, viewer_token)
                or hmac.compare_digest(broker_token, viewer_token)):
            raise ValueError("Invalid separate viewer token")
        channel.broker_enabled = True
    class Handler(BaseHTTPRequestHandler):
        server_version = "AgentChannels/0.1"
        def log_message(self, *_): pass
        def send(self, status, body, content_type="application/json"):
            data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)
        def authorized(self, expected=token):
            supplied = self.headers.get("Authorization", "")
            return not self.headers.get("Origin") and hmac.compare_digest(
                supplied.encode(), ("Bearer " + expected).encode())
        def do_GET(self):
            if self.path == "/health":
                if os.environ.get("QICHENG_DESKTOP_APP") == "wechat" and not wechat_gui_alive():
                    return self.send(503, {"error": "WeChat desktop GUI unavailable"})
                return self.send(200, {"service": "agent-channels", "version": "0.1"})
            if self.path == "/api/lease/inspect":
                if broker_token is None or not self.authorized(broker_token):
                    return self.send(401, {"error": "Authentication required"})
                return self.send(200, channel.status())
            if broker_token is not None:
                if not (self.authorized(token) or self.authorized(viewer_token)):
                    return self.send(401, {"error": "Authentication required"})
            elif not self.authorized(): return self.send(401, {"error": "Authentication required"})
            try:
                if self.path == "/api/state":
                    state = channel.status()
                    if state.get("desktop_app") == "wechat" and not state.get("gui_alive"):
                        return self.send(503, {"error": "WeChat desktop GUI unavailable", "desktop_app": "wechat", "gui_alive": False})
                    return self.send(200, state)
                if self.path == "/api/screenshot": return self.send(200, channel.screenshot(), "image/png")
                if self.path == "/api/frame.jpg": return self.send(200, channel.frame_jpeg(), "image/jpeg")
                self.send(404, {"error": "Not found"})
            except Exception: self.send(503, {"error": "Private desktop unavailable"})
        def do_POST(self):
            lease_path = self.path in ("/api/lease/claim", "/api/lease/renew", "/api/lease/release")
            if lease_path:
                if broker_token is None or not self.authorized(broker_token):
                    return self.send(401, {"error": "Authentication required"})
            elif self.path == "/api/input" and broker_token is not None:
                if not (self.authorized(viewer_token) or self.authorized(broker_token)):
                    return self.send(401, {"error": "Authentication required"})
            elif self.path == "/api/control" and broker_token is not None:
                if not self.authorized(viewer_token):
                    return self.send(401, {"error": "Authentication required"})
            elif not self.authorized(): return self.send(401, {"error": "Authentication required"})
            try:
                if self.headers.get("Content-Type", "").split(";")[0] != "application/json": raise Invalid("JSON required")
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY: raise Invalid("Invalid body length")
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict): raise Invalid("Expected an object")
                if self.path == "/api/control": channel.control(data.get("mode"))
                elif self.path == "/api/input":
                    if broker_token is not None:
                        expected = broker_token if data.get("actor") == "agent" else viewer_token
                        if not self.authorized(expected):
                            return self.send(401, {"error": "Authentication required"})
                    channel.act(data)
                elif self.path == "/api/lease/claim": return self.send(200, channel.claim(data))
                elif self.path == "/api/lease/renew": return self.send(200, channel.renew(data))
                elif self.path == "/api/lease/release": return self.send(200, channel.release(data))
                else: return self.send(404, {"error": "Not found"})
                self.send(200, channel.status())
            except Conflict as exc: self.send(409, {"error": str(exc)})
            except (Invalid, ValueError, TypeError, UnicodeError): self.send(400, {"error": "Invalid request"})
            except InputFailure as exc:
                self.send(503, {"error": "Private desktop unavailable; no host fallback",
                                "diagnostic": exc.diagnostic})
            except Exception: self.send(503, {"error": "Private desktop unavailable; no host fallback"})
    return Handler

if __name__ == "__main__":
    token = Path("/run/secrets/channel_token").read_text().strip()
    if not re.fullmatch(r"[a-f0-9]{64}", token): raise RuntimeError("Invalid generated token")
    broker_value, broker_file = os.environ.get("BROKER_TOKEN"), os.environ.get("BROKER_TOKEN_FILE")
    if broker_value is not None and broker_file is not None:
        raise RuntimeError("Configure only one broker token source")
    broker_token = Path(broker_file).read_text().strip() if broker_file else broker_value
    viewer_value, viewer_file = os.environ.get("VIEWER_TOKEN"), os.environ.get("VIEWER_TOKEN_FILE")
    if viewer_value is not None and viewer_file is not None:
        raise RuntimeError("Configure only one viewer token source")
    viewer_token = Path(viewer_file).read_text().strip() if viewer_file else viewer_value
    channel = Channel(XDisplay(), int(os.environ.get("SCREEN_WIDTH", "1600")),
                      int(os.environ.get("SCREEN_HEIGHT", "900")),
                      broker_enabled=broker_token is not None,
                      channel_id=os.environ.get("CHANNEL_ID"))
    ThreadingHTTPServer(("0.0.0.0", 8080),
            handler_for(channel, token, broker_token, viewer_token)).serve_forever()
