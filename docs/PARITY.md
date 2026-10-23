# Workflow parity and gaps

Files Replica is an original implementation inspired by selected Hazel workflows. It is a partial recreation, not a vendor-authored product, complete clone or full 1:1 parity claim. Evidence levels below distinguish the official manual from direct application observation and Files tests.

| Area | Evidence state | Current statement |
| --- | --- | --- |
| Folder and rule concepts | Documented in the official manual | Hazel documents adding folders, ordered rules, conditions and actions. |
| Rule editor layout | Documented only | The manual shows name, all/any/none grouping, condition controls, ordered actions and Save validation. The current Hazel rule workspace was not directly observed for this source snapshot. |
| Rule preview and status | Documented only | The manual describes single-file rule preview with condition results and a separate status table. Files' folder-wide action preview is a different workflow. |
| Files engine | Source implemented; build/test/native state recorded separately | Selected direct regular files, limited predicates, file actions, preview, Apply, history and Undo share the custom project's engine. |
| Visual/layout match | Pending same-input native review | No claim of pixel or interaction equivalence to the live reference UI. |
| Advanced rules | Not implemented | No recursion, nested groups, scripts, content/metadata matching, date templates, regex/tokens, Continue Matching Rules, sharing UI or daemon. |

## Safety and behavior differences

- Preview is read-only; applying changes requires an explicit action.
- Background rules are a separate opt-in and start paused; they run only while the app stays open.
- Existing destination paths are not replaced. Direct regular files are handled; directories and symlinks are not traversed.
- History and Undo follow the Files engine's conservative journal/recovery model, which differs from Hazel.
- Stability checks cannot prove every writing process has finished. Multi-action rules can partially complete and may need reverse-order Undo or manual inspection.

This page should be updated only when a specific reference version, evidence identifier and actual tested build support the change. Manual evidence is not presented as runtime observation.
