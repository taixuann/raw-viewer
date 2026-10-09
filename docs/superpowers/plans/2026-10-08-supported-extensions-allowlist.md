# Supported Extensions Allowlist and Inspection Offloading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict RawView source discovery to supported measurement file extensions (`.csv`, `.txt`, `.lvm`) so non-measurement files (`.log`, `.py`, `.sh`, `.json`, `.md`, dot-files) are completely skipped, offload progress I/O off `@MainActor`, and persist `profileID` in `IndexDatabase`.

**Architecture:** Update `ProjectContext.walkRawSources` with a positive allowlist of measurement extensions (`supportedRawExtensions: Set<String> = ["csv", "txt", "lvm"]`) while keeping exclusion checks. Offload modification time retrieval and `indexDB.upsertBatch` to the background task in `RawViewModel.inspectSources`. Add explicit `profile_id` column to `IndexDatabase`.

**Tech Stack:** Swift 6.0, macOS 14+, SQLite3, Swift Testing framework.

**Spec:** CONTRACT.md and user requirement to only inspect `.csv`, `.txt`, and `.lvm` measurement files.

## Global Constraints
- Target platform: macOS 14+ on Apple Silicon (arm64).
- Testing library: `swift-testing` (`import Testing`).
- CLI test invocation command:
  `swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib`
- Discovery must never read or stat excluded / non-measurement files.
- Main thread (`@MainActor`) must remain responsive without synchronous disk I/O.

## Review Focus
1. Hidden log files (`.intake.log`) in `data/raw/` must be skipped without reading or stat-ing.
2. Uppercase extensions (`.CSV`, `.TXT`, `.LVM`) must still be discovered and supported.
3. Non-measurement files (`run.log`, `test.py`, `info.json`, `data.dat`) must be omitted from discovery.
4. `IndexDatabase` must retain `profileID` across cache save and restore cycles even if different from `instrumentID`.
5. Background inspection progress batches must not execute blocking file stats or SQLite transactions on `@MainActor`.

---

### Task 1: Add Supported Extensions Allowlist to `ProjectContext`

**Files:**
- Modify: `Sources/RawViewCore/ProjectContext.swift:1-160`
- Test: `Tests/RawViewCoreTests/ProjectCatalogTests.swift`

**Interfaces:**
- Produces: `ProjectContext.supportedRawExtensions: Set<String> = ["csv", "txt", "lvm"]`
- Behavior: `walkRawSources` skips any file whose lowercased extension is not in `supportedRawExtensions`.

- [ ] **Step 1: Write the failing test in `ProjectCatalogTests.swift`**

```swift
@Test func discoveryIncludesOnlySupportedMeasurementExtensions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = root.appendingPathComponent("data/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    try Data("meas1".utf8).write(to: raw.appendingPathComponent("device.csv"))
    try Data("meas2".utf8).write(to: raw.appendingPathComponent("spec.txt"))
    try Data("meas3".utf8).write(to: raw.appendingPathComponent("labview.lvm"))
    try Data("meas4".utf8).write(to: raw.appendingPathComponent("UPPER.CSV"))
    try Data("log".utf8).write(to: raw.appendingPathComponent("run.log"))
    try Data("log".utf8).write(to: raw.appendingPathComponent(".intake.log"))
    try Data("script".utf8).write(to: raw.appendingPathComponent("run.py"))
    try Data("json".utf8).write(to: raw.appendingPathComponent("info.json"))

    let sources = try ProjectContext.open(root).discoverSources()

    #expect(sources.map(\.relativePath).sorted() == [
        "data/raw/UPPER.CSV",
        "data/raw/device.csv",
        "data/raw/labview.lvm",
        "data/raw/spec.txt"
    ])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter discoveryIncludesOnlySupportedMeasurementExtensions -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib`
Expected: FAIL (extra files like `run.log`, `run.py`, etc. are discovered).

- [ ] **Step 3: Implement `supportedRawExtensions` in `ProjectContext.swift`**

Add `static let supportedRawExtensions: Set<String> = ["csv", "txt", "lvm"]` and check in `walkRawSources`:
```swift
let ext = url.pathExtension.lowercased()
guard Self.supportedRawExtensions.contains(ext) else { continue }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter discoveryIncludesOnlySupportedMeasurementExtensions -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RawViewCore/ProjectContext.swift Tests/RawViewCoreTests/ProjectCatalogTests.swift
git commit -m "feat: filter discovered raw sources to supported extensions (csv, txt, lvm)"
```

---

### Task 2: Persist `profile_id` in `IndexDatabase`

**Files:**
- Modify: `Sources/RawViewCore/IndexDatabase.swift:1-160`
- Modify: `Sources/RawViewCore/IndexDatabase.swift:200-254`

**Interfaces:**
- Produces: `Record.profileID: String?` in `IndexDatabase.Record`
- Database schema: `profile_id TEXT` column in `sources` table
- `asInspection` returns `profileID: profileID ?? instrumentID ?? ""`

- [ ] **Step 1: Update schema and Record in `IndexDatabase.swift`**

Add `public let profileID: String?` to `IndexDatabase.Record`.
Add `profile_id TEXT` column to `CREATE TABLE IF NOT EXISTS sources (...)`.
Update `INSERT OR REPLACE` query to bind and read `profile_id`.
Update `asInspection` to use `profileID: profileID ?? instrumentID ?? ""`.

- [ ] **Step 2: Verify `swift build` passes**

Run: `swift build`
Expected: Build complete with 0 errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/RawViewCore/IndexDatabase.swift
git commit -m "feat: persist profile_id explicitly in IndexDatabase schema"
```

---

### Task 3: Offload Progress File Stats & Database Upsert from `@MainActor`

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift:440-475`

**Interfaces:**
- Consumes: `InstrumentReader.inspectMany`, `IndexDatabase.upsertBatch`
- Produces: Background worker thread processes file modification dates and batch index database writes, passing only clean UI state to `@MainActor.run`.

- [ ] **Step 1: Refactor `inspectSources` in `RawViewApp.swift`**

Change `onProgress` closure to compute `dbRecords` and call `try? indexDB?.upsertBatch(dbRecords)` before calling `MainActor.run`:
```swift
onProgress: { results, completed in
    var dbRecords: [IndexDatabase.Record] = []
    for result in results {
        if let inspection = result.inspection {
            let mtime: Int64 = (try? result.source.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int64($0) } ?? 0
            dbRecords.append(IndexDatabase.Record(source: result.source, inspection: inspection, mtime: mtime))
        }
    }
    if let indexDB, !dbRecords.isEmpty {
        try? indexDB.upsertBatch(dbRecords)
    }
    await MainActor.run {
        guard requestID == self.inspectionID else { return }
        for result in results {
            var state = self.sourceStates[result.id] ?? GallerySourceState()
            state.inspection = result.inspection
            state.error = result.error
            self.sourceStates[result.id] = state
        }
        self.inspectedSources = baseCompleted + completed
    }
}
```

- [ ] **Step 2: Verify `swift build` passes**

Run: `swift build`
Expected: Build complete with 0 errors.

- [ ] **Step 3: Re-package release app and installer DMG**

Run: `./Scripts/package_app.sh`
Expected: Package and DMG creation succeed with exit code 0.

- [ ] **Step 4: Commit**

```bash
git add Sources/RawViewApp/RawViewApp.swift
git commit -m "perf: offload progress stats and database batch upsert from MainActor"
```
