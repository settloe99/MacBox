# MacBox for 86Box

A community-maintained fork of [MacBox by Moonif](https://github.com/Moonif/MacBox), providing a macOS interface for managing virtual machines running in [86Box](https://github.com/86Box/86Box).

## Features

- Create and manage multiple virtual machines.
- Create virtual machines from hardware-based templates.
- Import existing 86Box virtual machines.
- Manage 86Box application and ROM updates.
- Check for MacBox application updates.
- Select a custom 86Box version for individual virtual machines.

## Download

Download MacBox from the [settloe99/MacBox releases page](https://github.com/settloe99/MacBox/releases).

### Compatibility

The initial maintained release targets:

- Apple Silicon Macs (ARM64).
- macOS 12 Monterey or later.

Intel Mac support and older macOS versions have not yet been verified for this release. They should not be assumed compatible.

### macOS security

MacBox is distributed with ad-hoc code signing. It is not signed with an Apple Developer ID certificate or notarised by Apple.

macOS may block the application when it is first opened. If you trust the download and choose to allow it, attempt to open MacBox, then visit **System Settings > Privacy & Security > Open Anyway**.

See [Apple's instructions](https://support.apple.com/en-gb/guide/mac-help/mh40617/mac).

Do not disable Gatekeeper system-wide.

### Release authentication

Releases include:

- `MacBox-v<version>.zip`: the application package.
- `MacBox-release.manifest`: release version and SHA-256 checksum.
- `MacBox-release.manifest.sig`: cryptographic signature.

The maintained updater uses an embedded public key to authenticate release manifests and verify update packages. Ad-hoc code signing does not provide Apple-verified publisher identity.

## Original project

MacBox was originally created by [Moonif](https://github.com/Moonif/MacBox). This fork preserves the original project's attribution and licence.

See [LICENSE](LICENSE) for licence terms.
