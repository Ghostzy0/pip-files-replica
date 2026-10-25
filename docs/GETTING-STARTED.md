# Getting started

Files Replica is an experimental neutral macOS app for selected-folder rules. It is an independent, partial Hazel-workflow recreation. The current stage is source-first: there is no binary release, and native replica acceptance for this exact source is pending.

## Requirements

- macOS 14 or later and Apple's Swift toolchain.
- Xcode Command Line Tools; no paid account, model, Python package, cloud service or external Swift package is required.
- The current app is unsandboxed and stores selected-folder metadata and operation history locally. Keep disposable samples and backups until you understand recovery.

## Build and launch

```sh
git clone https://github.com/Ghostzy0/pip-files-replica.git
cd pip-files-replica
swift --version
swift test --jobs 2
./scripts/build.sh
codesign --verify --deep --strict 'dist/Files Replica.app'
open 'dist/Files Replica.app'
```

With the package executable, you can start an unbundled development instance by running `swift run PipFiles --replica`. Packaged bundles use the edition marker embedded in their app bundle; development overrides do not select the packaged app's data folder.

### Release build symbols

The packaging script uses Swift's normal backend selection and builds Release without DWARF debug information:

```sh
./scripts/build.sh replica
```

This follows repeated local stalls during `dsymutil` with both tested Swift build backends; the cause has not been established. The Release build still uses normal optimization and proceeds through stripping, the local-path scan, notice copying, code signing, signature verification, and atomic promotion. The Debug configuration remains available for local diagnostics with debug information. A successful command and package checks are required; changing the symbol format is not itself evidence of a completed build.

## Try a disposable sample

1. Use the app's sample action to create its synthetic workspace.
2. Review the selected inbox and saved rule.
3. Run Preview and inspect the matching file, operation and destination.
4. Apply only the sample operation you intended.
5. Check History and use Undo; confirm the sample file returns to its original path.

Leave background rules paused for this first check. Do not begin with Downloads, Documents, a shared volume or any other personal folder. A file-settling check cannot guarantee that every writer has finished.

## Signing and status

Local builds use ad-hoc signatures. The repository has no binary release and the app is not Developer ID signed or notarised. A successful compile, test run or package build is not proof of native workflow acceptance. Consult [Testing](TESTING.md) for the exact evidence state before relying on it.
