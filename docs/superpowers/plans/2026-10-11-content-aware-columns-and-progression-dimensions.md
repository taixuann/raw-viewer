# Content-Aware Column Sizing & Progression Dimensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement content-aware adaptive column sizing with `.3f` numeric truncation bounds, introduce independent Progression Dimensions (`Index`, `Time`, `Custom`) into the column data model, and refine toolbar typography and selection button ergonomics in the Profile Studio.

**Architecture:** Extend `ColumnDefinition` and column configuration in `EditorWorkspaceModel` with an explicit `ColumnRole` enum (`channel`, `x`, `y`, `progression`, `skip`) and a `ProgressionType` enum (`index`, `time`, `custom`). In `EditorCanvasViews`, compute content-aware column widths clamped between 110pt and 240pt using header token length and truncated `.3f` numeric sample values. Remove redundant "Set Data" toolbar button and enlarge "Set X" / "Set Y" action buttons to `.controlSize(.small)` with prominent typography.

**Tech Stack:** Swift, SwiftUI, AppKit, RawViewCore, RawViewApp.

**Spec:** In-conversation architectural design approved on 2026-10-11.

## Global Constraints

- Never mutate raw line tokens or raw measurement data on disk (Raw Data Immutability).
- Progression dimensions must not be mutually exclusive with regular auxiliary channels, but remain independent of primary X/Y axis assignment.
- Numeric estimation for width calculation must round or format floats to at most 3 decimal places (`.3f`) without crashing on non-numeric or exponential strings.
- Keep `@MainActor` 60fps responsive; do not compute column widths inside heavy line-by-line render loops.

## Review Focus

- Long scientific exponential numbers (e.g., `6.182861328125E-08`) must format compactly for width estimation without corrupting raw matrix display values.
- Columns with very short single-digit tokens (e.g. `1`, `2` in `Scan` or `Index`) must shrink cleanly down to ~110-120pt without visual clipping.
- Assigning a column as Progression (`Time` or `Index`) must not auto-unset active X or Y axes, but update the column role and UI badge distinctly.
- Deselecting or switching a column role back to standard channel must cleanly clear its progression metadata.
- Toolbar layout across cards must remain vertically balanced without overflowing standard macOS window sizes.

---

### Task 1: Extend Data Model with Progression Dimensions and ColumnRole

**Files:**
- Modify: `Sources/RawViewCore/Editor/EditorWorkspaceModel.swift`
- Test: `Tests/RawViewCoreTests/InstrumentReaderTests.swift` or dedicated editor test

**Interfaces:**
- Produces:
  ```swift
  public enum ColumnRole: String, Sendable, Codable, CaseIterable {
      case channel = "channel"
      case x = "x"
      case y = "y"
      case progression = "progression"
      case skip = "skip"
  }

  public enum ProgressionType: String, Sendable, Codable, CaseIterable {
      case index = "index"
      case time = "time"
      case custom = "custom"
  }
  ```
  And properties on `ColumnDefinition`:
  ```swift
  public var role: ColumnRole
  public var progressionType: ProgressionType?
  public var customProgressionName: String?
  ```

- [ ] **Step 1: Write unit tests verifying ColumnRole and ProgressionType serialization and role helpers**
- [ ] **Step 2: Run test to verify it fails before implementation**
- [ ] **Step 3: Implement `ColumnRole`, `ProgressionType`, and update `ColumnDefinition` in `EditorWorkspaceModel.swift`**
- [ ] **Step 4: Run test to verify it passes**
- [ ] **Step 5: Commit changes**

---

### Task 2: Implement Content-Aware Column Width Calculation in Raw Stream View

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`

**Interfaces:**
- Produces:
  ```swift
  func contentAwareColumnWidth(colIdx: Int, headerToken: String, sampleRows: [String]) -> CGFloat
  ```
  - Inspects header token length, title text length, and up to 10 sample values.
  - Numbers formatted to at most 3 decimals (`.3f`) for estimation.
  - Clamped between minimum `110pt` and maximum `240pt`.

- [ ] **Step 1: Add helper `contentAwareColumnWidth` with `.3f` estimation and clamping**
- [ ] **Step 2: Update `streamRow` and `streamHeaderCell` to consume `columnWidth(colIdx)` instead of fixed minWidth**
- [ ] **Step 3: Verify with single-digit columns (Scan, Index) shrinking and scientific columns expanding**
- [ ] **Step 4: Commit changes**

---

### Task 3: Refactor Toolbar Controls & Selection Action Ergonomics

**Files:**
- Modify: `Sources/RawViewApp/Editor/EditorCanvasViews.swift`

**Changes:**
- Remove redundant `Set Data` button from Card 4 selection action bar.
- Enlarge `Set X` and `Set Y` buttons to `.controlSize(.small)` with font `11pt, weight: .semibold` and colored visual accents (Accent Blue for X, Emerald/Green for Y).
- Add `Set Progression` menu button with options: `⏱ Time`, `🔢 Index / Cycle`, `⚙️ Custom...`.
- Rebalance Card 2 (Metadata) & Card 3/4 padding and height to match Card 1 & 2.

- [ ] **Step 1: Remove `Set Data` button and upgrade `Set X` / `Set Y` styling**
- [ ] **Step 2: Add `Set Progression` action and menu items**
- [ ] **Step 3: Harmonize card vertical rhythm and font sizes**
- [ ] **Step 4: Verify visually and run app build check**
- [ ] **Step 5: Commit changes**

---

### Task 4: Full Test Suite, Check Core & App Verification

**Files:**
- Execute verification suite across worktree.

- [ ] **Step 1: Run `swift test` (all 228+ tests passing)**
- [ ] **Step 2: Run `./Scripts/check_core.sh` (zero type-check errors)**
- [ ] **Step 3: Package app `./Scripts/package_app.sh` and restart `/Applications/RawView.app`**
- [ ] **Step 4: Inspect live UI in Raw Stream Studio**
