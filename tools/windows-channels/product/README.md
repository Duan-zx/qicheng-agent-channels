# Windows Channels product package

This directory builds a reviewable, per-user Windows package around the
experimental Hyper-V host client and viewer. It does not provision Windows,
download installation media, create VMs, copy guest payloads, enable Hyper-V,
or claim that the native Windows channel has passed live acceptance.

Build from a clean or reviewed checkout:

```powershell
.\Build-Package.ps1 -OutputDirectory 'D:\Build\QichengWindowsChannels'
```

The builder compiles the viewer, copies only the source allowlist declared in
`Build-Package.ps1`, writes SHA-256 manifests, and creates a zip beside the
package directory. Machine-local configuration, tokens, VM disks, ISO files,
project memory, `.local` directories, Git history, logs, and account state are
not discovered or copied.

Validate the packaging workflow without touching the real installation:

```powershell
.\tests\Test-ProductPackage.ps1
```

The generated package contains a double-click installer, the Chinese
quick-start guide, explicit existing-config import, launch and diagnostics,
stable per-project MCP launchers, opt-in Codex CLI registration, and
uninstallation. Program files and user data use separate per-user roots. The
`source/` subtree also carries the explicit guest, deployment, and test
allowlist needed to reproduce and review the Windows path in a public repo;
publication and licensing remain separate release decisions.
