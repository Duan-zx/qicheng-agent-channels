"""Hyper-V-only client. No TCP or host-desktop fallback."""
import argparse
import base64
import hmac
import json
import re
import socket
import struct
import sys
import uuid
from pathlib import Path

SERVICE_ID = '6f3bbd64-8b13-4f20-a1c6-93f77f6ab20e'
MAX_REQUEST = 65536
MAX_RESPONSE = 12 * 1024 * 1024


def canonical_id(value):
    identifier = uuid.UUID(value)
    if not identifier.int:
        raise ValueError('A specific nonzero guest identity is required')
    return str(identifier)


def read_config(path):
    config_path = Path(path).resolve()
    data = json.loads(config_path.read_text(encoding='utf-8-sig'))
    if data.get('schema_version') != 1 or not isinstance(data.get('projects'), dict) or not data['projects']:
        raise ValueError('Expected schema_version=1 and nonempty projects')
    projects = {}
    vm_ids, bios_ids, tokens = set(), set(), set()
    for name, item in data['projects'].items():
        if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,39}', name):
            raise ValueError('Invalid project name')
        vm_id, bios_id = canonical_id(item['vm_id']), canonical_id(item['bios_uuid'])
        # An independent guest and token file are required per project.
        token_path = Path(item['token_file'])
        if not token_path.is_absolute():
            token_path = config_path.parent / token_path
        token_path = token_path.resolve()
        token_key = str(token_path).casefold()
        if vm_id in vm_ids or bios_id in bios_ids or token_key in tokens:
            raise ValueError('Projects must not share guest identities or token files')
        vm_ids.add(vm_id); bios_ids.add(bios_id); tokens.add(token_key)
        projects[name] = dict(vm_id=vm_id, bios_uuid=bios_id, token_file=token_path)
    return projects


def read_exact(stream, size):
    pieces = []
    while size:
        block = stream.recv(size)
        if not block:
            raise ConnectionError('Incomplete guest response')
        pieces.append(block)
        size -= len(block)
    return b''.join(pieces)


class GuestClient:
    def __init__(self, binding, socket_factory=None):
        self.binding = binding
        self.factory = socket_factory or socket.socket
        self.token = binding['token_file'].read_text(encoding='utf-8').strip()
        if not re.fullmatch(r'[a-f0-9]{64}', self.token):
            raise ValueError('Invalid per-guest token file')
        self.sequence = 0

    def exchange(self, op, **fields):
        if not hasattr(socket, 'AF_HYPERV'):
            raise RuntimeError('Python 3.12+ with Windows Hyper-V sockets is required')
        self.sequence += 1
        request = dict(id=str(self.sequence), token=self.token, op=op, **fields)
        frame = json.dumps(request, ensure_ascii=True).encode('utf-8')
        if len(frame) > MAX_REQUEST:
            raise ValueError('Request too large')
        with self.factory(socket.AF_HYPERV, socket.SOCK_STREAM, socket.HV_PROTOCOL_RAW) as stream:
            stream.settimeout(15)
            stream.connect((self.binding['vm_id'], SERVICE_ID))
            stream.sendall(struct.pack('!I', len(frame)) + frame)
            size = struct.unpack('!I', read_exact(stream, 4))[0]
            if not 0 < size <= MAX_RESPONSE:
                raise ValueError('Invalid guest response length')
            response = json.loads(read_exact(stream, size))
        if response.get('id') != str(self.sequence) or type(response.get('ok')) is not bool:
            raise ValueError('Invalid guest response envelope')
        if not response['ok']:
            # Guest error values are untrusted; do not echo raw response or data.
            raise RuntimeError('Guest rejected the operation; inspect its local state')
        return response['result']

    def state(self):
        result = self.exchange('state')
        actual = canonical_id(result['identity']['bios_uuid'])
        if not hmac.compare_digest(actual, self.binding['bios_uuid']):
            raise RuntimeError('Guest identity mismatch; operation refused')
        if result.get('input_target') != 'private-windows-guest' or result.get('host_input_supported') is not False:
            raise RuntimeError('Guest isolation identity not established')
        return result

    def operation(self, op, **fields):
        state = self.state()
        if op == 'state':
            return state
        if op == 'control' and fields.get('mode') == 'agent' and state.get('mode') == 'human':
            raise RuntimeError('Human takeover retained; enable locally after handoff')
        if op == 'input' and state.get('mode') != fields.get('actor'):
            raise RuntimeError('Input is paused or controlled by another actor')
        return self.exchange(op, **fields)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--project', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    for cmd in ('state', 'allow', 'pause', 'takeover'):
        sub.add_parser(cmd)
    screenshot = sub.add_parser('screenshot'); screenshot.add_argument('--out', required=True)
    action = sub.add_parser('input')
    action.add_argument('--actor', choices=['agent', 'human'], default='agent')
    action.add_argument('--action', choices=['click', 'move', 'type', 'key'], required=True)
    for key in ('x', 'y', 'button'):
        action.add_argument('--' + key, type=int)
    for key in ('text', 'key'):
        action.add_argument('--' + key)
    args = parser.parse_args()
    try:
        bindings = read_config(args.config)
        client = GuestClient(bindings[args.project])
        if args.command == 'state':
            result = client.state()
        elif args.command in ('allow', 'pause', 'takeover'):
            result = client.operation('control', mode={'allow': 'agent', 'pause': 'paused', 'takeover': 'human'}[args.command])
        elif args.command == 'screenshot':
            result = client.operation('screenshot')
            png = base64.b64decode(result['data'], validate=True)
            if result['mime_type'] != 'image/png' or not png.startswith(b'\x89PNG\r\n\x1a\n') or len(png) > 8 * 1024 * 1024:
                raise ValueError('Invalid guest screenshot')
            destination = Path(args.out).resolve()
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(png)
            result = dict(screenshot=str(destination), width=result['width'], height=result['height'])
        else:
            fields = {key: getattr(args, key) for key in ('action', 'x', 'y', 'button', 'text', 'key') if getattr(args, key, None) is not None}
            result = client.operation('input', actor=args.actor, **fields)
        print(json.dumps(dict(ok=True, project=args.project, result=result), ensure_ascii=True))
        return 0
    except Exception as exc:
        print(json.dumps(dict(ok=False, error_type=type(exc).__name__, error='Windows guest operation failed; no host fallback'), ensure_ascii=True))
        return 1


if __name__ == '__main__':
    sys.exit(main())
