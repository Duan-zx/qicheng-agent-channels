# Experimental Windows guest agent

This is a bounded Python standard-library prototype for a future Hyper-V Windows guest channel. It is not a production security boundary, deployment tool, VM creator, installer, login helper, Windows service, MCP server, or host-input fallback.

## Hard runtime boundary

Run the agent only inside the logged-in interactive session of the intended Hyper-V Windows guest. Do not register it as a host service or launch it from session 0: session 0 cannot safely drive the user's interactive desktop. Input and screenshots are refused whenever the process is in session 0, the current input desktop is not named `Default`, or the input desktop cannot be verified. This rejects the Windows lock/UAC secure desktop instead of attempting to bypass it.

Startup verifies all of the following before opening a socket:

- Windows is the current OS.
- WMI `Win32_ComputerSystem.Model` is `Virtual Machine`.
- WMI `Win32_ComputerSystem.Manufacturer` identifies Microsoft.
- WMI `Win32_ComputerSystemProduct.UUID` matches the required host-configured BIOS UUID.

The host-side `Get-VM ... BIOSGUID` and guest-side WMI UUID representation still require verification on the real target VM. Never weaken or skip this guard to work around a mismatch; record the observed values and resolve the mapping first.

## Start contract

Python 3.12 or newer is required because `AF_HYPERV` support was added in 3.12. The Python socket documentation defines a Hyper-V address as `(vm_id, service_id)` UUID strings and marks the constants as Windows-only: <https://docs.python.org/3.12/library/socket.html#socket.AF_HYPERV>.

From `tools/windows-channels` inside the guest interactive session:

```powershell
python -m guest.agent `
  --expected-bios-uuid '00000000-0000-0000-0000-000000000000' `
  --token-file 'C:\ProgramData\Qicheng\channel.token'
```

The shown zero UUID is only a placeholder and will fail unless it is the real expected UUID. The token file must contain one independently generated 64-character lowercase hexadecimal token for this VM. The agent reads only the explicitly supplied file and never writes or logs it.

The opt-in lease mode additionally requires distinct `--broker-token-file` and `--human-token-file` paths. The ordinary channel token can read state and carry leased agent input, the broker token claims and releases short guest leases, and the human token controls mode and human input. In lease mode an agent input without the current claim is rejected even if the channel says `agent`. `Build-GuestPayload.ps1` can prepare all three credentials; `Stage-GuestPayloadDirect.ps1` copies the validated package into a new version directory without replacing the running agent. Staging alone does not enable the gate. An old agent left running on the fixed service ID is still an unfenced input path until an explicit tested switch retires it.

### Controlled v2 task transition

`Switch-GuestPayloadDirect.ps1` has four explicit phases for a staged v2 payload. The default call is diagnostic only. `-Apply` starts a candidate scheduled task without a trigger, stops the legacy task, checks that exactly one candidate `pythonw.exe` remains, and verifies a host `state` handshake. Until promotion, the next interactive logon starts the unchanged legacy task. `-Promote` repeats the staged payload and host handshake checks, disables the legacy logon task, then adds a logon trigger for the same guest user to the running candidate task. It returns `promoted` only after confirming one enabled candidate logon task, a disabled legacy task, and one candidate process. `-Rollback` first disables a promoted candidate, stops its process, enables and starts the unchanged legacy task, and removes the candidate task after proving the old process is sole. It also handles the earlier untriggered Apply state.

Run these phases only in a controlled VM acceptance window, with the exact VM ID, BIOS UUID, guest credential, staged version, and matching host project binding. A legacy Startup shortcut, another candidate task, an unexpected `pythonw.exe`, or a changed task definition blocks the transition. The legacy task action and staged files stay in place for recovery. A failed phase reports `failed-rolled-back` only when restoration is proved; `failed-recovery-incomplete` requires an operator to inspect scheduled tasks and processes before another start or reboot. A power loss during either trigger handoff can leave no automatic agent at next logon; rerun diagnostics and Rollback to restore it. Mock tests cover transitions, not a real VM reboot or Task Scheduler behavior; validate those separately before treating persistence as accepted.

The fixed service ID is `6f3bbd64-8b13-4f20-a1c6-93f77f6ab20e`. The transport is only `AF_HYPERV/SOCK_STREAM/HV_PROTOCOL_RAW`, bound to `HV_GUID_PARENT` so the guest accepts connections only from its Hyper-V parent partition; it does not bind the wildcard VMID. No TCP listener or remotely callable shell operation exists. The startup identity guard invokes one fixed, noninteractive PowerShell `Get-CimInstance` query for the two named WMI classes with `shell=False`; no request value enters that command.

## Protocol

Each connection carries exactly one request and one response. Frames are a four-byte unsigned big-endian length followed by UTF-8 JSON. Requests are limited to 64 KiB and have a five-second connection timeout. Screenshot PNG bytes are limited to 8 MiB before base64 encoding; the whole response is limited to 12 MiB.

Every request contains `id`, the VM-specific `token`, and `op`. Response shapes are fixed:

```json
{"id":"r1","ok":true,"result":{}}
{"id":"r1","ok":false,"error":{"code":"...","message":"...","diagnostic":{}}}
```

Operations:

- `{"id":"r1","token":"...","op":"state"}`
- `{"id":"r2","token":"...","op":"control","mode":"paused|human|agent"}`
- `{"id":"r3","token":"...","op":"input","actor":"agent","action":"click","x":10,"y":20,"button":1}`
- Input actions also include `move`, allowlisted `key`, and bounded `type`. Unicode typing uses Win32 `SendInput` UTF-16 events and never the clipboard.
- `{"id":"r4","token":"...","op":"screenshot"}` returns `{"mime_type":"image/png","data":"<base64>","width":...,"height":...}`.

`state` remains available while locked and returns `desktop_ready:false` while forcing mode to `paused`. Input, screenshots, and enabling `human` or `agent` are refused until the interactive `Default` desktop is ready. The state identity includes the normalized BIOS UUID so the host can verify it before every operation. Each VM must use a distinct token and configured VM ID/BIOS UUID.

Failures automatically pause the channel. Public diagnostics contain only fixed categories, exception type names, fixed stages, durations, and numeric exit codes. They never contain input text, request bodies, command text, tokens, stderr, or raw exception messages.

The state/screenshot/input agent has been deployed and tested in two dedicated Windows VMs on one host. The fixed WeChat CLI runner below is newer candidate code and has not been deployed. Guest setup, account login, host lifecycle, project binding, and cross-task ownership still need separate product work.

## Fixed WeChat CLI probe (unwired)

`wechat_cli.py` is a separate candidate runner for one read-only action. A trusted guest-side startup configuration binds `project_id`, `guest_project_path`, the absolute official `cli.bat` path, and `service_port`. The caller may supply only `{"project_id":"<configured ID>","action":"check-login"}`. The generated command is exactly `cli.bat islogin --port <configured port>` with `shell=False`; its working directory is the configured guest project path. Only a parsed `login` boolean or a fixed error code is returned. No CLI log, account detail, or raw exception is returned. The stdout reader stops at 4 KiB; stderr is discarded.

The CLI deadline is five seconds, reserving up to three more seconds for cleanup within an eight-second target. On timeout or oversized output, the runner tries `taskkill.exe /T /F` and then kills the immediate process if needed. Windows process-tree cleanup is best effort: Python's standard `Popen` cannot prove that all detached descendants were terminated, and OS scheduling may exceed the target. The future bridge must keep its lease held and treat timeout as an uncertain external process state until the guest is checked. This module has only mock tests on the host and is not registered in `agent.py` or the channel protocol.
