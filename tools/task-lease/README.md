# Task lease core

## Source-only attempt workspace preparer

`attempt_workspace.py` is a standalone local CLI for Git source checkouts. Its
three absolute paths must name an existing checkout root, an existing worktree
root, and an existing build-output root. The roots must not overlap. For example:

```powershell
python tools/task-lease/attempt_workspace.py --source C:\source\project --worktree-root C:\private\worktrees --build-root C:\private\builds --task-id task1 --attempt-id attempt1
```

It prints JSON with a detached `worktree`, a separate `build_output` directory,
and the pinned commit. A repeated call with the same IDs and source commit
returns those paths after checking the record and Git registration. An ID
bound to another source or commit, an existing unrecorded path, or a link or
junction in the attempt path is rejected. A failed preparation removes only a
new clean worktree; it does not delete existing user files. The caller owns
build commands, cleanup, and the lifetime of each prepared attempt. This
prepares the committed revision only; uncommitted source changes are not copied.
The standalone caller must explicitly pass its chosen source checkout and ref.
The broker can also call this preparer for an opted-in channel, as described
below. It does not allocate or enforce network ports.
Run its tests with `python -B -m unittest discover -s tools/task-lease/tests -p test_attempt_workspace.py -v`.

Optional Windows user-level package and n8n setup: [product/README.zh-CN.md](product/README.zh-CN.md).

`lease.py` is a local SQLite allocator for one task per channel and one active
holder per endpoint ID. `broker.py` also runs registered short CLI operations
under that lease. It does not control the host desktop or intercept other tools.
Call `acquire` with a unique `request_id` for an execution attempt, then pass
its bearer `token` only to a trusted adapter. The adapter must run each bounded
synchronous operation through `execute_owned(channel_id, token, action)`, which
holds cross-process channel and endpoint locks until the action completes.
`assert_owner` is only a snapshot and must not authorize a later action: another
task can take over between the check and the external operation. Adapters must
fail closed if the target environment is unavailable. Renew while the task
runs; release after completion or cancellation. Expired leases can be
reassigned, and old tokens cannot control the successor.

Lease transitions use short immediate SQLite write transactions and WAL, plus
OS file locks for the affected channel and endpoint. Separate processes cannot
acquire the same channel or endpoint concurrently. Request IDs persist as
tombstones to make retries safe across restarts. A retry of an active request
returns the same token; a retry after expiry or release raises `LeaseGone`.
Create a new request ID for a new execution attempt.

`execute_owned` checks ownership under the channel lock, then holds both the
channel and endpoint locks during its callback. It closes the SQLite connection
before the callback, allowing independent endpoints to execute concurrently.
Keep external operations bounded and short; the lock wait budget is 10 seconds.
Do not call LeaseStore recursively from the callback. An external side effect
cannot be rolled back if the callback raises. OS locks are released after a
process crash; an orphaned child process or independent external action is not
fenced by them. For longer operations, the target bridge needs its own
generation-aware execution gate plus heartbeat. Endpoint IDs must identify the
actual exclusive tool instance, not merely a display label. Two channels naming
one endpoint are refused.
Renew and release on the same channel wait for its action to finish. Set the
lease TTL longer than the longest configured action plus expected queue time;
an action that passes its TTL retains its lock until it returns, but a delayed
renewal then fails and the next request may take over.

Place the database in private runtime data, outside Git. Its sibling `.key`
file contains the local HMAC secret; raw bearer tokens and credentials are
never stored in SQLite. Back up database and key together. Losing the key
causes initialization to fail closed. `endpoint_id` and `tool_id` are opaque,
non-secret identifiers; adapters resolve them from their own trusted config.
The resolved `project_path` is an identity binding, not file-system isolation.

This is the allocation primitive only. It does not yet enforce every MCP/CLI
action, allocate free channels, or recover
a dead task early. Those require integration with the service supervisor.

Run tests with `python -m unittest discover -s tools/task-lease/tests -v`.

## Local HTTP broker

`broker.py` exposes this allocator to trusted local callers such as an n8n
HTTP Request node or a Codex task launcher. It binds only to `127.0.0.1`.
Every endpoint requires `Authorization: Bearer <BROKER_TOKEN>`; the credential
file belongs in a private runtime directory outside the source tree. The
example below contains placeholders only:

```json
{
  "default_ttl_seconds": 60,
  "max_ttl_seconds": 300,
  "channels": [
    {
      "channel_id": "channel-2",
      "endpoint_id": "wechat-instance-2",
      "tool_id": "wechat-cli",
      "project_id": "my-project",
      "project_path": "C:/path/to/isolated/project",
      "exclusive_ports": [55975, 9420],
      "actions": {
        "check-login": {
          "argv": ["C:/path/to/devtools/cli.bat", "islogin", "--project", "C:/path/to/isolated/project", "--port", "55975"],
          "timeout_seconds": 5
        }
      }
    }
  ]
}
```

Create the credential file once with
`python broker.py --config <CONFIG> --credential-file <PRIVATE_TOKEN_FILE> --db <PRIVATE_DB> --init-credential`.
Then start with the same arguments without `--init-credential`, optionally
adding `--port <PORT>`. Keep the file in a directory whose access is limited
to the intended local user and service accounts. The broker never prints it.
The database and its `.key` sibling belong in that directory as well.

All writes use JSON and `Content-Type: application/json`:

| Method/path | Body | Result |
| --- | --- | --- |
| `POST /v1/acquire` | `{"request_id":"attempt-1","task_id":"task-1","channel_id":"channel-2","ttl_seconds":60,"wait_seconds":120}` | Lease and bearer `token`; guest channels also return `guest_identity` |
| `POST /v1/renew` | `{"channel_id":"channel-2","token":"<LEASE_TOKEN>","ttl_seconds":60}` | Updated lease; guest channels also return `guest_identity` |
| `POST /v1/release` | `{"channel_id":"channel-2","token":"<LEASE_TOKEN>"}` | Released lease |
| `POST /v1/ack` | `{"channel_id":"channel-2","token":"<LEASE_TOKEN>","action_id":"action-1"}` | Idempotent guest success acknowledgement: `{"ok":true,"action_id":"action-1"}` |
| `POST /v1/execute` | `{"channel_id":"channel-2","token":"<LEASE_TOKEN>","action":"check-login"}` | Exit code and bounded CLI output |
| `GET /v1/status` | none; optional `?channel_id=channel-2` | Public lease status, no lease token |

The broker returns HTTP 409 `busy` for a held channel or endpoint, 409
`request_conflict` for an idempotency key reused with different bindings, 410
`lease_gone` for an expired or released request, and 401 for a missing or wrong
broker credential. Requests cannot supply a project path, endpoint or tool ID;
those are resolved from the trusted configuration. A new execution attempt
needs a new globally unique `request_id`. Callers must renew before expiry and
release on success, failure or cancellation. TTL allows eventual recovery if a
caller crashes for ordinary channels. Guest input has a persistent dirty gate
described below. Configured project roots must be absolute and existing. Two
channels may share exactly the same Git project root only when both opt into
workspace isolation; other overlaps are rejected. An opted-in workspace channel creates its
task-specific worktree at fixed-action execution time.

`wait_seconds` is optional. Omit it or set it to `0` for the original immediate
`409 busy` behavior. A positive value up to 300 seconds waits in a durable FIFO
queue for the configured endpoint (at most 64 waiters per endpoint). The lease
TTL begins when the waiter reaches the front and receives its lease. Retrying
the same binding and `request_id` while queued keeps its place; retries do not
extend the original queue deadline. HTTP 408 `wait_timeout` and 429
`wait_queue_full` mean no lease was issued. A timed-out or cancelled request ID
is terminal, so a new attempt needs a new ID. The broker cancels an HTTP waiter
when its connection closes; orphaned rows after a broker crash are pruned after
five seconds without a heartbeat or at their stored deadline. The queue is
shared by broker processes using the same SQLite database. Set the HTTP
client's request timeout longer than `wait_seconds` and release the preceding
lease when its workflow finishes. Guest dirty state and binding checks still
block new lease delivery.

Codex and n8n can call the same loopback HTTP endpoints: acquire, execute a
registered action, renew before expiry, and release in a final step. The
`check-login` action above is a read-only probe; register only approved fixed
commands. Each action has literal arguments and an absolute executable path;
callers cannot pass arbitrary command text, cwd or port. Without a workspace
binding, the action runs from the bound project directory under the endpoint
execution lock. The runner drains output while keeping at most 16 KiB per
stream in memory and reports truncation. Its deadline covers process exit and
inherited output pipes after worker startup; operating-system process creation
cannot be strictly timed. On timeout it attempts to terminate the process tree.
Keep actions below eight seconds and do not use this bridge for
long-running automation sessions. Deliberately detached descendants or CLI
side effects cannot be proven stopped merely from a timeout response.
Before each action starts, the broker persists `action_dirty` for that endpoint
and clears it only after confirmed process-tree cleanup. A broker crash or
uncertain cleanup leaves the marker in place and denies new actions even after
lease release or restart. Windows actions run in a Job configured to kill
ordinary descendants when the broker closes its handle; deliberately detached
processes and external side effects still need separate verification.
The offline `reconcile_action_dirty.py` tool requires an explicit stopped-broker
and stopped-action verification, plus no active lease, before clearing only
that endpoint. It never cleans generated worktrees or external side effects.

For a source checkout channel, add the optional fixed `workspace` binding:

```json
"workspace": {
  "worktree_root": "C:/private/worktrees",
  "build_root": "C:/private/builds",
  "ref": "HEAD"
}
```

`project_path` then names the existing Git checkout root. Separate channels can
share that exact source root because their attempt directory IDs also include
the channel ID; each still needs its own endpoint and nonconflicting ports for
parallel actions. Both workspace roots
must already exist, be absolute, and remain separate from each other and from
every configured channel project root. A channel cannot combine `workspace`
with guest input. When a valid lease holder executes a registered action, the
broker prepares a detached worktree from the configured ref inside the endpoint
execution fence. The task and attempt directory IDs are stable hashes of the
lease's channel, task and request IDs, using compact directory names for
Windows path limits, so retries of the same binding reuse the
recorded paths. A changed source commit or tampered record fails closed. The
command runs with its cwd set to that worktree and receives
`QICHENG_WORKTREE`, `QICHENG_BUILD_OUTPUT`, and `QICHENG_EXCLUSIVE_PORTS` in its
environment. The last value is a comma-separated list of the channel's fixed
ports, or an empty string. The broker returns the preparation record in the
execute result; a preparation failure returns `workspace_unavailable` (503)
without starting the command. Workspace paths and ports cannot be selected in
the HTTP request. The configured executable and literal argv remain fixed,
and the eight-second action limit still applies. Port variables inform the
child process; the broker cannot force a child that ignores them to bind there.
Existing channels without `workspace` keep their original cwd and response.

For WeChat Developer Tools, use the actual local CLI service port and
automation WebSocket port of the intended instance. Configure both in
`exclusive_ports`; two channels claiming any same port must use the same
`endpoint_id`, so the store excludes them concurrently. The broker verifies
literal `--port` and `--auto-port` values against this list. When a script
connects `miniprogram-automator` to an already running WebSocket endpoint,
its port is inside the script and must be reviewed against this config. This
bridge does not start, log into, or take over Developer Tools. The official
[mini program automation documentation](https://developers.weixin.qq.com/miniprogram/dev/devtools/auto/quick-start.html)
describes the SDK and Developer Tools setup; check the installed CLI's actual
flags and live port before registering an action.

Only operations routed through `/v1/execute` or `/v1/input` are fenced. Existing MCP bridges,
direct CLI invocations, Codex Computer Use, and live n8n workflows remain
outside this gate. Keep the broker credential, config, database and key in a
private runtime directory. Do not include credentials, tokens, uploads or
private business data in registered commands or returned output.

## Windows guest input candidate

A channel may additionally bind a fixed Windows guest using `guest` with absolute
`host_config_path`, a `project` key in that host configuration, and an absolute
`broker_token_file`. The broker pins the guest VM, BIOS identity, project and
credential identities to its private lease database; changing that binding
requires a deliberate migration after leases are retired. Guest-bound channels
reject `/v1/execute` so a configured local subprocess cannot bypass the guest
gate. The package contains a fixed, hash-checked Windows host adapter; source
checkouts use the sibling `windows-channels/host` tree.

`POST /v1/input` accepts only `channel_id`, the active local lease `token`, a
stable `action_id`, and one bounded `click`, `move`, `key`, or `type` action with
its documented fields. Inside the local endpoint lock it claims a short guest
lease, sends one input, and releases the guest claim. The broker commits an
input-attempt record and an endpoint-level `guest_dirty` gate before touching
the guest. Other requests cannot acquire that endpoint, including an alias
channel or after lease expiry and broker restart. `GET /v1/status` reports
`guest_dirty` without exposing a token. Guest acquire and renew return fixed
`guest_identity: {"vm_id":"...","bios_uuid":"...","project":"..."}` from the
configured host binding so a caller can compare it with the actual direct
guest target before sending input. Ordinary channels do not receive this field.

Repeating the same `action_id` within the same lease request replays a
confirmed success or returns a fixed uncertain/conflict error without re-input.
After each confirmed success the client must call `/v1/ack` with the same
channel, lease token and action ID. Ack is idempotent and succeeds only for a
successful input attempt in the current request. A new action is refused until
the previous action is acknowledged. Normal `/v1/release` clears `guest_dirty`
only if every attempt in that request is successful and acknowledged. Releasing
in a `finally` block after failure, lost response or missing ack leaves the
endpoint dirty. The caller must never invent a new request or action ID to
retry an uncertain input. HTTP 409 `guest_dirty` means another session needs
reconciliation; 409 `ack_required` means this request has an unfinished or
unacknowledged prior attempt; 409 `ack_unavailable` means the action was not
confirmed successful. Broker bearer authentication never grants permission to
clear the dirty gate.

There is no automated dirty reconciliation. For an uncertain attempt, stop the
broker and all guest clients, verify the target guest and application outcome
through independent evidence, and wait until both local and guest leases have
expired. Back up the private database together with its `.key` file before an
operator inspects `guest_dirty` and `guest_input_attempts`. Only after that
operator resolves whether the action actually happened may they perform a
targeted offline database repair for the recorded endpoint/request and restart
the broker. An old database containing guest attempts but lacking the new
dirty/ack schema refuses startup; it needs the same offline reconciliation.
Guest input still needs live VM acceptance before production use.
