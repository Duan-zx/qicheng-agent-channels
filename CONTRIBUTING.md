# Contributing

Start with a reproducible issue: package version, Windows/Docker/Python versions, channel number, steps and sanitized errors. See [validation limits](docs/VALIDATION.md) before treating an untested integration as supported.

Keep changes focused. Preserve data volumes, compatibility identifiers and explicit takeover/pause behavior. Do not add host-input fallback when a guest request fails. Never commit tokens, profiles, private logs or third-party installers.

For Lite changes, run `python -m unittest discover -s tools/agent-channels/tests`, build using `tools/agent-channels/product/Build-Package.ps1` with a new output directory, and describe what you actually tested. Mock/package tests do not prove guest input or a second machine's installation. If changing the public source allowlist, update the corresponding SHA-256 source manifest.

Source contributions are under this repository's Apache-2.0 license. Third-party dependencies keep their own licenses. Please document new dependencies and avoid unrelated reformatting or generated artifacts in source patches.
