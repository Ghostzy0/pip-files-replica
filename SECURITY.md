# Security and file safety

Experimental local file automation needs careful testing. Use disposable folders and backups. Do not submit private documents, paths, credentials, bookmark data or raw journals in public issues. Report a minimal synthetic reproduction through the repository's GitHub reporting facilities if available; otherwise open a non-sensitive issue requesting a private contact route. No response-time guarantee.

Rules have no shell/script/network action. Preview is read-only. Apply revalidates selected folder/config/source/result paths and refuses collisions. Undo verifies unchanged output and fails closed on ambiguity. A multi-action sequence is not atomic; interrupted actions are recorded for manual recovery. No app can promise safety against every adversarial local filesystem change, unavailable volume or hardware failure. Source tests document bounded invariants, not universal filesystem guarantees.

No automatic updater or external dependency is bundled. Builds are ad-hoc signed, not notarised unless a specific release explicitly says otherwise. Never disable operating-system protections globally to run this app.

Copy/ZIP Undo retains hidden sibling recovery files; it never automatically unlinks a path. Move/rename uses a journaled random sibling stage and verifies the staged result before proceeding. Uncooperative concurrent writers can still race name-based renames; uncertain results are preserved for manual inspection. No atomic inode-conditional rename or power-loss guarantee is made. Hidden retained files consume storage and are never auto-purged.
