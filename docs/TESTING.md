# Testing and acceptance

This page records gates for the exact clean source export. A build, unit test, screenshot or manual description does not imply completion of the other gates.

## Source checks

```sh
swift test --jobs 2
./scripts/build.sh
codesign --verify --deep --strict 'dist/Files Replica.app'
```

Continuous integration should run the test suite and build only the canonical `replica` profile on `macos-14`. Neutral Plus, Pip Core and Pip Plus belong to the separate custom repository.

## Acceptance matrix

| Gate | Current state |
| --- | --- |
| Deterministic engine and app-state tests | Hosted macOS 14 CI passed at tested code commit `f5fa7edea79d984541c3efdfbe4af419d8e90e64` ([run 40117713029](https://github.com/Ghostzy0/pip-files-replica/actions/runs/40117713029)); CI at main merge `ee4c63cffdd2ec0215d27ade8c86be1f29e5c214` also passed ([run 40119444296](https://github.com/Ghostzy0/pip-files-replica/actions/runs/40119444296)). |
| Clean `replica` package build | Hosted macOS 14 CI ran `./scripts/build.sh` and passed at both refs above. No hosted executable hash or strict-signature result is claimed here. |
| Synthetic native folder selection, rule edit, preview, apply, history and undo | Pending for this replica source revision until an exact-build receipt is added. |
| Keyboard, Save validation, cancellation and accessibility | Pending exact-build checks. |
| Direct same-input Hazel workflow/layout comparison | Pending native reference observation; no current parity claim. |
| macOS 14 runtime and Intel | Not verified unless a separate exact-host run is recorded. |
| Developer ID signature and notarisation | Not performed. |

Before any binary release, add dated exact-package evidence and outcomes. Never claim a gate passed without its linked log or reproducible test result.
