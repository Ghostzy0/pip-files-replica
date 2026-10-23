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
| Deterministic engine and app-state tests | Record the exact run and result for the exported source before publication. |
| Clean `replica` package build and strict signature check | Record command, host, source ref and app executable hash. |
| Synthetic native folder selection, rule edit, preview, apply, history and undo | Pending for this replica source revision until an exact-build receipt is added. |
| Keyboard, Save validation, cancellation and accessibility | Pending exact-build checks. |
| Direct same-input Hazel workflow/layout comparison | Pending native reference observation; no current parity claim. |
| macOS 14 runtime and Intel | Not verified unless a separate exact-host run is recorded. |
| Developer ID signature and notarisation | Not performed. |

Before publishing, replace this note with dated source/ref/build evidence and outcomes. Never claim a gate passed without its linked log or reproducible test result.
