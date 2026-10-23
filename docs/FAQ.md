# FAQ

## Is this a Hazel clone?

It is an independent, partial recreation of selected Hazel workflows, based on published documentation and limited reference access. No complete feature or layout parity is claimed. No Hazel source code, product assets or vendor identity are included. See [parity](PARITY.md) and [reference notes](REFERENCE-NOTES.md).

## What can it do?

The shared engine supports ordered rules over direct regular files in selected folders, read-only previews, explicit Apply, operation history and conservative Undo. The public README and [testing record](TESTING.md) describe what has actually been built and verified. Features mentioned in a roadmap are not current capabilities.

## Does it upload my files?

No network or hosted AI is part of the app. Folder names, paths, bookmarks and operation history are stored locally and are not encrypted. The app is unsandboxed; only choose a disposable sample until you understand the access and recovery boundaries.

## Does it run rules automatically?

Only after you separately opt into background rules. They run while the app is open and start paused on each launch. A stability interval cannot prove that every writer has finished. Avoid active downloads, builds and changing folders.

## Does it support subfolders, scripts or content matching?

No. It currently handles direct regular files only, with a limited set of name, extension, size and age conditions and file operations. It has no recursion, scripting, content search, nested conditions, rule import/export or login daemon. More detail is in [parity and gaps](PARITY.md).

## Where is the data stored?

The packaged neutral app uses its own `Files Replica` application-support folder. Development runs have a distinct data identity. The app does not migrate another edition's history into this directory.

## Are signed downloads available?

No binary release is published in this source stage. Locally built packages use ad-hoc signing; they are not Developer ID signed or notarised. Do not disable Gatekeeper to run them.
