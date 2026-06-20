# AI Spotlight v1 — Debug Issues for External Help

## Environment
- macOS 27.0 (26A5353q) — Sequoia beta
- Swift 6.4 (Xcode 27 beta)
- arm64e

---

## Issue 1: MDQuery CRASH with Chinese characters (SIGSEGV)

**Crash report:** `~/Library/Logs/DiagnosticReports/AISpotlight-*.ips`

```
Exception: EXC_BAD_ACCESS (SIGSEGV)
KERN_INVALID_ADDRESS at 0x000017e6518d46f8
Faulting thread: MDQueryExecute
```

**Crash stack:**
```
MDQueryExecute (imageIndex:12)
  → FileSystemAdapter.spotlightSearch (line 218, FileSystemAdapter.swift)
    → FileSystemAdapter.search (line 149)
      → FileSystemAdapterProvider.search
```

**Code (FileSystemAdapter.swift, around line 200-225):**
```swift
let mdQueryStr = "kMDItemDisplayName == '*\(escaped)*'cd"
guard let mdq = MDQueryCreate(kCFAllocatorDefault, mdQueryStr as CFString, nil, nil) else { return [] }
defer { /* CFRelease via Unmanaged */ }
defer { MDQueryStop(mdq) }
MDQueryExecute(mdq, CFOptionFlags(kMDQuerySynchronous.rawValue))  // ← CRASHES HERE
```

**Notes:**
- The identical code pattern (MDQueryCreate → defers → MDQueryExecute) works in `FileSystemProvider.swift` without issues.
- The difference: the query string contains Chinese characters: `kMDItemDisplayName == '*化学*'cd`
- The original `FileSystemProvider` builds queries like `kMDItemDisplayName == '*test*'` (ASCII only).
- Possibly a macOS 27.0 beta bug with MDQuery + CJK characters in predicate format.
- Also: `MDQuery` memory management in Swift is tricky — `MDQueryCreate` is Create Rule (+1), and it's unclear whether Swift ARC also manages CF types automatically, leading to double-free or premature release.

**Current mitigation:** Removed `FileSystemAdapterProvider` from search pipeline. Chinese search handled by SQLiteBackend LIKE fallback instead.

---

## Issue 2: FTS5 `unicode61` tokenizer + CJK characters

**Problem:** SQLite FTS5's `unicode61` tokenizer does NOT segment Chinese/Japanese/Korean text. A filename like `化学笔记.pdf` is indexed as a single token `化学笔记pdf`. Query `"化学"*` should match as a prefix but FTS5 returns 0 results.

**Current code (SQLiteBackend.swift, schema creation):**
```sql
tokenize = 'porter unicode61'
```

**Current workaround (added in Phase 6.2):**
```swift
if results.isEmpty, terms.contains(where: { $0.unicodeScalars.contains(where: { !$0.isASCII }) }) {
    // LIKE-based fallback on files table
    SELECT path, filename FROM files WHERE (filename LIKE '%化学%' OR path LIKE '%化学%') AND is_deleted = 0
}
```

**Need:** Either:
- Replace `unicode61` with `unicode61 cjk` tokenizer if available
- Implement a custom FTS5 tokenizer that handles CJK bigrams
- Or keep the LIKE fallback as-is

Note: changing the tokenizer requires re-indexing all files (schema migration).

---

## Issue 3: FileSystemProvider + Chinese characters

**File:** `FileSystemProvider.swift`

The original `FileSystemProvider` only handles `.findFile` intent and builds predicate:
```swift
parts.append("kMDItemDisplayName == '*\(escaped)*'")
```

For Chinese queries, the original `FileSystemProvider` is never called because:
- Before fix: Chinese single-token `"化学笔记"` was classified as `.openApp` (app search) → only `AppProvider` ran
- After fix: Chinese queries are classified as `.findFile` → `FileSystemProvider` + `ContentSearch` + `SQLiteBackend` all run

The original `FileSystemProvider` also uses MDQuery. It needs testing with Chinese characters.

---

## Issue 4: `isLoading` deadlock potential

**File:** `AppState.swift`, `runSearch()` method

```swift
isLoading = true; defer { isLoading = false }
```

`defer` runs on scope exit for the `async` function. If the function is cancelled mid-execution, `defer` still runs. But if a task is cancelled and another starts immediately, there could be a race where `isLoading` is set to `false` by the cancelled task while the new task should be `true`.

**Fix proposed but not yet implemented:** Use `CancellationController` from `AIStateMachine.swift` with generation guard.

---

## Issue 5: IndexEngine not wired into search pipeline

**Files:**
- `IndexEngine.swift` (created but never started in main.swift)
- `FileIndexItem.swift` (created but not used by any search provider)

The `IndexEngine` has `LocalIndexSource`, `CloudIndexSource`, and `ExternalIndexSource` but they are NOT registered or started anywhere. The existing `SyncService` + `SQLiteBackend` pipeline handles indexing independently.

**Need:** Either wire `IndexEngine` into AppState/main.swift or remove it.
