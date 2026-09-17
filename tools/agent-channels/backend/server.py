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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 16384
KEYS = {"Return", "BackSpace", "Tab", "Escape", "Delete", "Left", "Right",
        "Up", "Down", "Home", "End", "Page_Up", "Page_Down", "space",
        "ctrl+a", "ctrl+c", "ctrl+v", "ctrl+x", "ctrl+z", "ctrl+f", "ctrl+l",
        "ctrl+r", "ctrl+t", "ctrl+w", "ctrl+shift+t"}

class Invalid(ValueError): pass
class Conflict(RuntimeError): pass

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

class Channel:
    def __init__(self, display, width=1600, height=900):
        self.display, self.width, self.height = display, width, height
        self.lock = threading.Lock()
        self.mode = "paused"
        self.action_count = 0
        self.last_action_at = None
        self.last_input_error = None
    def status(self):
        with self.lock:
            return {"mode": self.mode, "width": self.width, "height": self.height,
                    "actions": self.action_count, "last_action_at": self.last_action_at,
                    "last_input_error": self.last_input_error,
                    "input_target": "private-linux-display", "host_input_supported": False}
    def control(self, mode):
        if mode not in ("paused", "human", "agent"): raise Invalid("Unknown mode")
        # Serialize takeover with input; already delivered input cannot be undone.
        with self.lock: self.mode = mode
    def act(self, data):
        actor, args, stdin = validate_action(data, self.width, self.height)
        with self.lock:
            if self.mode != actor: raise Conflict("Input disabled for this actor")
            started = time.monotonic()
            try:
                self.display.input(args, stdin)
            except Exception as exc:
                self.mode = "paused"
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

def handler_for(channel, token):
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
        def authorized(self):
            supplied = self.headers.get("Authorization", "")
            return not self.headers.get("Origin") and hmac.compare_digest(
                supplied.encode(), ("Bearer " + token).encode())
        def do_GET(self):
            if self.path == "/health": return self.send(200, {"service": "agent-channels", "version": "0.1"})
            if not self.authorized(): return self.send(401, {"error": "Authentication required"})
            try:
                if self.path == "/api/state": return self.send(200, channel.status())
                if self.path == "/api/screenshot": return self.send(200, channel.screenshot(), "image/png")
                if self.path == "/api/frame.jpg": return self.send(200, channel.frame_jpeg(), "image/jpeg")
                self.send(404, {"error": "Not found"})
            except Exception: self.send(503, {"error": "Private desktop unavailable"})
        def do_POST(self):
            if not self.authorized(): return self.send(401, {"error": "Authentication required"})
            try:
                if self.headers.get("Content-Type", "").split(";")[0] != "application/json": raise Invalid("JSON required")
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY: raise Invalid("Invalid body length")
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict): raise Invalid("Expected an object")
                if self.path == "/api/control": channel.control(data.get("mode"))
                elif self.path == "/api/input": channel.act(data)
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
    channel = Channel(XDisplay(), int(os.environ.get("SCREEN_WIDTH", "1600")), int(os.environ.get("SCREEN_HEIGHT", "900")))
    ThreadingHTTPServer(("0.0.0.0", 8080), handler_for(channel, token)).serve_forever()
