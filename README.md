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

## MacBox 0.6.5

This release continues the maintenance of MacBox, originally
created by Moonif and now maintained by settloe99.

### Improvements

- Universal MacBox application and external updater helper,
  supporting Intel and Apple Silicon architectures.
- Automatic migration from the original Moonif MacBox installation.
- Preservation of existing virtual machines and missing legacy
  application preferences.
- Administrator-authorised updates for protected installations
  at `/Applications/MacBox.app`.
- Transactional application replacement with backup and rollback.
- Independent signed-release authentication and SHA-256 verification.
- Hardened ZIP archive validation.
- Improved experimental 86Box release descriptions.
- Correct numeric version comparisons and downgrade prevention.
- Release notes hidden when MacBox is up to date.
- Updated application attribution.

### Compatibility and distribution

The minimum deployment target remains macOS 12.0.

MacBox is distributed with ad-hoc code signing and independently
authenticated release packages. It is not Apple Developer ID
signed or notarised.

macOS may require initial approval through Privacy & Security.

### Validation

Production migration, application relaunch and VM preservation
have been tested on Apple Silicon.

Intel helper execution has been tested through Rosetta.
Native Intel hardware and all supported macOS versions have
not been independently tested.

Administrator-authorised migration, replacement and rollback
have passed isolated protected-installation tests. The complete
elevated production UI workflow has not been independently tested.
