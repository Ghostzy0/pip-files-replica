# Contributing

Run `swift test --jobs 2`, `./scripts/build.sh` and `codesign --verify --deep --strict 'dist/Files Replica.app'` before proposing a focused change. Include a synthetic disposable reproduction for file-operation changes and state the exact source revision and host.

Keep Preview read-only, refuse destination replacement and preserve uncertain recovery records for inspection. Do not add personal-folder defaults, shell scripts, uploads or unrequested network services. Keep public claims aligned with `docs/PARITY.md` and `docs/TESTING.md`; manual documentation is not runtime observation.

Never include personal file paths, bookmarks, journals, credentials, private reference captures, vendor assets or internal project files in an issue or pull request. Preserve the MIT notice and update third-party notices if dependencies or assets change.
