"""Windows-only identity guard, SendInput and GDI screenshot implementation."""
import binascii
import ctypes
from ctypes import wintypes
import hmac
import json
import os
import struct
import subprocess
import uuid
import zlib

from .protocol import OperationFailure

MAX_PIXELS = 16_777_216


def normalize_uuid(value):
    try:
        return str(uuid.UUID(str(value).strip())).lower()
    except (ValueError, AttributeError, TypeError) as exc:
        raise RuntimeError("Invalid BIOS UUID") from exc


def validate_vm_identity(identity, expected_bios_uuid, os_name=os.name):
    if os_name != "nt":
        raise RuntimeError("Windows guest required")
    if not isinstance(identity, dict):
        raise RuntimeError("WMI identity unavailable")
    model = str(identity.get("model", "")).strip()
    manufacturer = str(identity.get("manufacturer", "")).strip()
    if len(model) > 128 or len(manufacturer) > 128:
        raise RuntimeError("WMI identity unavailable")
    bios_uuid = normalize_uuid(identity.get("bios_uuid"))
    expected = normalize_uuid(expected_bios_uuid)
    if model.casefold() != "virtual machine" or "microsoft" not in manufacturer.casefold():
        raise RuntimeError("Hyper-V virtual machine identity required")
    if not hmac.compare_digest(bios_uuid, expected):
        raise RuntimeError("BIOS UUID mismatch")
    return {"bios_uuid": bios_uuid, "model": "Virtual Machine", "manufacturer": manufacturer}


def query_wmi_identity():
    script = (
        "$c=Get-CimInstance -ClassName Win32_ComputerSystem;"
        "$p=Get-CimInstance -ClassName Win32_ComputerSystemProduct;"
        "@{model=$c.Model;manufacturer=$c.Manufacturer;bios_uuid=$p.UUID}|ConvertTo-Json -Compress"
    )
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=10, check=True, shell=False, creationflags=flags,
        )
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError("WMI identity unavailable") from None
    if len(result.stdout) > 4096:
        raise RuntimeError("WMI identity unavailable")
    try:
        value = json.loads(result.stdout.decode("utf-8-sig"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("WMI identity unavailable") from exc
    if not isinstance(value, dict):
        raise RuntimeError("WMI identity unavailable")
    return value


def verify_this_guest(expected_bios_uuid):
    return validate_vm_identity(query_wmi_identity(), expected_bios_uuid)


def _png_chunk(kind, data):
    return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", binascii.crc32(kind + data) & 0xFFFFFFFF)


def png_from_bgra(width, height, pixels):
    if type(width) is not int or type(height) is not int or width <= 0 or height <= 0 or width * height > MAX_PIXELS:
        raise ValueError("Invalid screen dimensions")
    if len(pixels) != width * height * 4:
        raise ValueError("Invalid pixel buffer")
    compressor = zlib.compressobj(level=6)
    compressed = []
    stride = width * 4
    for y in range(height):
        source = pixels[y * stride:(y + 1) * stride]
        rgb = bytearray(width * 3)
        rgb[0::3] = source[2::4]
        rgb[1::3] = source[1::4]
        rgb[2::3] = source[0::4]
        compressed.append(compressor.compress(b"\x00" + rgb))
    compressed.append(compressor.flush())
    header = struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", header) +
            _png_chunk(b"IDAT", b"".join(compressed)) + _png_chunk(b"IEND", b""))


def absolute_coordinate(value, size):
    if type(value) is not int or type(size) is not int or size <= 0 or not 0 <= value < size:
        raise ValueError("Coordinate outside guest desktop")
    return 0 if size == 1 else round(value * 65535 / (size - 1))


def unicode_units(text):
    encoded = text.encode("utf-16-le", "surrogatepass")
    return [int.from_bytes(encoded[index:index + 2], "little") for index in range(0, len(encoded), 2)]


ULONG_PTR = ctypes.c_size_t


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("value",)
    _fields_ = [("type", wintypes.DWORD), ("value", INPUTUNION)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


class RGBQUAD(ctypes.Structure):
    _fields_ = [("rgbBlue", ctypes.c_ubyte), ("rgbGreen", ctypes.c_ubyte),
                ("rgbRed", ctypes.c_ubyte), ("rgbReserved", ctypes.c_ubyte)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", RGBQUAD * 1)]


VK = {
    "Return": 0x0D, "BackSpace": 0x08, "Tab": 0x09, "Escape": 0x1B, "Delete": 0x2E,
    "Left": 0x25, "Up": 0x26, "Right": 0x27, "Down": 0x28, "Home": 0x24,
    "End": 0x23, "Page_Up": 0x21, "Page_Down": 0x22, "space": 0x20,
}


class Win32Desktop:
    def __init__(self):
        if os.name != "nt":
            raise RuntimeError("Windows guest required")
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
        self._configure_api()

    def _configure_api(self):
        self.user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
        self.user32.SendInput.restype = wintypes.UINT
        self.user32.OpenInputDesktop.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.user32.OpenInputDesktop.restype = wintypes.HANDLE
        self.user32.GetUserObjectInformationW.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID,
                                                          wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        self.user32.GetUserObjectInformationW.restype = wintypes.BOOL
        self.user32.CloseDesktop.argtypes = [wintypes.HANDLE]
        self.user32.CloseDesktop.restype = wintypes.BOOL
        self.user32.GetDC.argtypes = [wintypes.HWND]
        self.user32.GetDC.restype = wintypes.HDC
        self.user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
        self.user32.ReleaseDC.restype = ctypes.c_int
        self.kernel32.GetCurrentProcessId.restype = wintypes.DWORD
        self.kernel32.ProcessIdToSessionId.argtypes = [wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        self.kernel32.ProcessIdToSessionId.restype = wintypes.BOOL
        self.gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
        self.gdi32.CreateCompatibleDC.restype = wintypes.HDC
        self.gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
        self.gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
        self.gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
        self.gdi32.SelectObject.restype = wintypes.HGDIOBJ
        self.gdi32.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                     wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
        self.gdi32.BitBlt.restype = wintypes.BOOL
        self.gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                                        wintypes.LPVOID, ctypes.POINTER(BITMAPINFO), wintypes.UINT]
        self.gdi32.GetDIBits.restype = ctypes.c_int
        self.gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
        self.gdi32.DeleteObject.restype = wintypes.BOOL
        self.gdi32.DeleteDC.argtypes = [wintypes.HDC]
        self.gdi32.DeleteDC.restype = wintypes.BOOL

    def dimensions(self):
        width = int(self.user32.GetSystemMetrics(0))
        height = int(self.user32.GetSystemMetrics(1))
        if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
            raise RuntimeError("Unsupported guest desktop dimensions")
        return width, height

    def _session_id(self):
        session = wintypes.DWORD()
        process_id = self.kernel32.GetCurrentProcessId()
        if not self.kernel32.ProcessIdToSessionId(process_id, ctypes.byref(session)):
            raise ctypes.WinError(ctypes.get_last_error())
        return int(session.value)

    def _input_desktop_name(self):
        handle = self.user32.OpenInputDesktop(0, False, 0x0001)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            buffer = ctypes.create_unicode_buffer(256)
            needed = wintypes.DWORD()
            if not self.user32.GetUserObjectInformationW(handle, 2, buffer, ctypes.sizeof(buffer), ctypes.byref(needed)):
                raise ctypes.WinError(ctypes.get_last_error())
            return buffer.value
        finally:
            self.user32.CloseDesktop(handle)

    def probe_ready(self):
        try:
            if self._session_id() == 0:
                return False, "session_zero"
            if self._input_desktop_name().casefold() != "default":
                return False, "non_default_desktop"
            return True, "ready"
        except Exception:
            return False, "desktop_unavailable"

    def _require_ready(self, stage):
        ready, _ = self.probe_ready()
        if not ready:
            raise OperationFailure({
                "category": "desktop_not_ready", "exception_type": "DesktopGuard",
                "stage": stage, "duration_ms": 0, "exit_code": None,
            })

    @staticmethod
    def _mouse(flags, dx=0, dy=0, data=0):
        value = INPUT(); value.type = 0
        value.mi = MOUSEINPUT(dx, dy, data, flags, 0, 0)
        return value

    @staticmethod
    def _key(vk=0, scan=0, flags=0):
        value = INPUT(); value.type = 1
        value.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
        return value

    def _send(self, inputs):
        array = (INPUT * len(inputs))(*inputs)
        sent = self.user32.SendInput(len(inputs), array, ctypes.sizeof(INPUT))
        if sent != len(inputs):
            raise ctypes.WinError(ctypes.get_last_error())

    def perform(self, request):
        self._require_ready("input_guard")
        action = request["action"]
        width, height = self.dimensions()
        if action in {"move", "click"}:
            move = self._mouse(0x0001 | 0x8000, absolute_coordinate(request["x"], width),
                               absolute_coordinate(request["y"], height))
            inputs = [move]
            if action == "click":
                down, up = {1: (0x0002, 0x0004), 2: (0x0020, 0x0040), 3: (0x0008, 0x0010)}[request.get("button", 1)]
                inputs.extend([self._mouse(down), self._mouse(up)])
            self._send(inputs)
        elif action == "key":
            name = request["key"]
            if name.startswith("ctrl+"):
                letter = ord(name[-1].upper())
                self._send([self._key(0x11), self._key(letter), self._key(letter, flags=0x0002),
                            self._key(0x11, flags=0x0002)])
            else:
                key = VK[name]
                self._send([self._key(key), self._key(key, flags=0x0002)])
        else:
            inputs = []
            for unit in unicode_units(request["text"]):
                inputs.extend([self._key(scan=unit, flags=0x0004),
                               self._key(scan=unit, flags=0x0004 | 0x0002)])
            self._send(inputs)

    def screenshot_png(self):
        self._require_ready("screenshot_guard")
        width, height = self.dimensions()
        screen_dc = self.user32.GetDC(None)
        memory_dc = self.gdi32.CreateCompatibleDC(screen_dc) if screen_dc else None
        bitmap = self.gdi32.CreateCompatibleBitmap(screen_dc, width, height) if memory_dc else None
        previous = self.gdi32.SelectObject(memory_dc, bitmap) if bitmap else None
        invalid_object = ctypes.c_void_p(-1).value
        selected = bool(previous) and previous != invalid_object
        try:
            if not screen_dc or not memory_dc or not bitmap or not selected:
                raise ctypes.WinError(ctypes.get_last_error())
            if not self.gdi32.BitBlt(memory_dc, 0, 0, width, height, screen_dc, 0, 0, 0x00CC0020):
                raise ctypes.WinError(ctypes.get_last_error())
            if not self.gdi32.SelectObject(memory_dc, previous):
                raise ctypes.WinError(ctypes.get_last_error())
            selected = False
            info = BITMAPINFO()
            info.bmiHeader = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), width, -height, 1, 32,
                                               0, width * height * 4, 0, 0, 0, 0)
            pixels = ctypes.create_string_buffer(width * height * 4)
            if self.gdi32.GetDIBits(memory_dc, bitmap, 0, height, pixels, ctypes.byref(info), 0) != height:
                raise ctypes.WinError(ctypes.get_last_error())
            png = png_from_bgra(width, height, pixels.raw)
            return png
        finally:
            if selected and previous and memory_dc:
                self.gdi32.SelectObject(memory_dc, previous)
            if bitmap:
                self.gdi32.DeleteObject(bitmap)
            if memory_dc:
                self.gdi32.DeleteDC(memory_dc)
            if screen_dc:
                self.user32.ReleaseDC(None, screen_dc)
