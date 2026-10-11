# Deep-Nested Tree Selection & Impeccable Visual Profile Editor Studio Specification

## 1. Problem Statement & Motivation

1. **Tree Selection Bug on Arbitrary Subnested Directories**:
   - In `ProjectGalleryViews.swift`, the recursive `treeNodeRow` implementation wrapped child folders and files inside a single parent directory's `VStack`.
   - In SwiftUI, embedding items inside an enclosing `VStack` within a `List(selection: ...)` collapses them into a **single row item**. As a result, clicking individual measurement files in the tree failed to trigger `.tag(source.id)` or update `focusedSourceID`.
   - Modern research projects organize data across multiple nested subfolders (e.g. `data/raw/batch_2026_10/sample_A/device_01/run_03/iv_curve.csv`). Tree expansion must scale to arbitrary nesting depths without UI lag or selection failure.

2. **Profile Editor UX Deficiencies**:
   - **Lack of In-Project Workflow**: Rather than opening random files via Finder dialogs, researchers want a direct, seamless 1-click bridge from the Explorer workspace: when browsing any measurement file, click **"✨ Build Profile from This File"** to immediately jump into the Editor with that file loaded as the active sample.
   - **Need for Real Scientific Workstation Feel**:
     - Scientific instruments produce ASCII files with specific patterns:
       * **Metadata Block**: Lines formatted as `<key>: <value>` or `<key> = <value>` or starting with comments (`#`, `//`).
       * **Header Row**: The line immediately preceding the data matrix, containing textual column labels and physical units.
       * **Data Matrix**: Continuous rows of numerical values (floating point, scientific notation `1.05E-06`).
       * **Separators vs. Decimals**: Column separator is typically Tab (`\t`), Semicolon (`;`), Whitespace, or Comma (`,`), while decimal delimiter is Dot (`.`) or European Comma (`,`).
     - Configuring a profile requires interactive **column role assignment** (X axis, Y axis, Aux, and Units) rather than just line highlighting.
     - **Live Quick-Plot Sandbox**: Instant visualization of the extracted X/Y curves directly inside the editor so users immediately verify the profile before saving.

---

## 2. Architecture & Design

### A. Flattened Tree Engine for Arbitrary Nested Directories
Instead of recursive view rendering inside a single List row, we introduce an iterative/flattened tree model:
```swift
public struct FlattenedTreeItem: Identifiable, Sendable {
    public let id: String
    public let node: SourceTreeNode
    public let depth: Int
    public var isDirectory: Bool { node.sourceID == nil }
}
```
- A flattening algorithm walks `sourceTree.root.children` and recursively flattens only currently expanded folders (`expandedDirectoryIDs.contains(node.id)`).
- Each folder and each file renders as a **direct top-level row** in `List(selection: $selectedSourceIDs)`.
- Files carry direct `.tag(source.id)` and `.onTapGesture { focusedSourceID = source.id; selectedSourceIDs = [source.id] }`.
- Folder clicks toggle `expandedDirectoryIDs` independently without altering file selection.
- Subfolder indentation scales smoothly (`CGFloat(depth * 14)`).

### B. Explorer-to-Editor Direct Bridge
- In `ExplorerWorkspace`:
  - When any source is selected/focused, the sidebar row context menu, inspector pane, and gallery toolbar expose:
    `Button("Build Profile from This File", systemImage: "sparkles.rectangle.stack")`
  - Clicking this switches `activeWorkspaceMode = .editor` and loads the focused source URL directly into the editor state machine.
- No external `NSOpenPanel` file dialogs needed: keeps the workflow 100% focused on active project assets.

### C. Smart Auto-Detection Heuristic Engine
The detector inspects the first 100 lines of the sample file:
1. **Column Separator & Decimal Delimiter Sniffing**:
   - Tests candidates: Tab (`\t`), Semicolon (`;`), Comma (`,`), and multi-space.
   - Detects decimal format: Dot (`.`) vs. Comma (`,`).
2. **Metadata Recognition**:
   - Lines with `<key>: <value>` or `<key> = <value>` or comments (`#`) before the header are classified as Metadata.
3. **Data Matrix Boundary**:
   - Finds the first line where >= 80% of tokens parse as numbers (supporting scientific notation `1.23e-4`).
4. **Header Line & Channel Heuristics**:
   - The line immediately preceding the data matrix is marked as `columnHeaderLine`.
   - Inspects column header labels:
     * Contains "V", "Volt", "Wavenumber", "Time", "s" -> assigned as **X Axis (Sweep)**.
     * Contains "I", "Current", "Amp", "Intensity", "Counts", "Abs" -> assigned as **Y Axis (Signal)**.
     * Extracts physical units from parentheses (e.g. `(V)` -> unit "V", `[mA]` -> unit "mA").

### D. Impeccable Visual Profile Editor Studio
The editor center view is designed as a **Scientific Parser Studio**:
1. **Top Command Bar**:
   - Displays sample file path, row count, detected separator (`Tab`, `;`, `,`), and decimal format (`.`).
   - Prominent **"✨ Run Smart Heuristics"** button for 1-click configuration.
   - Primary **"💾 Save Profile to .rawviewer/instrument"** button.
2. **Interactive Sheet (Dual-View)**:
   - **Structural Boxes View (Default)**:
     * **Metadata Card**: Displays discovered key-value properties.
     * **Header Card**: Shows active header line and column tokens.
     * **Data Matrix Grid (Spreadsheet-Style)**: Displays the first 50 rows in a formatted grid. Each column header features:
       - Role badge: `[X Axis]` (Blue), `[Y Axis]` (Emerald), `[Aux]` (Gray).
       - Quick popover to assign Role, Name, and Unit chips (`V`, `mV`, `A`, `mA`, `µA`, `nA`, `cm⁻¹`, `nm`, `s`, `°C`).
   - **Raw Stream View**: Verbatim line-by-line inspection with line numbers.
3. **Live Quick-Plot Sandbox Preview**:
   - Embedded live chart at the bottom right rendering the extracted X/Y data curves in real-time.
   - Immediate visual feedback confirms the parser settings produce clean physical spectra/sweeps.

---

## 3. Invariants & Verification Gates

1. **Depth Invariant**: Tree navigation handles arbitrary nesting (depth >= 10) smoothly.
2. **Immediate Selection Invariant**: Single click on any file in tree mode immediately selects it, focuses it, and loads its plot.
3. **Zero Mutation Invariant**: Raw measurement files remain strictly read-only.
4. **Verification Gate**: `./Scripts/check_core.sh` and `./Scripts/check_index_cli.sh` must pass with 0 errors.
