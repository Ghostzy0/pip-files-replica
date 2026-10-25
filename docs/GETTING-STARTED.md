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

### Select a Swift build backend when needed

The script uses Swift's default backend when `PIP_FILES_BUILD_SYSTEM` is unset. On 25 October 2026, the host's default `swiftbuild` Release path stalled during `dsymutil`; the installed `swift build --help` listed `native`, `swiftbuild`, and `xcode` as supported backends. To retry with Swift's native backend:

```sh
PIP_FILES_BUILD_SYSTEM=native ./scripts/build.sh replica
```

This selects only Swift's build backend. The normal Release configuration, stripping, local-path scan, notice copying, code signing, signature verification, and atomic promotion still run. A successful command and package checks are required; the fallback is not itself evidence of a completed build.

## Try a disposable sample

1. Use the app's sample action to create its synthetic workspace.
2. Review the selected inbox and saved rule.
3. Run Preview and inspect the matching file, operation and destination.
4. Apply only the sample operation you intended.
5. Check History and use Undo; confirm the sample file returns to its original path.

Leave background rules paused for this first check. Do not begin with Downloads, Documents, a shared volume or any other personal folder. A file-settling check cannot guarantee that every writer has finished.

## Signing and status

Local builds use ad-hoc signatures. The repository has no binary release and the app is not Developer ID signed or notarised. A successful compile, test run or package build is not proof of native workflow acceptance. Consult [Testing](TESTING.md) for the exact evidence state before relying on it.
