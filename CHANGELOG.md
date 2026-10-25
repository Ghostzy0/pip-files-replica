# Changes

## Unreleased
- Dirty-rule quit and close confirmation now uses an owned AppKit alert sheet; Escape resolves to Keep Editing and close Discard continues after sheet dismissal. Native retest of this correction remains pending. [Related issue #9](https://github.com/Ghostzy0/pip-files-replica/issues/9).
- The unsaved-draft confirmation now observes delegate state through a dedicated SwiftUI view modifier, addressing the reproduced missing-alert update. Direct native retest remains pending. [Related issue #9](https://github.com/Ghostzy0/pip-files-replica/issues/9).

- Release packaging now uses SwiftPM's default backend with `-debug-info-format none` after both attempted backends stalled during `dsymutil` on this host. The root cause remains unknown; the earlier attempts produced no verified package. The Release script still performs stripping, local-path scanning, notice copying, signing, signature verification and atomic promotion. Debug builds remain available for diagnostics. Neutral Core package and native acceptance remain pending. [Related issue](https://github.com/Ghostzy0/pip-files-replica/issues/9).

- Neutral Core now protects dirty inline rule drafts on app Quit and window close with a Keep Editing default/cancel action and explicit Discard Changes choice. Native retest of the exact Replica candidate remains pending; this source update does not establish acceptance. Related: [issue #9](https://github.com/Ghostzy0/pip-files-replica/issues/9).

- The Files Replica package includes the repository `LICENSE` and `THIRD-PARTY-NOTICES.md` under `Contents/Resources` before code signing. The Neutral Core candidate was built from public-source head `6f8255f9c13a042c17c4bbdb409deafea1989785` on macOS 27.0.1 arm64. A fresh package restore on 25 October verified archive structure and CRCs, bundle identity, executable hash and mode, source-matched notice bytes, and the ad-hoc signature with strict deep verification. This is package verification only: this exact candidate has not been run in the native GUI, and native acceptance and the binary release gate remain pending. This makes no broader legal-compliance claim. See [issue #7](https://github.com/Ghostzy0/pip-files-replica/issues/7).

- The Replica preview now gives guidance that stays accurate before and after Apply: review proposed changes first; applied actions are recorded in History. This copy-only correction addresses [issue #5](https://github.com/Ghostzy0/pip-files-replica/issues/5). A new native Move → Apply → History → Undo retest remains pending; the existing keyboard issue remains separate.

- The shared Plus export sheet uses a bounded scroll area. At the minimum supported window, 24 October native visual checks of Pip Plus and Neutral Plus showed full disclosures and all three controls in normal and refused-replacement states; refusal preserved the existing report bytes. Broader native and keyboard acceptance remains open. Neutral Plus Return activation is under investigation in the separate custom app's [issue #8](https://github.com/Ghostzy0/pip-files/issues/8). These checks do not establish Replica-specific native workflow acceptance; Neutral Core does not expose the Plus report UI.

- Improved History count, empty-state, timestamp and issue-caption contrast across the reference layout and Core fallback; Plus report notices retain their edition palette.

- Experimental independent neutral Files Replica source profile.
- No app binary is published.
