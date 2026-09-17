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
```

The operator can explicitly `allow`, `takeover`, or `pause`. `allow` refuses to replace human control. After a human handoff, pause first, then deliberately enable a new agent task. A locked or unavailable guest refuses input. Agents must never automatically retry `allow` after takeover or failure.

For MCP, run `python -m host.mcp --config <absolute-local-config> --project project-a` with this directory as the process working directory. Each MCP process binds one project. The three exposed tools read state, screenshot, and send agent input; there is no control override tool. Client configuration is not proof of native tool loading or acceptance.

Current status: host framing and routing have mock tests. End-to-end Hyper-V guest connection, desktop input, and concurrent native-tool behavior require live acceptance before a release.
