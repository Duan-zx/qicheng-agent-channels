"""Load the fixed Windows Channels host adapter from a package or source tree."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


_PACKAGE = "_task_lease_windows_host"
_host = None


def windows_host():
    """Use only packaged files after installation, or the fixed source sibling."""
    global _host
    if _host is None:
        root = Path(__file__).resolve().parent
        packaged = root / "windows-channels" / "host"
        sibling = root.parent / "windows-channels" / "host"
        directory = packaged if (root / "package-manifest.json").is_file() else sibling
        if not all((directory / name).is_file() for name in
                   ("__init__.py", "client.py", "lease_client.py")):
            raise RuntimeError("Windows guest host adapter is unavailable")
        entry = directory / "__init__.py"
        spec = importlib.util.spec_from_file_location(
            _PACKAGE, entry, submodule_search_locations=[str(directory)])
        if spec is None or spec.loader is None:
            raise RuntimeError("Windows guest host adapter is unavailable")
        package = importlib.util.module_from_spec(spec)
        sys.modules[_PACKAGE] = package
        try:
            spec.loader.exec_module(package)
            from importlib import import_module
            client = import_module(f"{_PACKAGE}.client")
            lease_client = import_module(f"{_PACKAGE}.lease_client")
        except Exception:
            sys.modules.pop(_PACKAGE, None)
            raise RuntimeError("Windows guest host adapter is unavailable") from None
        _host = (client.read_config, lease_client.LeaseClient)
    return _host
