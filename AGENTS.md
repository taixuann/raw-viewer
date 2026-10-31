# RawView Developer and Agent Guide

This file defines the architecture, invariant contracts, and component graph for AI agents working on RawView.

## Register and Rules

Write instructions in Plain register: short imperative sentences, active voice, one instruction per sentence.
Never delete or split existing source files without explicit human authorization.
Raw scientific data files under project data roots are strictly read-only and immutable.

## Knowledge Graph and Component Map (Graphify)

The Swift package lives in `apps/macos/`. Paths in the map below are relative to that package.

RawView is organized into five decoupled core layers and a single Explorer workspace in the macOS app.

```mermaid
graph TD
    subgraph Storage ["Storage (Sources/RawViewCore/Storage)"]
        ProjectIndexStore["ProjectIndexStore: manages .rawviewer/index.db & flock lease"]
        IndexDatabase["IndexDatabase: SQLite3 WAL database connection & migrations"]
        MeasurementCache["MeasurementCache: private app-local measurement binary cache"]
        ProjectSettings["ProjectSettings: loads/saves .rawviewer/setting.yaml"]
    end

    subgraph Discovery ["Discovery (Sources/RawViewCore/Discovery)"]
        ProjectContext["ProjectContext: resolves canonical root and relative data_root"]
        SourceTree["SourceTree: hierarchical directory tree preserving ancestors"]
        CategoryRuleEngine["CategoryRuleEngine: tokenizes filenames from view/category.yaml"]
    end

    subgraph Reader ["Reader (Sources/RawViewCore/Reader)"]
        ProfileCatalog["ProfileCatalog: resolves YAML profiles from .rawviewer/instrument/"]
        InstrumentReader["InstrumentReader: parallel worker pool for stream extraction"]
        ProgressionPlotReader["ProgressionPlotReader: progression plot segments (#18 wiring pending)"]
        GenericTableReader["GenericTableReader: bounded 64 KiB delimiter/header sniffer"]
        SourceInspection["SourceInspection: typed inspection results & dispositions"]
    end

    subgraph PlotStyle ["Plot presets (Sources/RawViewCore/Editor)"]
        PresetCatalog["PresetCatalog & ScientificPreset: publication figure presets"]
        AxisFormatter["AxisFormatter: tick/label scaling for Explorer plots"]
    end

    subgraph AppUI ["Application Shell (Sources/RawViewApp)"]
        RawViewApp["RawViewApp: application lifecycle & global state"]
        ExplorerWorkspace["Explorer: 3-column scientific viewer (Tree/Plot/Table)"]
    end

    ProjectContext --> ProjectSettings
    ProjectContext --> ProjectIndexStore
    SourceTree --> ProjectContext
    CategoryRuleEngine --> ProjectContext
    ProfileCatalog --> ProjectContext
    InstrumentReader --> ProfileCatalog
    ExplorerWorkspace --> ProjectContext
    ExplorerWorkspace --> InstrumentReader
    ExplorerWorkspace --> PresetCatalog
```

## Invariants and Contracts

1. **Storage Invariant**: Writable index is located at `<project>/.rawviewer/index.db`. Zero project-local SQLite writes occur outside `.rawviewer/`. Legacy `data/.rawview/index.db` is read-only hints.
2. **Settings Invariant**: Project configuration is declarative and resides at `<project>/.rawviewer/setting.yaml`. Default view is `tree`. Default preset is `nature-single`.
3. **Profile Fallback**: Profiles are loaded from `<project>/.rawviewer/instrument/`. If missing, fallback to `data/.rawview/instrument/` and `data/instruments/` (ignoring empty directories). The app must not write new YAML under `.rawviewer/instrument/` (read-only consumption until a dedicated profile pipeline lands).
4. **Verification**: Always run `./apps/macos/Scripts/check_core.sh` and `./apps/macos/Scripts/check_index_cli.sh` before declaring completion. Rust workspace checks are `cargo fmt --check`, `cargo clippy --workspace -- -D warnings`, and `cargo test --workspace` from the repository root.
