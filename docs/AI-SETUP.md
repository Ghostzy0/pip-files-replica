# AI setup

Paste this short request into an assistant with terminal access:

> Build Files Replica from this checkout, run its tests and verify the ad-hoc signature. Launch only Files Replica and use its disposable sample with background rules paused. Never open personal folders or change macOS security settings; report test, build and native acceptance evidence separately.

Commands from the repository root:

```sh
swift test --jobs 2
./scripts/build.sh
codesign --verify --deep --strict 'dist/Files Replica.app'
open 'dist/Files Replica.app'
```

For an unbundled development launch, use `swift run PipFiles --replica`. Do not use other edition flags during this check. The packaged app is selected from its embedded marker; development arguments and environment overrides cannot redirect packaged app data.
