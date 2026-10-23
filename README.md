# Files Replica

Files Replica is an experimental, independent macOS folder-rule implementation inspired by workflows documented in Hazel 6.1.2. It is not made by, sponsored by, or affiliated with Noodlesoft. This project uses original code and does not include Hazel code, branding assets, icons, images, or other product assets.

The project is a partial recreation. Its neutral interface and operation engine are still being checked against the reference. The current public source contains no app binary, and no full 1:1 or complete Hazel-parity claim is made. The older generic Files Baseline edition lives in the separate [Pip Files custom project](https://github.com/Ghostzy0/pip-files); it is preserved as an experimental workflow subset and is not relabelled as this replica.

The source tree retains shared MIT-licensed Pip-edition UI and icon-generator code used by the separate custom project. The default `replica` build selects the neutral Replica window and folder icon; that app does not show the Pip theme or character. This export includes no Pip screenshots or private/reference images.

## What it is for

Choose a folder, define an ordered rule, inspect a preview, and explicitly apply the reviewed operation. The implementation is local and uses Apple system frameworks. It has no account, hosted service, telemetry, model or required third-party package.

The current implementation is limited to selected folders and direct regular files. It does not recursively traverse folders, run scripts, delete files, or replace an existing destination. Preview is read-only. Background processing is separate, opt-in, limited to while the app remains open, and starts paused. See [known gaps](docs/PARITY.md) before using the app on anything other than a disposable sample.

## Build the neutral edition

On macOS 14 or later with Apple's Swift toolchain:

```sh
git clone https://github.com/Ghostzy0/pip-files-replica.git
cd pip-files-replica
swift test --jobs 2
./scripts/build.sh
codesign --verify --deep --strict 'dist/Files Replica.app'
open 'dist/Files Replica.app'
```

The build script defaults to the `replica` edition. For an unbundled development launch, use `swift run PipFiles --replica`; packaged app identity and saved data remain tied to its edition marker. Do not add a personal folder during the first run; use the built-in disposable sample and leave background rules paused.

These local builds are ad-hoc signed. No Developer ID signature, notarisation or downloadable binary is currently provided. Do not disable macOS security controls globally.

## Reference and evidence

The design work currently uses the [official Hazel manual](https://www.noodlesoft.com/manual/hazel/) as documented workflow evidence. No direct native comparison of the full Hazel rule workspace has been completed for this source snapshot. The manual, direct app observation, implementation inference and tested Files behavior are kept separate in [reference notes](docs/REFERENCE-NOTES.md) and [testing](docs/TESTING.md).

## Project details

- [Getting started](docs/GETTING-STARTED.md)
- [FAQ](docs/FAQ.md)
- [AI setup prompt](docs/AI-SETUP.md)
- [Workflow parity and gaps](docs/PARITY.md)
- [Testing and acceptance](docs/TESTING.md)
- [Reference notes](docs/REFERENCE-NOTES.md)
- [Release notes](docs/RELEASE-NOTES.md)
- [Roadmap](docs/ROADMAP.md)
- [License](LICENSE) · [Third-party notices](THIRD-PARTY-NOTICES.md) · [Security](SECURITY.md)

Maintained by [Ghostzy0](https://github.com/Ghostzy0). MIT licensed. File issues with synthetic examples only; never attach private folder paths, bookmarks, journals or user files.
