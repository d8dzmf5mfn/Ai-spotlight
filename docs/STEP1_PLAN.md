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

### 1.1 `Sources/AISpotlightKit/Search/SearchBackend.swift` (new, ≤ 50 lines)

```swift
// Signature only — implementation is empty stubs.
public protocol SearchBackend: Sendable {
    var name: String { get }
    func search(intent: Intent, limit: Int) async -> [SearchResult]
}
```

This is the **only** new protocol in Step-1. `SearchProvider`
(the existing protocol in `Sources/AISpotlightKit/Providers/SearchProvider.swift`)
stays untouched.

### 1.2 `Sources/AISpotlightKit/Search/MDQueryBackend.swift` (new, ≤ 80 lines)

A thin wrapper around the current `ContentSearchProvider`. The
goal is to make `ContentSearchProvider` conform to
`SearchBackend` without modifying `ContentSearchProvider`
itself.

If wrapper-by-inheritance or wrapper-by-composition turns out
ugly, defer to Step-1.1 (see §3) instead of growing this file.

### 1.3 `Sources/AISpotlightKit/Search/SQLiteBackend.swift` (new, ≤ 80 lines)

- Hardcoded DB path:
  `~/Library/Application Support/AISpotlight/search_augment.sqlite`
- `init()` opens the DB, runs schema migration if first launch
- `search(intent:limit:)` returns empty `[]` always (no data
  writes yet; no FTS5 queries yet)
- Documented in the file's header comment: "Step-1 stub; query
  implementation lands in Step-3 merge layer."

### 1.4 `Sources/AISpotlightKit/Search/SearchConfig.swift` (new, ≤ 40 lines)

```swift
public struct SearchConfig: Sendable {
    public var useSQLiteAugmentation: Bool = false
    public init() {}
}
```

No other config fields in Step-1. Weights, boost constants, etc.
arrive in Step-3.

---

## 2. Modified files

### 2.1 None

That's the point. Step-1 is purely additive. `ContentSearchProvider`,
`SearchOrchestrator`, `AppState`, `main.swift` — all unchanged.

If you find yourself wanting to modify any of these, stop. That
is Step-2 or later.

### 2.2 `Tests/AISpotlightKitTests/SearchBackendProtocolTests.swift` (new, ≤ 50 lines)

A single conformance test:

```swift
func testMDQueryBackend_conformsToSearchBackend() {
    let backend: SearchBackend = MDQueryBackend()
    // assert it accepts the protocol and returns [SearchResult]
}
```

That's it. No round-trip SQLite tests in Step-1 (those are
Step-3 with the merge engine).

---

## 3. Deferred decisions (DO NOT solve in Step-1)

These are explicitly **out of scope** for Step-1, even though
they're tempting:

| Decision | Deferred to | Why |
|---|---|---|
| How to wire `SearchBackend` into `SearchOrchestrator` | Step-2 (or later) | `SearchOrchestrator` change is a runtime integration; Step-1 is type-only |
| How `useSQLiteAugmentation` is read at runtime | Step-3 | No need to read it before SQLite actually has data |
| `HybridBackend` shape | Step-3 | Can't design merge without knowing both backends' output shapes |
| Schema migration versioning | Step-2 | One migration is fine for v1 |
| `user_signals` writes | Step-2 or later | Step-1 only creates the empty table |
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
- Step-1 does **not** introduce a SQLite write path. The DB file
  gets created on first launch, but stays empty.
- Step-1 does **not** prove the architecture works. Step-3 is
  where the merge engine proves it.

If you want a working hybrid, you have to ship Step-1, Step-2,
Step-3, and Step-4. That's the price of the anti-inflation
constraint.
