# Fennec

Run `just lint` and `just test` before pushing. CI runs the same recipes.

## Rules

| Rule | Enforced by |
|---|---|
| Guard shared state with `Mutex`/`Atomic`, never `@unchecked Sendable` or `nonisolated(unsafe)` | `just lint` |
| Hand C callbacks a retained receiver (`FSEventStreamContext.retaining(_:)`), never `Unmanaged.passUnretained` | `just lint` |
| No `// MARK:` banners | `just lint` |
| Folder-list keys live in `FolderKey`; the shortcuts panel reads `allCases` | Architecture |
| Comments only for platform quirks or a non-obvious why, one line, never what the code does | This file |
| Put meaning in names and types (enums, separate flags), not in comments or optional sentinels | This file |

## Lint exceptions

Put `// lint-allow: <reason>, expires YYYY-MM-DD, approved-by <name>` on the offending line. A human must approve it. Expired exceptions fail.
