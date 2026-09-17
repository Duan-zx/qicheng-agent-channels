"""Hyper-V socket transport for the experimental Windows guest agent."""
import argparse
import os
from pathlib import Path
import socket
import sys

from .protocol import (GuestChannel, RequestError, TOKEN_RE, dispatch,
                       receive_request, response_error, send_response)
from .windows import Win32Desktop, verify_this_guest

SERVICE_ID = "6f3bbd64-8b13-4f20-a1c6-93f77f6ab20e"
CONNECTION_TIMEOUT_SECONDS = 5


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
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if sys.version_info < (3, 12):
        raise RuntimeError("Python 3.12+ is required")
    if os.name != "nt":
        raise RuntimeError("This agent only runs inside a verified Windows guest")
    identity = verify_this_guest(args.expected_bios_uuid)
    token = load_token(args.token_file)
    backend = Win32Desktop()
    channel = GuestChannel(backend, identity)
    listener = create_hyperv_listener()
    with listener:
        serve(listener, token, channel)


if __name__ == "__main__":
    main()
