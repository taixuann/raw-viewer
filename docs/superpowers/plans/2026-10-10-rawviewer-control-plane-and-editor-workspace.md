# RawViewer Control Plane and Interactive 3-Panel Visual Profile & View Editor Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the unified `.rawviewer/` project control plane (`setting.yaml`, `index.db`, `instrument/`, `preset/`, `view/`) and a dedicated 3-panel Visual Profile & View Editor Workspace in SwiftUI.

**Architecture:** Consolidate all project-level metadata under `<project>/.rawviewer/` with project-local index caching and hierarchical profile discovery. Introduce a dedicated 3-panel Editor Workspace (Left: representative file + filename token segmenter; Center: line-by-line interactive raw canvas with region tagging; Right: static vs. dynamic semantic inspector, cohort validator, and declarative YAML compiler).

**Tech Stack:** Swift 6 tools / Swift 5 language mode, macOS 14+, SwiftUI, SQLite3 (in-process WAL), Foundation, fail-closed YAML.

**Spec:** `docs/superpowers/specs/2026-10-10-rawviewer-control-plane-and-editor-workspace-design.md`

## Global Constraints

- No external dependencies beyond Apple platforms and standard Swift libraries.
- No project-local source file mutation: raw files and existing laboratory data remain strictly read-only and immutable.
- Writable index is located at `<project>/.rawviewer/index.db` protected by flock lease `.rawviewer/index-writer.lock`.
- Settings file is located at `<project>/.rawviewer/setting.yaml` (schema v2, default view `tree`, default preset `nature-single`).
- Dynamic category parsing rules reside at `<project>/.rawviewer/view/category.yaml`.
- Backward-compatible profile discovery: `.rawviewer/instrument/` overrides `data/.rawview/instrument/` and `data/instruments/` (ignoring empty directories).

## Review Focus

1. `res_volatile-polydopamine` immediately discovers all 5 instrument profiles without manual copy.
2. Relocation of index to `.rawviewer/index.db` preserves legacy database as read-only rollback.
3. Filename token segmentation parses arbitrary delimiters (`_`, `[`, `]`, `-`) into stable categories.
4. Center raw canvas drag-selection handles files with diverse line endings (CRLF, LF) and multibyte encodings.
5. Saving in Editor Mode generates strictly valid schema v1/v2 YAML profiles compatible with existing readers.

---

### Task 1: Project-local Index Relocation and Setting Schema v2

**Files:**
- Modify: `Sources/RawViewCore/ProjectIndexStore.swift`
- Modify: `Sources/RawViewCore/ProjectContext.swift`
- Modify: `Sources/RawViewCore/ProjectSettings.swift`
- Modify: `Tests/RawViewCoreTests/ProjectIndexStoreTests.swift`
- Modify: `Tests/RawViewCoreTests/ProjectSettingsTests.swift`

**Interfaces:**
- `ProjectIndexStore.destinationRelativePath`: changed to `".rawviewer/index.db"`
- `ProjectSettingsStore.relativePath`: changed to `".rawviewer/setting.yaml"`
- `ProjectSettings`: schema v2 adds `defaultPreset: String` (defaults to `"nature-single"`)

- [x] **Step 1: Write failing tests for .rawviewer/index.db and .rawviewer/setting.yaml**
  - Test `testIndexDatabaseResolvesInRawviewerRoot`: asserts `ProjectIndexStore.preferredDestinationURL(project:)` points to `<project>/.rawviewer/index.db`.
  - Test `testSettingsSchemaV2ParsesRootFile`: asserts `ProjectSettingsStore.load` reads `.rawviewer/setting.yaml` with schema v2 and `default_preset`.

- [x] **Step 2: Run tests to verify failure**
  - Run: `swift test --filter ProjectSettingsTests`
  - Expected: FAIL with mismatched path or missing fields.

- [x] **Step 3: Update ProjectIndexStore and ProjectSettings**
  - Update `destinationRelativePath` in `ProjectIndexStore.swift` to `".rawviewer/index.db"`.
  - Update `relativePath` in `ProjectSettings.swift` to `".rawviewer/setting.yaml"`.
  - Add schema v2 parsing with `defaultPreset` field (defaulting to `"nature-single"`).

- [x] **Step 4: Run tests to verify pass**
  - Run: `swift test --filter ProjectSettingsTests` and `swift test --filter ProjectIndexStoreTests`
  - Expected: PASS.

---

### Task 2: Multi-Source Hierarchical Instrument Profile Catalog

**Files:**
- Modify: `Sources/RawViewCore/InstrumentProfile.swift`
- Modify: `Tests/RawViewCoreTests/InstrumentReaderTests.swift`

**Interfaces:**
- `ProfileCatalog.load(project: ProjectContext) -> ProfileCatalog`:
  - Priority 1: `<project>/.rawviewer/instrument/`
  - Priority 2: `<project>/data/.rawview/instrument/`
  - Priority 3: `<project>/data/instruments/` (checks that directory is not empty before making it authoritative)

- [x] **Step 1: Write failing test for multi-source profile fallback**
  - Test `testProfileCatalogDiscoversFromRawviewerOrLegacyOrInstruments`: creates synthetic project with profiles in `data/.rawview/instrument` and an empty `data/instruments/rawview/`, asserts catalog successfully discovers profiles.

- [x] **Step 2: Run test to verify failure**
  - Run: `swift test --filter InstrumentReaderTests`
  - Expected: FAIL (empty rawview folder blocks discovery).

- [x] **Step 3: Update ProfileCatalog.load**
  - Check `.rawviewer/instrument` first if present and non-empty.
  - Fall back to `data/.rawview/instrument` if present and non-empty.
  - Check `data/instruments` only if companion `rawview/` is non-empty or absent.

- [x] **Step 4: Run test to verify pass**
  - Run: `swift test --filter InstrumentReaderTests`
  - Expected: PASS.

---

### Task 3: Custom Presets Catalog (.rawviewer/preset/)

**Files:**
- Create: `Sources/RawViewCore/PresetCatalog.swift`
- Modify: `Sources/RawViewApp/RawViewModel.swift`
- Create: `Tests/RawViewCoreTests/PresetCatalogTests.swift`

**Interfaces:**
- `PresetCatalog.load(project: ProjectContext) -> [ScientificPreset]`
- Scans `<project>/.rawviewer/preset/*.yaml` and loads custom figrecipe presets.
- Merges with default `nature-single`.

- [x] **Step 1: Write failing test for PresetCatalog**
  - Test `testPresetCatalogLoadsCustomAndDefaults`: adds custom YAML in `.rawviewer/preset/`, verifies catalog returns it alongside built-in presets.

- [x] **Step 2: Run test to verify failure**
  - Run: `swift test --filter PresetCatalogTests`
  - Expected: FAIL (type not defined).

- [x] **Step 3: Implement PresetCatalog**
  - Implement YAML preset loading from `<project>/.rawviewer/preset/`.
  - Fail-closed on corrupted YAML; ignores non-yaml files.

- [x] **Step 4: Run test to verify pass**
  - Run: `swift test --filter PresetCatalogTests`
  - Expected: PASS.

---

### Task 4: Dynamic Category & Filename Token Pattern Engine

**Files:**
- Create: `Sources/RawViewCore/CategoryRuleEngine.swift`
- Modify: `Sources/RawViewCore/InstrumentReader.swift`
- Create: `Tests/RawViewCoreTests/CategoryRuleEngineTests.swift`

**Interfaces:**
- `CategoryRule`: Codable struct for `delimiters`, `tokens`, `categories`.
- `CategoryRuleEngine.extract(from filename: String, rules: CategoryRule?) -> ExtractedFacts`

- [x] **Step 1: Write failing test for CategoryRuleEngine**
  - Test `testTokenSegmentationExtractsCategoryAndDevice`: provides `SampleA_IV_101026.csv` with delimiters `["_"]` and rules mapping index 1 to Category "IV", verifies extracted category is "I-V Sweep".

- [x] **Step 2: Run test to verify failure**
  - Run: `swift test --filter CategoryRuleEngineTests`
  - Expected: FAIL.

- [x] **Step 3: Implement CategoryRuleEngine**
  - Implement delimiter splitting, index token mapping, category display name resolution, and YAML loading from `<project>/.rawviewer/view/category.yaml`.

- [x] **Step 4: Run test to verify pass**
  - Run: `swift test --filter CategoryRuleEngineTests`
  - Expected: PASS.

---

### Task 5: Editor Workspace Model & Interactive Region Tagger

**Files:**
- Create: `Sources/RawViewCore/EditorWorkspaceModel.swift`
- Create: `Tests/RawViewCoreTests/EditorWorkspaceModelTests.swift`

**Interfaces:**
- `EditorWorkspaceModel`: state machine managing sample file loading, line range tagging (Header, Names, Data, KeyValues), static vs. dynamic field definitions.
- `compileProfile() throws -> String`: generates validated YAML profile string.

- [x] **Step 1: Write failing test for EditorWorkspaceModel**
  - Test `testEditorModelCompilesValidInstrumentYAML`: tags line 0 as header, line 1 as column names, lines 2..10 as data, defines X and Y channels, verifies output YAML string parses into a valid `InstrumentProfile`.

- [x] **Step 2: Run test to verify failure**
  - Run: `swift test --filter EditorWorkspaceModelTests`
  - Expected: FAIL.

- [x] **Step 3: Implement EditorWorkspaceModel**
  - Implement line tagger, column delimiter detector, static/dynamic property binding, and YAML serializer conforming to `schema_version: 1` / `2`.

- [x] **Step 4: Run test to verify pass**
  - Run: `swift test --filter EditorWorkspaceModelTests`
  - Expected: PASS.

---

### Task 6: 3-Panel Visual Profile & View Editor SwiftUI Workspace

**Files:**
- Create: `Sources/RawViewApp/EditorWorkspaceView.swift`
- Create: `Sources/RawViewApp/EditorCanvasViews.swift`
- Modify: `Sources/RawViewApp/RawViewApp.swift`

**Interfaces:**
- `EditorWorkspaceView: View`
  - Left column: Sample file switcher + Filename token interactive pills.
  - Center column: Line-numbered interactive raw text canvas with drag-selection and colored region highlights.
  - Right column: Static vs. Dynamic properties inspector + Cohort match badge tester + Save Profile button.

- [x] **Step 1: Implement Left Panel (File Switcher & Token Pills)**
  - Clickable filename token pills allowing quick assignment of roles (Category, Device, Date).
  - Live token preview: preview parsed fields on 5 sibling files in real-time.

- [x] **Step 2: Implement Center Panel (Interactive Canvas with Impeccable Virtualization)**
  - Bounded 500-line virtualized canvas: fast 120 FPS rendering even for 100 MB / 70,000+ line scientific files.
  - Line-by-line number gutter with Shift-click line range selection (click start line + Shift-click end line to tag whole block).
  - Region color badges: Purple (Key-Value Metadata), Blue (Column Names), Emerald (Data Matrix).

- [x] **Step 3: Implement Right Panel (Semantic Inspector & Exporter)**
  - Toggle between Static and Dynamic values.
  - Column mapping table (Name, Quantity, Unit, X/Y axes).
  - "Test against cohort" button showing compatibility indicators (Green/Amber/Red).
  - "Save to .rawviewer" button saving profile and category rules.

- [x] **Step 4: App-level Typecheck**
  - Run: `./Scripts/check_core.sh`
  - Expected: PASS with zero SwiftUI type inference or syntax errors.

---

### Task 7: Top-level Workspace Switcher and Project Integration

**Files:**
- Modify: `Sources/RawViewApp/RawViewApp.swift`
- Modify: `Sources/RawViewApp/ProjectGalleryViews.swift`

**Interfaces:**
- Toolbar mode picker: `Explorer` vs. `Profile & View Editor`.
- Preserves active selection and window layout when toggling between modes.

- [x] **Step 1: Add Workspace Switcher to Toolbar**
  - Segmented control in navigation bar switching between Explorer and Editor.

- [x] **Step 2: Integrate with Active Project State**
  - Automatically loads currently selected file into Editor Workspace upon switching.

- [x] **Step 3: Verify Core & App Layer**
  - Run: `./Scripts/check_core.sh`
  - Expected: PASS.

---

### Task 8: Full Verification, Packaging and Real Project Acceptance

**Files:**
- Modify: `CONTRACT.md`
- Modify: `README.md`
- Run: `Scripts/check_core.sh`
- Run: `Scripts/check_index_cli.sh`
- Run: `Scripts/package_app.sh`

- [x] **Step 1: Run complete check_core.sh and check_index_cli.sh**
  - Verify all unit, integration, and self-checks pass cleanly (exit 0).

- [x] **Step 2: Package Release Application Bundle**
  - Execute `RAWVIEW_APP_PATH="$(pwd)/.build/RawView.app" ./Scripts/package_app.sh`.
  - Verify code signing passes.

- [x] **Step 3: Verify with real res_volatile-polydopamine project**
  - Launch app against `/Users/tai/research-projects/active-projects/res_volatile-polydopamine`.
  - Verify all 5 profiles appear, tree mode functions, and Editor Workspace opens.
