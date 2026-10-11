# RawViewer Control Plane and Interactive 3-Panel Visual Profile & View Editor Workspace Design

**Date:** 2026-10-10  
**Status:** Approved in Brainstorming  
**Issue Reference:** Linear TAI-80 (Idea 3 — Define, validate and remember reader profiles)

---

## 1. Executive Summary & Intent

RawView is evolving into a self-contained, filesystem-first scientific measurement workspace. To eliminate fragmentation and manual YAML editing:
1. **Unified Project Control Plane (`.rawviewer/`)**:
   - `setting.yaml`: Root declarative defaults (`data_root`, `default_view: "tree"`, `default_preset: "nature-single"`).
   - `index.db`: High-performance SQLite index database (+ WAL/SHM) stored directly within `<project>/.rawviewer/index.db`.
   - `instrument/`: Declarative YAML instrument profiles (`*.yaml`).
   - `preset/`: Custom scientific publication figure presets (`*.yaml`).
   - `view/`: Dynamic categorization and facet rules (`category.yaml`).
2. **Interactive 3-Panel Editor Workspace**:
   - A dedicated visual environment where researchers define instrument layouts, column mappings, and filename tokens by clicking directly on raw file lines without hand-writing YAML.
   - Categorizes properties as **Static** (constant per instrument) or **Dynamic** (extracted per file from header lines or filename tokens).
   - Tests definitions live against other project files and compiles them into production-ready YAML profiles in `.rawviewer/instrument/` and rules in `.rawviewer/view/`.

---

## 2. Architecture & Directory Structure

```text
<project>/
├── data/                         # Pure scientific measurements (read-only)
│   └── raw/
└── .rawviewer/                   # RawView Control Plane
    ├── setting.yaml              # Declarative configuration defaults
    ├── index.db                  # Local SQLite WAL database (+ index.db-wal, index.db-shm)
    ├── instrument/               # Custom and project instrument profiles (*.yaml)
    ├── preset/                   # Custom publication figure presets (*.yaml)
    └── view/                     # View rules and token extraction specs
        └── category.yaml         # Filename token segmentation and category mapping
```

---

## 3. Detailed Component Specifications

### 3.1 Declarative Settings (`.rawviewer/setting.yaml`)
Schema v2 format:
```yaml
schema_version: 2
data_root: "data/raw"
default_view: "tree"
default_preset: "nature-single"
```
- **Immutability rule**: Does not continuously overwrite on UI session events (e.g. expanding a folder). Only persists explicit configuration changes (via Settings UI or `--save-settings`).

### 3.2 High-Performance Project Index (`<project>/.rawviewer/index.db`)
- Stored project-locally under `<project>/.rawviewer/index.db`.
- Protected by advisory flock lease (`.rawviewer/index-writer.lock`).
- Grants full project portability: copying or moving the project folder preserves the entire index cache without requiring re-indexing.

### 3.3 Dynamic Profile & Fallback Resolution
When discovering instrument profiles, RawView applies an authoritative fallback order:
1. **Primary**: `<project>/.rawviewer/instrument/*.yaml`
2. **Fallback**: `<project>/data/.rawview/instrument/*.yaml` and `<project>/data/instruments/*.yaml` (skipping empty directories like `data/instruments/rawview/`).
- Resolves all existing profiles in active projects (such as `res_volatile-polydopamine`) immediately without manual file moves.

### 3.4 Custom Presets (`.rawviewer/preset/`)
- Default preset is always **Nature Single** (`nature-single`).
- Scans `<project>/.rawviewer/preset/*.yaml` for project-specific figure presets (e.g. customized multi-panel aspect ratios or typography overrides).
- If `preset/` contains files, they appear as selectable custom options in the top toolbar preset picker.

### 3.5 Dynamic Category & Filename Token Engine (`.rawviewer/view/category.yaml`)
Schema for token segmentation:
```yaml
schema_version: 1
delimiters: ["_", "[", "]", "-"]
tokens:
  - index: 0
    name: "sample_id"
    role: "device"
  - index: 1
    name: "measurement_type"
    role: "category"
  - index: 2
    name: "date"
    role: "timestamp"
    format: "DDMMYY"
categories:
  - token_value: "IV"
    display_name: "I-V Sweep"
  - token_value: "Pulse"
    display_name: "Pulsed Endurance"
```
The indexing and discovery engine consumes this specification to automatically extract categories and facets without hard-coded string manipulation.

---

## 4. Impeccable 3-Panel Editor Workspace UX

### 4.1 Mode Transition
A top-level toolbar toggle provides instant switching between:
- **Viewer Mode**: Standard 3-column scientific explorer (Tree Sidebar, Data/Plot Center, Inspector Right).
- **Editor Workspace Mode**: Dedicated full-canvas instrument and view builder.

### 4.2 Workspace Layout (3 Panels)

#### Left Panel: Representative Source & Structural Outlines
- **File Switcher**: Dropdown/search to select any project file as the representative template.
- **Filename Tokenizer**: Renders the filename as interactive pills:
  `[Sample01]` `_` `[IV]` `_` `[101026]` `.csv`
  Clicking a pill allows tagging its semantic role (`Category`, `Device ID`, `Timestamp`, `Ignored`).
- **Detected Block Outline**: Summary of identified blocks (Header, Metadata, Columns, Data Matrix).

#### Center Panel: Interactive Raw Data Canvas
- Line-numbered monospace display of the representative file.
- **Interactive Region Selection**:
  - Drag or click lines to designate:
    - **Header Block**: Comments and equipment preambles.
    - **Column Names Line**: Headers for quantities and units.
    - **Data Rows**: First data row and boundary.
    - **Key-Value Metadata**: Lines containing `Key: Value` pairs.
  - Smart heuristics visually highlight candidate regions with subtle color coding (e.g. Purple for Metadata, Blue for Header, Emerald for Data).

#### Right Panel: Semantic Schema & Inspector
- **Static vs. Dynamic Property Inspector**:
  - **Static**: Constant across all files matching this instrument (e.g., `delimiter: ","`, `x_channel: "voltage"`).
  - **Dynamic**: Changes per file (e.g., `timestamp` extracted from line 3, `category` extracted from filename token index 1).
- **Channel & Unit Configuration**:
  - Table of detected columns: edit Header, Quantity (`voltage`, `current`), Unit (`V`, `A`), and assign X/Y axes.
- **Validation & Test Cohort**:
  - Tests the draft profile against 10-20 other files in the project.
  - Displays match status: Green (100% compatible), Amber (Ambiguous dialect), Red (Incompatible).
- **Export & Commit**:
  - "Save Instrument Profile" compiles the visual setup into `<project>/.rawviewer/instrument/<id>.yaml`.
  - Automatically writes `<project>/.rawviewer/view/category.yaml` if filename tokens were defined.

---

## 5. Verification & Acceptance Criteria
- Unit tests verify `.rawviewer/` folder layout and schema v2 loading.
- Regression tests prove `res_volatile-polydopamine` immediately detects all 5 instrument profiles.
- Pure parsing tests for `view/category.yaml` token extraction and category mapping.
- SwiftUI type-checks and packaging tests verify the 3-panel Editor Workspace without performance degradation.
