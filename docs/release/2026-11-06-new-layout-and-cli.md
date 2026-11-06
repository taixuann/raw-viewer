# Release Note: Unified Multi-Platform Layout & Scriptable CLI

**Date**: 2026-11-06  
**Status**: Completed (#12, #18, #19, #20, #21, #22, #24, #25)

## Overview

RawView has restructured from a macOS-only prototype into a multi-platform scientific visualization and data inspection system built on a high-performance **Rust core** (`raw-viewer-core`), with:
1. **macOS Native App** (`apps/macos`): Resizable 3-column SwiftUI interface with FigRecipe publication presets and SQLite WAL indexing.
2. **Cross-Platform Desktop App** (`apps/tauri`): Tauri 2 shell targeting Windows and Linux, calling unified core explorer commands.
3. **Headless Scriptable CLI** (`apps/cli`): `raw-viewer` executable providing JSON-envelope automation, environment diagnostics, grammar testing, profile management, and agent skill registration.
4. **Agent Workflows & Skills** (`.agents/skills/`): `set-grammar` and `set-profile` skills for automated, conversational onboarding of laboratory instrument data.

---

## Key Changes & Architecture

### 1. Configuration & Project Layout (`.raw-viewer/`)
- Legacy `.rawviewer/setting.yaml` is replaced by `<project>/.raw-viewer/config.yaml` (`schema_version: 1`), with backward-compatible fallback for existing projects.
- Read order for grammar:
  1. `<project>/.raw-viewer/grammar.yaml`
  2. `<project>/.rawviewer/grammar.yaml`
  3. `<project>/.rawviewer/view/grammar.yaml`
  4. `config.yaml` inline `grammar:` block
  5. Built-in `standard-scientific` grammar
- Profile directory: `<project>/.raw-viewer/profiles/<id>.yaml` (regular files only; symlinks are rejected). Profiles are enabled via `profiles.enabled` in `config.yaml`.
- Private cache: Project cache and database indexes reside strictly outside project trees under `<platform-cache>/raw-viewer/projects/<sha256>/`.

### 2. Headless CLI (`raw-viewer`)
- Binary location:
  - Unix: `~/.local/bin/raw-viewer`
  - Windows: `%LOCALAPPDATA%\raw-viewer\bin\raw-viewer.exe`
- Strict JSON Envelope:
  - Success: `{"ok":true,"command":"<cmd>","data":{...}}`
  - Failure: `{"ok":false,"command":"<cmd>","error":{"code":"...","message":"...","details":{}}}`
- Predictable Exit Codes:
  - `0`: Success / Ok
  - `1`: Bad usage / syntax error
  - `2`: Resource or path not found
  - `3`: Ambiguous profile match (2+ profiles matched; never falls back to generic table)
  - `4`: Validation error
  - `5`: I/O or filesystem error

### 3. Built-in Profile Namespaces
- Shipped profiles are namespaced under `usth/...`:
  - `usth/keithley-2400`
  - `usth/autolab-usth`
  - `usth/horiba-labram`
  - `usth/iop-hanoi`
  - `usth/keysight-b1500a`

### 4. Shipped Agent Skills
- `set-grammar`: Interactive interview to deduce filename tokens and validate against sample filenames via `raw-viewer --json grammar test`.
- `set-profile`: Interactive column/row mapping tool creating verified Schema v4 YAML profiles.
- Automated installation and repair via `raw-viewer skills install` and `raw-viewer skills repair` to `~/.agents/skills` and `~/.claude/skills` (or Windows `%USERPROFILE%`).
