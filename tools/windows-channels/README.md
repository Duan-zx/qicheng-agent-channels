# Qicheng Windows Channels (alpha)

A Windows workbench for viewing and controlling two independent Hyper-V Windows desktops. The product entry provides Alt+1 to return to the host, Alt+2/3 to switch workspaces, live screenshots, human takeover, explicit AI handoff, and pause.

Start with [product installation and quick start](product/QUICKSTART.zh-CN.md). The per-user installer creates desktop and Start menu shortcuts; Windows guests and their licenses remain separate prerequisites. This is an alpha, not an unattended Windows provisioning appliance.

Node01 live validation has demonstrated screenshots, Chinese agent/human input in both guests, isolation and control boundaries, and visitor-mode WeChat Developer Tools interaction. The workbench has demonstrated real channel switching and direct Chinese input. Final installed-build UI regression, reconnect/lock recovery and active endurance acceptance must be tracked separately. MCP configuration generation does not prove native tool discovery in an already-running AI client.

The following sections document the underlying workspace preparation tools.
## Read-only host check

Run from Windows PowerShell:

```powershell
.\Test-Host.ps1
```

The command emits JSON describing Windows, PowerShell, Hyper-V feature/cmdlet/service visibility, firmware virtualization reporting, and the requested VM names. It reads no credentials and makes no changes. VM inventory is queried once with terminating errors enabled and names are compared exactly, case-insensitively. If inventory fails, each requested VM reports `exists: null`; failure is never treated as absence.

## Review-only resource plan

`Prepare-Channels.ps1` validates the proposed VM names, installation-media path, target paths, existing VM inventory, and path collisions. It never creates a VM or directory.

```powershell
.\Prepare-Channels.ps1 `
  -IsoPath 'D:\InstallMedia\Windows.iso' `
  -RootPath 'D:\Hyper-V\qicheng-channels'
```

The default proposal contains `qicheng-win-1` and `qicheng-win-2`, each with Generation 2 firmware, 4 virtual processors, 8 GiB static memory, and an 80 GiB dynamically expanding VHDX. Paths must be fully qualified local-drive paths. VM names use a short allowlist, and every normalized VM path must remain beneath the requested root. Missing media, unavailable VM inventory, unsafe names or paths, existing VMs, and existing target paths fail closed.

The plan is emitted as JSON with `not-deployed`, `review-only`, and `hostChangesMade: false`. The `.iso` check here validates only the local path and extension; media authenticity, hash, edition, licensing, and bootability require separate review.

## Plan or create the VMs

`New-ChannelVMs.ps1` calls the same strict plan validation, requires a caller-supplied SHA-256, verifies the complete file before any mutation, and requires exactly one existing Hyper-V switch with the supplied name. It does not create a switch.

Its default mode is still review-only:

```powershell
.\New-ChannelVMs.ps1 `
  -IsoPath 'D:\InstallMedia\Windows.iso' `
  -ExpectedSha256 '<64-hex-character-reviewed-hash>' `
  -RootPath 'D:\Hyper-V\qicheng-channels' `
  -SwitchName 'Default Switch'
```

Exercise the complete preflight and PowerShell approval path without changing the host:

```powershell
.\New-ChannelVMs.ps1 `
  -IsoPath 'D:\InstallMedia\Windows.iso' `
  -ExpectedSha256 '<64-hex-character-reviewed-hash>' `
  -RootPath 'D:\Hyper-V\qicheng-channels' `
  -SwitchName 'Default Switch' `
  -Apply -WhatIf
```

Creation requires the explicit `-Apply` switch and PowerShell confirmation:

```powershell
.\New-ChannelVMs.ps1 `
  -IsoPath 'D:\InstallMedia\Windows.iso' `
  -ExpectedSha256 '<64-hex-character-reviewed-hash>' `
  -RootPath 'D:\Hyper-V\qicheng-channels' `
  -SwitchName 'Default Switch' `
  -Apply
```

Before `-Apply`, `RootPath` must already exist. The script creates only the two dedicated VM roots and their children. For each VM it creates the dynamic VHDX and Generation 2 VM, configures 4 vCPU and 8 GiB static memory, enables Secure Boot with the Windows template, attaches the verified ISO, and generates a separate local key protector before enabling vTPM. It does not start either VM.

Successful structured output includes VM IDs, realized BIOS GUIDs, configuration/disk/media paths, state, Secure Boot state, and TPM state. It never outputs key-protector bytes or fingerprints. If creation fails after a resource has been created, the script reports `partial-failure-preserved`, completed steps, and created resources. It deliberately does not delete a VM or VHDX automatically.

The script does not install Windows, accept an EULA, activate Windows, log into Windows or an application, enable Enhanced Session sharing, open host ports, change firewall rules, change virtualization/security settings, or start the VMs.

## Host and guest communication prototype

The `guest/` prototype is intended to run inside the interactive session of the selected Windows VM. It uses Python 3.12+ `AF_HYPERV`, verifies VM identity, refuses session 0 and non-default/secure desktops, and exposes bounded state, control, input, and screenshot operations. See [`guest/README.md`](guest/README.md).

The `host/` prototype connects to one explicitly configured VM identity and token, with no TCP endpoint and no host-desktop input fallback. It includes a bounded MCP process for one project per process. See [`host/README.md`](host/README.md).

The components have unit coverage and Node01 live guest communication, screenshot and Chinese input evidence. Release acceptance remains scoped: sustained operation, recovery, final installed user flow and native AI-client discovery are separate checks.

## Prepare a portable guest payload

`Build-GuestPayload.ps1` packages an already extracted, trusted Python embeddable distribution with the current `guest/` source for later offline transfer, such as a reviewed data ISO. It requires a specific nonzero BIOS UUID and a PM-generated token file. The builder verifies that `python.exe` has a valid Python Software Foundation Authenticode signature, preserves the embedded Python license and existing standard-library `_pth` entries, and adds the payload root to the isolated Python search path.

```powershell
.\Build-GuestPayload.ps1 `
  -EmbeddedPythonDirectory 'D:\InstallMedia\python-embed-amd64' `
  -OutputDirectory 'D:\Payloads\qicheng-win-1' `
  -BIOSUUID '11111111-2222-4333-8444-555555555555' `
  -TokenFile 'D:\Private\qicheng-win-1.token'
```

The output is a new directory containing `python/`, `guest/`, `.local/channel.token`, and `Start-Channel.cmd`. The token value is copied only into the output `.local` file and is never printed. Source/output overlap, an existing output, traversal, nonabsolute paths, a zero or invalid UUID, an invalid token, an invalid Python signature, a missing license, or an unsafe `_pth` entry fails before output creation.

Run `Start-Channel.cmd` manually only inside the intended guest's logged-in interactive session after reviewing the payload. It invokes `python -m guest.agent` with the fixed BIOS UUID and bundled token path. Raw agent stdout/stderr is suppressed; the wrapper prints only fixed redacted status lines and the process exit code. The payload builder does not start the agent, modify a VM, install Python, install Windows, configure automatic login, create a startup task/service, or copy anything to a guest.

## Install through PowerShell Direct

`Install-GuestPayloadDirect.ps1` is the supported installation candidate for a Windows guest whose local account setup is complete. It uses PowerShell Direct, so it does not enable guest file-copy integration, shared drives, or a network listener. Supply the guest credential only as an in-memory `PSCredential`; do not place a plaintext password in a command, script, or file.

First inspect the plan. Plan mode validates the protected payload and manifest, the exact VM ID, its Running state, and the host BIOS mapping, but does not open a PowerShell Direct session or change the guest:

```powershell
$credential = Get-Credential -UserName 'qicheng' -Message 'Credential for the intended guest local account'
.\Install-GuestPayloadDirect.ps1 `
  -VMName 'qicheng-win-1' `
  -ExpectedVMId '11111111-2222-4333-8444-555555555555' `
  -PayloadDirectory 'D:\Payloads\qicheng-win-1' `
  -Credential $credential
```

A successful plan reports `status: not-installed`. Review it before exercising the approval path with `-Apply -WhatIf`. Installation requires an explicit `-Apply` and PowerShell confirmation:

```powershell
.\Install-GuestPayloadDirect.ps1 `
  -VMName 'qicheng-win-1' `
  -ExpectedVMId '11111111-2222-4333-8444-555555555555' `
  -PayloadDirectory 'D:\Payloads\qicheng-win-1' `
  -Credential $credential `
  -Apply
```

Apply additionally requires that the credential identifies the user currently logged into the guest console. The script rechecks the guest BIOS UUID, creates a protected per-user installation under that account's `AppData\Local\Qicheng\channel`, copies and rehashes the manifest files, and registers an Interactive/Limited at-logon task. It refuses an existing installation root or task. It does not configure automatic login or store a password in the task.

`installed-and-start-requested` means the task was registered and `Start-ScheduledTask` accepted the request. It is not proof that the agent is running or reachable. A live acceptance record must still confirm the PowerShell Direct connection, guest identity/BIOS/console user, resulting guest ACL, copied-file hashes, registered task, start request, session removal, and a real host-to-guest channel exchange. A partial failure preserves copied guest files and reports whether the task was registered and whether a start was requested.

Use the PowerShell Direct deployment flow above for the supported guest installation path.

## Safety tests

```powershell
.\tests\Test-PlanSafety.ps1
.\tests\Test-ProvisionSafety.ps1
.\tests\PayloadSafety.Tests.ps1
.\tests\InstallGuestPayloadDirect.Tests.ps1
```

The plan tests cover path and name validation, missing media, collisions, inventory failures, and absence of deployment side effects. The provision tests mock Hyper-V mutations and verify that a hash mismatch, VM collision, or inventory failure produces zero mutation calls; they also verify default plan mode and `-Apply -WhatIf` remain non-mutating. Payload tests use temporary fixtures and a controlled signature mock to verify layout, license and `_pth` preservation, token non-disclosure, path rejection, and pre-mutation failures without starting the guest agent. The Direct installer test checks safe inherited payload ACLs, the required runtime manifest, plan/WhatIf isolation, and registration/start state ordering without creating a session or changing a VM. These tests do not replace live Hyper-V and guest acceptance.

## Guest setup checks before live deployment

Use the VMConnect **Basic session** and sign in to the intended guest local user. An Enhanced session can place the user in a remote desktop session while the console is empty; the Direct installer deliberately refuses that mismatch. Keep host drive and clipboard sharing disabled. Closing a viewer must not be treated as proof that the guest desktop stays available; verify it through the channel.

Fresh Windows Enterprise Evaluation installations must be activated normally. An unactivated evaluation can shut itself down every hour, even immediately after installation. Check its activation status and use Microsoft's normal online activation process (`cscript.exe //Nologo C:\Windows\System32\slmgr.vbs /ato` inside the guest) if needed. A successful evaluation is time limited and is not a production license. See [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise) and [Microsoft activation command documentation](https://learn.microsoft.com/en-us/windows-server/get-started/activation-slmgr-vbs-options). Do not alter the clock, disable the licensing service, or bypass activation.

## Repository and license boundary

This Windows channel module is available under [Apache-2.0](LICENSE). Windows, Python and WeChat Developer Tools remain separate dependencies governed by their respective licenses. Windows images, credentials and customer workspaces are not included. Source and releases: [Qicheng Agent Channels](https://github.com/Duan-zx/qicheng-agent-channels).
