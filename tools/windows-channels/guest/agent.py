"""Hyper-V socket transport for the experimental Windows guest agent."""
import argparse
import ntpath
import os
from pathlib import Path
import socket
import sys

from .protocol import (GuestChannel, RequestError, TOKEN_RE, dispatch,
                       receive_request, response_error, send_response)
from .windows import Win32Desktop, verify_this_guest
from .wechat_cli import load_trusted_config

SERVICE_ID = "6f3bbd64-8b13-4f20-a1c6-93f77f6ab20e"
CONNECTION_TIMEOUT_SECONDS = 5


def load_fixed_wechat_sidecar(path, token_file):
    """Require a fixed token sibling and reject reparse points; ACL is a deploy gate."""
    try:
        raw_path = os.fspath(path)
        token_path = os.fspath(token_file)
        drive, tail = ntpath.splitdrive(raw_path)
        token_drive, token_tail = ntpath.splitdrive(token_path)
        if (os.name != "nt" or len(drive) != 2 or drive[1] != ":"
                or not tail.startswith("\\") or len(token_drive) != 2
                or token_drive[1] != ":" or not token_tail.startswith("\\")
                or ntpath.normpath(raw_path) != raw_path
                or ntpath.normpath(token_path) != token_path):
            raise ValueError("invalid path")
        token_dir = ntpath.dirname(token_path)
        if (ntpath.basename(token_dir).lower() != ".local"
                or ntpath.normcase(raw_path) != ntpath.normcase(
                    ntpath.join(token_dir, "wechat.json"))):
            raise ValueError("config must be fixed token sibling")
        for target in (token_dir, token_path, raw_path):
            info = os.stat(target, follow_symlinks=False)
            attributes = getattr(info, "st_file_attributes", None)
            if attributes is None or attributes & 0x400 or os.path.islink(target):
                raise ValueError("reparse point or unsupported filesystem")
        if not os.path.isfile(raw_path):
            raise ValueError("not a file")
        config = load_trusted_config(raw_path)
        if not os.path.isdir(config.guest_project_path):
            raise ValueError("project missing")
        if not os.path.isfile(config.cli_bat_path):
            raise ValueError("CLI missing")
        return config
    except Exception:
        raise RuntimeError("Fixed WeChat CLI sidecar unavailable") from None


def load_token(path):
    token_path = Path(path)
    if not token_path.is_file() or token_path.stat().st_size > 128:
        raise RuntimeError("Token file is missing or invalid")
    token = token_path.read_text(encoding="ascii").strip()
    if not TOKEN_RE.fullmatch(token):
        raise RuntimeError("Token file must contain one 64-character lowercase hex token")
    return token


def create_hyperv_listener(socket_module=socket):
    required = ("AF_HYPERV", "HV_PROTOCOL_RAW", "HV_GUID_PARENT")
    if any(not hasattr(socket_module, name) for name in required):
        raise RuntimeError("Python 3.12+ Hyper-V socket support is required")
    listener = socket_module.socket(socket_module.AF_HYPERV, socket_module.SOCK_STREAM,
                                    socket_module.HV_PROTOCOL_RAW)
    try:
        listener.settimeout(1)
        # Bind only the parent partition, not every Hyper-V partition.
        listener.bind((socket_module.HV_GUID_PARENT, SERVICE_ID))
        listener.listen(8)
        return listener
    except Exception:
        listener.close()
        raise


def handle_connection(connection, expected_token, channel):
    request_id = None
    try:
        connection.settimeout(CONNECTION_TIMEOUT_SECONDS)
        request = receive_request(connection)
        if request.get("op") == "wechat_cli":
            connection.settimeout(12)
        request_id = request.get("id")
        response = dispatch(request, expected_token, channel)
    except RequestError as exc:
        response = response_error(request_id, exc.code, exc.public_message)
    except TimeoutError:
        response = response_error(request_id, "timeout", "Request timed out")
    except Exception:
        response = response_error(request_id, "transport_error", "Guest transport failed")
    try:
        send_response(connection, response)
    except Exception:
        pass


def serve(listener, expected_token, channel):
    while True:
        try:
            connection, _ = listener.accept()
        except TimeoutError:
            continue
        with connection:
            handle_connection(connection, expected_token, channel)


def build_parser():
    parser = argparse.ArgumentParser(description="Experimental Hyper-V Windows guest control agent")
    parser.add_argument("--expected-bios-uuid", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--broker-token-file",
                        help="Enable broker-owned guest input leases with a distinct token")
    parser.add_argument("--human-token-file",
                        help="Required with broker leases for local control and human input")
    parser.add_argument("--wechat-config-file",
                        help="Optional protected guest-only WeChat CLI configuration")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if sys.version_info < (3, 12):
        raise RuntimeError("Python 3.12+ is required")
    if os.name != "nt":
        raise RuntimeError("This agent only runs inside a verified Windows guest")
    identity = verify_this_guest(args.expected_bios_uuid)
    token = load_token(args.token_file)
    if bool(args.broker_token_file) != bool(args.human_token_file):
        raise RuntimeError("Broker leases require distinct broker and human token files")
    broker_token = load_token(args.broker_token_file) if args.broker_token_file else None
    human_token = load_token(args.human_token_file) if args.human_token_file else None
    if broker_token is not None and len({token, broker_token, human_token}) != 3:
        raise RuntimeError("Channel, broker, and human tokens must differ")
    if args.wechat_config_file and broker_token is None:
        raise RuntimeError("WeChat CLI requires broker leases")
    wechat_config = (load_fixed_wechat_sidecar(args.wechat_config_file,
                                               args.token_file)
                     if args.wechat_config_file else None)
    backend = Win32Desktop()
    channel = GuestChannel(backend, identity, broker_token=broker_token,
                           human_token=human_token, wechat_config=wechat_config)
    listener = create_hyperv_listener()
    with listener:
        serve(listener, token, channel)


if __name__ == "__main__":
    main()
