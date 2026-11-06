# Project Folder Structure Blueprint

This document defines the canonical directory structure, architectural layers, and module placement rules for the **RawView** repository.

---

## 1. Structural Overview

RawView is organized as a multi-target workspace centered on a pure, zero-mutation **Rust core** (`core/`) that powers native desktop and command-line frontends.

- **Core Engine (`core/`)**: Pure Rust library crate `raw-viewer-core`. Implements all business logic, path resolution, YAML configuration loading, filename grammar token extraction, instrument profile matching (v1–v4), measurement stream parsing, generic table sniffing, and project inspection.
- **Headless CLI (`apps/cli/`)**: Command-line executable `raw-viewer` delivering scriptable automation via structured `--json` envelopes and standard exit codes (0–5).
- **macOS Desktop (`apps/macos/`)**: Native Swift/SwiftUI application providing publication figure presets and SQLite WAL indexing.
- **Cross-Platform Desktop (`apps/tauri/`)**: Desktop application shell for Windows and Linux built with Tauri 2.
- **Bindings (`bindings/`)**: C-ABI and future UniFFI bridge headers connecting frontends directly to `raw-viewer-core`.
- **Shipped Assets (`assets/`)**: Default configuration templates and built-in instrument profiles (`usth/...`).
- **Agent Skills (`.agents/skills/`)**: Conversational tools for grammar deducing (`set-grammar`) and profile onboarding (`set-profile`).
- **Fixtures & Tests (`fixtures/`, `Scripts/`)**: Cross-language test fixtures, golden measurement outputs, and CI gating scripts.

---

## 2. Directory Visualization

```
raw-viewer/
├── Cargo.toml                              # Root Cargo workspace configuration
├── Cargo.lock                              # Locked dependency graph
├── Makefile                                # Local build and install automation
├── README.md                               # Primary project documentation
├── AGENTS.md                               # Architectural guide and invariant contracts for AI agents
├── CONTRACT.md                             # Architectural contracts and specifications
├── RELEASE_GATE.md                         # Release quality gates and verification protocols
├── .agents/
│   └── skills/                             # Shipped agent skills
│       ├── set-grammar/                    # Filename grammar onboarding workflow
│       │   └── SKILL.md
│       ├── set-profile/                    # Instrument profile configuration workflow
│       │   └── SKILL.md
│       └── verify-raw-viewer/              # Local integration verification tools
├── apps/
│   ├── cli/                                # Headless scriptable CLI crate (raw-viewer-cli)
│   │   ├── Cargo.toml
│   │   ├── src/
│   │   │   ├── main.rs                     # CLI entrypoint, argument parsing, exit code handling
│   │   │   ├── envelope.rs                 # JSON envelope formatter (ok/error)
│   │   │   └── commands/                   # Subcommand handlers (doctor, projects, config, grammar, profiles, files, skills)
│   │   └── tests/
│   │       └── cli_contract.rs             # CLI contract integration tests
│   ├── macos/                              # Native macOS SwiftUI application
│   │   ├── Package.swift
│   │   ├── Sources/                        # SwiftUI views, view models, and macOS integrations
│   │   ├── Tests/                          # Swift package unit and integration tests
│   │   ├── Scripts/                        # Core self-check and packaging scripts
│   │   └── Examples/                       # Sample datasets and fixtures
│   └── tauri/                              # Cross-platform desktop shell (Windows / Linux)
│       ├── src-tauri/                      # Rust backend interfacing with raw-viewer-core
│       └── ui/                             # Web-based frontend presentation
├── assets/
│   ├── default-config.yaml                 # Baseline configuration template
│   └── profiles/                           # Built-in instrument profiles
│       └── usth/                           # USTH laboratory instrument profile suite (Keithley, Autolab, Horiba, etc.)
├── bindings/                               # Rust bindings for foreign function interfaces
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs                          # C-ABI and FFI bridge exports
├── core/                                   # Core Rust domain crate (raw-viewer-core)
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                          # Root module exports
│   │   ├── config.rs                       # config.yaml (schema_version: 1) loader
│   │   ├── paths.rs                        # Platform-specific config and cache path resolver
│   │   ├── explorer/                       # Unified project exploration facade
│   │   ├── grammar/                        # Filename grammar pattern matcher and token extractor
│   │   ├── profile/                        # Schema v1–v4 profile parser, catalog, and when matcher
│   │   ├── measurement/                    # Measurement data contract, channels, and golden serialization
│   │   ├── reader/                         # Instrument stream parsers and generic delimited table sniffer
│   │   ├── project/                        # Project context and directory scanner
│   │   └── yaml/                           # Robust YAML parser and AST utilities
│   └── tests/                              # Core test suite (golden tests, write ban, contracts, fixtures)
├── docs/
│   ├── config-and-paths.md                 # Configuration path resolution specification
│   ├── handoff/                            # Historic architectural decisions and migration records
│   ├── release/                            # Release notes for layout and CLI restructuring
│   └── superpowers/                        # Feature specifications and implementation plans
├── fixtures/
│   ├── config/                             # Configuration test vectors and test cases
│   ├── grammar/                            # Shared cross-language grammar test contract and vectors
│   ├── legacy/                             # Legacy v1–v3 project setting fixtures for backward compatibility
│   └── workspaces/                         # Realistic laboratory datasets (e.g. usth-lab)
└── Scripts/
    ├── pre_push.sh                         # Unified local pre-push test runner
    ├── check_pr_owned_files.sh             # PR owned-files boundary validation script
    ├── check_pr_acceptance_mapping.sh      # PR acceptance criteria mapping verification script
    └── check_cross_language_test_contract.sh # Cross-language grammar parity check
```

---

## 3. Placement Rules & Guidelines

1. **Pure Domain Logic**: All data parsing, path calculations, grammar extraction, and profile validation belong exclusively in `core/`.
2. **Zero Project-Tree Writes**: The core never writes inside a user's project directory. Indexes and caches must be placed under platform cache directories (`core/src/paths.rs`).
3. **Frontend Separation**: Frontends (`apps/macos`, `apps/tauri`, `apps/cli`) are consumers of `core/` and contain only presentation, argument parsing, or native platform windowing.
4. **Regular Files for Profiles**: Profile definitions in `.raw-viewer/profiles/<id>.yaml` must be regular files. Symlinks are rejected.
5. **JSON Contract**: All scriptable CLI features must output predictable JSON conforming to `apps/cli/src/envelope.rs`.
