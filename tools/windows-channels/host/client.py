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
KEY_NAMES = (
    'Return', 'BackSpace', 'Tab', 'Escape', 'Delete', 'Left', 'Right',
    'Up', 'Down', 'Home', 'End', 'Page_Up', 'Page_Down', 'space',
    'ctrl+a', 'ctrl+c', 'ctrl+v', 'ctrl+x', 'ctrl+z', 'ctrl+f', 'ctrl+l',
)
KEY_ALIASES = {name.casefold(): name for name in KEY_NAMES}
KEY_ALIASES.update({'enter': 'Return', 'esc': 'Escape', 'spacebar': 'space'})


def normalize_key(value):
    """Accept familiar key spellings while keeping the guest's fixed allowlist."""
    return KEY_ALIASES.get(value.casefold(), value) if isinstance(value, str) else value


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
        human_path = None
        if 'human_token_file' in item:
            if not isinstance(item['human_token_file'], str) or not item['human_token_file'].strip():
                raise ValueError('Invalid human token file path')
            human_path = Path(item['human_token_file'])
            if not human_path.is_absolute():
                human_path = config_path.parent / human_path
            human_path = human_path.resolve()
        token_keys = {str(token_path).casefold()}
        if human_path is not None:
            token_keys.add(str(human_path).casefold())
            if len(token_keys) != 2:
                raise ValueError('Channel and human token files must differ')
        if vm_id in vm_ids or bios_id in bios_ids or token_keys & tokens:
            raise ValueError('Projects must not share guest identities or token files')
        vm_ids.add(vm_id); bios_ids.add(bios_id); tokens.update(token_keys)
        projects[name] = dict(vm_id=vm_id, bios_uuid=bios_id, token_file=token_path)
        if human_path is not None:
            projects[name]['human_token_file'] = human_path
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
        self.token = self._read_token(binding['token_file'], 'per-guest')
        self.human_token_file = binding.get('human_token_file')
        if self.human_token_file is not None:
            channel_path = Path(binding['token_file']).resolve()
            human_path = Path(self.human_token_file).resolve()
            if str(channel_path).casefold() == str(human_path).casefold():
                raise ValueError('Channel and human token files must differ')
            self.human_token_file = human_path
        self.sequence = 0

    @staticmethod
    def _read_token(path, label):
        token = Path(path).read_text(encoding='utf-8').strip()
        if not re.fullmatch(r'[a-f0-9]{64}', token):
            raise ValueError('Invalid ' + label + ' token file')
        return token

    def _operation_token(self, op, fields):
        if self.human_token_file is None or not (op == 'control' or
                (op == 'input' and fields.get('actor') == 'human')):
            return self.token
        human_token = self._read_token(self.human_token_file, 'human')
        if hmac.compare_digest(human_token, self.token):
            raise ValueError('Channel and human token values must differ')
        return human_token

    def exchange(self, op, **fields):
        if not hasattr(socket, 'AF_HYPERV'):
            raise RuntimeError('Python 3.12+ with Windows Hyper-V sockets is required')
        self.sequence += 1
        request = dict(id=str(self.sequence), token=self._operation_token(op, fields), op=op, **fields)
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
        if op not in ('state', 'screenshot', 'control', 'input'):
            raise ValueError('Unsupported guest operation')
        state = self.state()
        if op == 'state':
            return state
        if op == 'control' and fields.get('mode') == 'agent' and state.get('mode') == 'human':
            raise RuntimeError('Human takeover retained; enable locally after handoff')
        if op == 'input' and state.get('mode') != fields.get('actor'):
            raise RuntimeError('Input is paused or controlled by another actor')
        if op == 'input' and fields.get('action') == 'key' and 'key' in fields:
            fields['key'] = normalize_key(fields['key'])
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
