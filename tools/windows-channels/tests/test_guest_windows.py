import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import zlib

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))

from guest import windows


UUID = "11111111-2222-3333-4444-555555555555"


class WindowsPureTests(unittest.TestCase):
    def test_identity_requires_windows_hyperv_model_manufacturer_and_uuid(self):
        identity = {"model": "Virtual Machine", "manufacturer": "Microsoft Corporation", "bios_uuid": UUID.upper()}
        verified = windows.validate_vm_identity(identity, UUID, os_name="nt")
        self.assertEqual(verified["bios_uuid"], UUID)
        for changed, os_name in [
            ({**identity, "model": "Surface Laptop"}, "nt"),
            ({**identity, "manufacturer": "Example PC"}, "nt"),
            ({**identity, "bios_uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}, "nt"),
            (identity, "posix"),
        ]:
            with self.subTest(changed=changed, os_name=os_name), self.assertRaises(RuntimeError):
                windows.validate_vm_identity(changed, UUID, os_name=os_name)

    def test_wmi_query_uses_fixed_classes_without_shell_or_stderr_capture(self):
        payload = json.dumps({"model": "Virtual Machine", "manufacturer": "Microsoft Corporation", "bios_uuid": UUID}).encode()
        with patch.object(windows.subprocess, "run", return_value=SimpleNamespace(stdout=payload)) as run:
            result = windows.query_wmi_identity()
        self.assertEqual(result["bios_uuid"], UUID)
        args, kwargs = run.call_args
        command = args[0]
        self.assertIn("Win32_ComputerSystem", command[-1])
        self.assertIn("Win32_ComputerSystemProduct", command[-1])
        self.assertFalse(kwargs["shell"])
        self.assertIs(kwargs["stderr"], windows.subprocess.DEVNULL)

    def test_png_encoder_outputs_top_down_rgb(self):
        # BGRA: red then green.
        png = windows.png_from_bgra(2, 1, bytes([0, 0, 255, 0, 0, 255, 0, 0]))
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        width, height = struct.unpack("!II", png[16:24])
        self.assertEqual((width, height), (2, 1))
        offset, idat = 8, b""
        while offset < len(png):
            length = struct.unpack("!I", png[offset:offset + 4])[0]
            kind = png[offset + 4:offset + 8]
            data = png[offset + 8:offset + 8 + length]
            if kind == b"IDAT": idat += data
            offset += 12 + length
        self.assertEqual(zlib.decompress(idat), b"\x00\xff\x00\x00\x00\xff\x00")

    def test_coordinates_and_unicode_units(self):
        self.assertEqual(windows.absolute_coordinate(0, 1280), 0)
        self.assertEqual(windows.absolute_coordinate(1279, 1280), 65535)
        self.assertEqual(windows.unicode_units("A\U0001f600"), [0x41, 0xD83D, 0xDE00])
        with self.assertRaises(ValueError): windows.absolute_coordinate(1280, 1280)

    def test_type_builds_unicode_sendinput_events_without_clipboard(self):
        desktop = object.__new__(windows.Win32Desktop)
        desktop.probe_ready = lambda: (True, "ready")
        desktop.dimensions = lambda: (1280, 800)
        captured = []
        desktop._send = lambda values: captured.extend(values)
        desktop.perform({"action": "type", "text": "A\U0001f600"})
        self.assertEqual([item.ki.wScan for item in captured],
                         [0x41, 0x41, 0xD83D, 0xD83D, 0xDE00, 0xDE00])
        self.assertEqual([item.ki.dwFlags for item in captured], [0x0004, 0x0006] * 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
