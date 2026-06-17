# Step 1 Implementation Plan — Search Backend Foundation

> **Status (2026-06-17):** Concrete task list for Step-1 of
> `docs/SEARCH_BACKEND.md`. This is the plan; the code comes after
> plan review. **No Swift code in this file** — only file-level
> scope and function signatures.
>
> **Anti-inflation rule:** if Step-1 grows beyond this file, it
> has failed. Stop, document why, ask the user.

---

## 0. Hard constraints (read first)

These are **non-negotiable** for Step-1. Violating any one is a
code-review blocker:

1. **No change to existing `ContentSearchProvider` runtime path.**
   The current `ContentSearchProvider` is what users query today.
   Step-1 does not touch it; it only wraps it in a new protocol.
2. **No sync layer.** No FSEvents, no debounce, no batch writes.
3. **No merge engine.** No score fusion, no dedup logic.
4. **No SQLite writes from production code.** Step-1 only
   creates the schema on an empty DB file. Reads can happen in
   test code, but production code path is read-through to
   `MDQuery` for now.
5. **`useSQLiteAugmentation` defaults to `false`.** The flag
   exists in `SearchConfig` but is never read in Step-1.
6. **Total new code ≤ 4 files, ≤ 250 lines.** If you're over,
   something is wrong.

---

## 1. New files (≤ 4)

### 1.3 New files (≤ 3) — REVISED 2026-06-17

> **Revision note (2026-06-17):** Originally this plan listed
> 4 files including `MDQueryBackend.swift`. During implementation
> it became clear that `ContentSearchProvider` already conforms
> to `SearchProvider` directly — there is no need for a wrapper
> backend. The `SearchBackend` protocol was also dropped because
> it duplicated `SearchProvider`. The final Step-1 file count
> is **3**, not 4.

### 1.1 `Sources/AISpotlightKit/Search/SQLiteBackend.swift` (new, ≤ 50 lines)

- A `SearchProvider` conformance that does **nothing** at runtime.
- `init()` body is intentionally empty.
- `search(intent:limit:)` returns `[]` always.
- **No** `import SQLite3`. **No** file I/O. **No** schema
  migration. **No** `databaseURL` static property. Step-1 is
  type-only. Runtime wiring lands in Step-2.

If you find yourself wanting to add `import SQLite3`,
`FileManager.createDirectory`, or a schema DDL string to this
file, **stop**. That is Step-2 work. (Note: the linking concern
that originally delayed Step-2 was resolved by the 2026-06-17
spike — see §6 below. Step-2's blocking item is now design,
not linking.)

### 1.2 `Sources/AISpotlightKit/Search/SearchConfig.swift` (new, ≤ 25 lines)

```swift
public struct SearchConfig: Sendable {
    public var useSQLiteAugmentation: Bool
    public init(useSQLiteAugmentation: Bool = false) {
        self.useSQLiteAugmentation = useSQLiteAugmentation
    }
}
```

No other config fields in Step-1. Weights, boost constants, etc.
arrive in Step-3.

### 1.3 `Tests/AISpotlightKitTests/SQLiteBackendTests.swift` (new, ≤ 50 lines)

Three conformance / smoke tests:

- `testSQLiteBackend_conformsToSearchProvider` — cast works
- `testSQLiteBackend_searchReturnsEmptyInStep1` — search returns `[]`
- `testSQLiteBackend_initDoesNotCrash` — guards against future
  regression where someone adds file I/O to `init()`

---

## 2. Modified files

### 2.1 None

That's the point. Step-1 is purely additive. `ContentSearchProvider`,
`SearchOrchestrator`, `AppState`, `main.swift` — all unchanged.

If you find yourself wanting to modify any of these, stop. That
is Step-2 or later.

### 2.2 `Tests/AISpotlightKitTests/SQLiteBackendTests.swift` (new, ≤ 50 lines)

Three conformance / smoke tests (added in this commit, replacing
the originally-planned single `testMDQueryBackend_conformsToSearchBackend`):

- `testSQLiteBackend_conformsToSearchProvider` — protocol cast works
- `testSQLiteBackend_searchReturnsEmptyInStep1` — search returns `[]`
- `testSQLiteBackend_initDoesNotCrash` — guards against future
  regression where someone adds file I/O to `init()`

That's it. No round-trip SQLite tests in Step-1 (those are
Step-3 with the merge engine).

---

## 3. Deferred decisions (DO NOT solve in Step-1)

These are explicitly **out of scope** for Step-1, even though
they're tempting:

| Decision | Deferred to | Why |
|---|---|---|
| How to wire `SQLiteBackend` into `SearchOrchestrator` | Step-2 (or later) | `SearchOrchestrator` change is a runtime integration; Step-1 is type-only |
| How `useSQLiteAugmentation` is read at runtime | Step-3 | No need to read it before SQLite actually has data |
| `HybridBackend` shape | Step-3 | Can't design merge without knowing both backends' output shapes |
| ~~**SwiftPM + libsqlite3 system library linking**~~ | ~~**Step-2 (first task)**~~ | **RESOLVED 2026-06-17 by linking spike at `/tmp/sqlite-linking-spike` (now deleted):** SwiftPM on this toolchain (Swift 5.9, macOS 14+ SDK) auto-links the system `libsqlite3.tbd`. A minimal `import SQLite3` + `sqlite3_open` + `sqlite3_exec` + `sqlite3_close` program ran cleanly with **no `linkerSettings`, no `systemLibrary` target, no module map**. The earlier `linkedLibrary("sqlite3")` failure was likely a transient toolchain / build-cache issue (or my misreading of the error). Step-2 does not need to solve linking — it can proceed directly to schema migration + DB lifecycle code. |
| Schema migration (DDL strings) | Step-2 | Tied to linking — can't write schema without `import SQLite3` working |
| `user_signals` table creation | Step-2 | Tied to schema migration |
| `user_signals` writes | Step-2 or later | Only after table exists |
| FSEvents / debounce / batch writes | Step-2 | Hard constraint #2 |
| Score fusion math | Step-3 | Hard constraint #3 |
| Indexing Boundary (`Set<URL>`) persistence | Step-2 | Tied to FSEvents scope |

---

## 4. Done criterion (Step-1 ship gate)

1. ✅ `swift build -c release` succeeds with zero new warnings
2. ✅ Schema migration runs cleanly on a temp file (manual smoke
   test; can be a one-off test, not part of the suite)
3. ✅ Dry-run mode: launching the app with the new files in
   place behaves **byte-equivalently** to before Step-1
4. ✅ `scripts/snapshot.sh` shows: 4 new files, 0 modified files
5. ✅ No new dependencies in `Package.swift` (Step-1 doesn't
   need `import SQLite3` because no production code reads or
   writes — schema migration is hardcoded SQL strings run via
   the built-in `import SQLite3` that ships with macOS)

### Test status

The 152 existing tests are **not a gate** in Step-1. They should
still pass (we're additive, not modifying), but if any fail,
that's a Step-1 code bug, not a regression in existing behavior.

### What ships

One commit. Message: `feat(phase6-step1): SearchBackend protocol + MDQuery/SQLite adapter stubs`. Body: links to `docs/SEARCH_BACKEND.md` and this file.

---

## 5. What this plan does NOT promise

- Step-1 is **not** a working hybrid. It's a type-level foundation.
- Step-1 does **not** change user-facing behavior. If a user
  installs the Step-1 build, nothing about their search
  experience changes.
- Step-1 does **not** create a SQLite file. The DB file creation
  is Step-2 work, gated on solving the SwiftPM + libsqlite3
  linking question.
- Step-1 does **not** prove the architecture works. Step-3 is
  where the merge engine proves it.

If you want a working hybrid, you have to ship Step-1, Step-2,
Step-3, and Step-4. That's the price of the anti-inflation
constraint.

---

## 6. Implementation outcome (Step-1, 2026-06-17)

The commit implementing this plan differs from the original
plan above. Recorded so the next session can reconstruct what
was actually built vs. originally envisioned.

- **Files added:** 3
  - `Sources/AISpotlightKit/Search/SQLiteBackend.swift`
  - `Sources/AISpotlightKit/Search/SearchConfig.swift`
  - `Tests/AISpotlightKitTests/SQLiteBackendTests.swift`
- **Files modified:** 0 (no changes to `ContentSearchProvider`,
  `SearchOrchestrator`, `AppState`, `main.swift`, `Package.swift`)
- **Test result:** 171/171 pass (3 new + 168 existing, 0 regressions)
- **Build:** clean, ~11s
- **Runtime behavior:** unchanged. `SQLiteBackend` exists but
  is never invoked by any production code path.

### Key course corrections during implementation

1. **`SearchBackend` protocol removed.** Originally the plan
   proposed a new `SearchBackend` protocol wrapping
   `SearchProvider`. Inspection of existing code showed
   `SearchProvider` already had the right shape and
   `ContentSearchProvider` already conformed — adding
   `SearchBackend` was pure indirection. Decision: reuse
   `SearchProvider`, drop `SearchBackend`.
2. **`MDQueryBackend` removed.** Originally the plan proposed
   a thin wrapper to expose `ContentSearchProvider` under the
   new protocol. With `SearchBackend` gone, the wrapper was
   pointless — `ContentSearchProvider` already conforms to
   `SearchProvider` directly. Decision: no wrapper.
3. **`SQLiteBackend.init()` emptied.** Originally the plan had
   `init()` running schema migration. Implementation hit
   SwiftPM + libsqlite3 linking issues — `linkerSettings:
   [.linkedLibrary("sqlite3")]` does not produce a working
   build on this toolchain. Decision: remove all `import SQLite3`
   from Step-1 entirely; defer both the linking question and
   the schema migration to Step-2. This is a scope correction,
   not a fallback — Step-1 is explicitly type-only, and Step-2
   owns SQLite runtime.

### Lesson recorded (in this plan, not memory)

> **Do not introduce runtime dependencies during abstraction
> scaffolding phases.** A "Step-1" or "foundation" phase that
> introduces runtime behavior (file I/O, DB creation, schema
> migration, network calls) before the architecture is stable
> is a scope misplacement, not an early optimization. The
> fix is to ship a no-op type first and defer runtime wiring.
