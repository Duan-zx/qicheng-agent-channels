# Windows guest client (experimental)

Requires Windows and Python 3.12+ with `socket.AF_HYPERV`. It connects directly to an explicitly configured VM and verifies the guest BIOS UUID before forwarding commands. No TCP endpoint or host desktop input fallback is implemented.

Create a **local, untracked** configuration file after obtaining real VM and BIOS identifiers:

```json
{
  "schema_version": 1,
  "projects": {
    "project-a": {
      "vm_id": "REPLACE-WITH-REAL-VM-ID",
      "bios_uuid": "REPLACE-WITH-REAL-BIOS-UUID",
      "token_file": "project-a.token"
    }
  }
}
```

Tokens contain 64 lowercase hex characters. Each guest/project must have its own token and identity. Token paths are relative to the configuration file. Do not commit them. The host service ID must be registered by the installer; guests must be running the guest agent in their own interactive session.

From the `windows-channels` directory:

```powershell
python -m host.client --config .local/channels.json --project project-a state
python -m host.client --config .local/channels.json --project project-a screenshot --out .local/project-a.png
python -m host.client --config .local/channels.json --project project-a input --action key --key Enter
```

The guest protocol calls the Enter key `Return`. The host client also accepts `Enter` and `ENTER` and normalizes them to `Return`; key names and `ctrl+a/c/v/x/z/f/l` are case-insensitive. Only the guest's fixed key allowlist is forwarded. Arbitrary shortcuts and shell commands are not supported.

The operator can explicitly `allow`, `takeover`, or `pause`. `allow` refuses to replace human control. After a human handoff, pause first, then deliberately enable a new agent task. A locked or unavailable guest refuses input. Agents must never automatically retry `allow` after takeover or failure.

For MCP, run `python -m host.mcp --config <absolute-local-config> --project project-a` with this directory as the process working directory. Each MCP process binds one project. The three exposed tools read state, screenshot, and send agent input; there is no control override tool. Client configuration is not proof of native tool loading or acceptance.

The optional task-lease candidate adds `--broker-url http://127.0.0.1:<port> --broker-token-file <private-file> --broker-channel-id <fixed-channel>`. Supply all three together. The broker must return the same VM ID, BIOS UUID and project binding as this host configuration; otherwise input stops. In this mode the existing `windows_channel_input` tool uses `action=begin`, `click`/`move`/`key`/`type` while leased, and `action=finish` to release. `begin` waits up to 30 seconds in the same-channel queue by default; `wait_seconds` on `begin` can set 0–300 seconds. After a confirmed `finish`, the same MCP process may begin another lease with a fresh request and task identity. Every input goes through the broker's durable attempt and acknowledgement flow. A failed or uncertain broker exchange ends that MCP process's session, and a new process must not blindly repeat an uncertain input. `state` and `screenshot` still connect directly to the fixed guest. Screenshot is not atomically fenced by the task lease and may remain readable after human takeover. A static MCP process ID is not a verified Codex task identity; real mixed-task acceptance is still required.

Broker mode also has a source-only, unregistered `windows_channel_wechat_check_login` candidate. It has no model-supplied arguments and works only after `windows_channel_input` `begin` acquires this fixed channel. Broker configuration pins the project ID and guest sidecar SHA-256 digest; the Guest verifies both before its fixed CLI `islogin` query. The tool returns only `{"login":true|false}` after a durable attempt and ACK. Uncertain response or ACK ends the session without retry. Guest-direct mode does not list this fourth tool. Registering or using it with a real WeChat account requires separate user authorization; the earlier state/screenshot/input permission does not cover it. The current installed Broker and A/B agents do not support this path.

Current status: one Windows host has passed live Hyper-V guest identity, screenshot, and separate Codex tasks entering distinct synthetic text into two guests. Real project workflows, concurrent keystroke timing, a second host install, and recovery after takeover still need acceptance before a general release.
