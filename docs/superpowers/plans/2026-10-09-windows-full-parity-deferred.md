# Windows Full-Parity Deferred Resumption Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans only after the written design and implementation plan are approved. Checkboxes below track resumption gates, not authorized implementation tasks.

**Goal:** Eventually deliver a standalone Windows RawView with the complete agreed macOS feature set and no Swift installation required for end users.

**Architecture:** Preserve the existing native macOS application. Evaluate shared Swift core and SwiftOpenUI source reuse; SwiftOpenUI is a candidate, not an approved dependency or a binary wrapper. Windows requires a newly compiled executable, platform adaptations, and a verified runtime bundle.

**Tech Stack:** Current Swift/SwiftUI/AppKit macOS app; candidate SwiftOpenUI Win32/Direct2D backend. Windows architecture, dependency versions, graphics/export implementation, and installer format require design decisions before execution.

**Spec:** No approved written Windows design exists. Product intent: Linear TAI-78, Raw Viewer project `f79d73241808`; this conversation's full macOS-feature-parity requirement. This is deliberately a deferred resumption plan, NOT an execution-ready implementation plan.

## Status and priority

DEFERRED by Tai's request. Develop the intended complete macOS app first, starting with TAI-79 (smart folder/data detection), then address reader-profile work through its own approved design. Do not automatically resume Windows when either issue closes: Tai must confirm the macOS feature baseline is complete enough and authorize resumption.

The local decision does not change Linear: TAI-78 was Backlog at the read-only audit, and no tracker mutation is authorized here.

## Global Constraints

- Preserve the native SwiftUI macOS app and existing features; no full Rust rewrite assumed.
- Target full functional parity, not a reduced Windows release. Do not claim identical pixels or performance without measurements.
- End users must not need a Swift toolchain installed.
- Preserve raw bytes, acquisition order, values, gaps, units, provenance, diagnostics, and human scientific-acceptance gates.
- Do not weaken fail-closed profile matching or secure file/cache policies to obtain a Windows build.
- No commits, pushes, merges, publication, installs, or paid Windows infrastructure without authorization.
- Re-read repo instructions and live state on resumption; audit baseline was `75f9add1af120f94ca3e1a64477b930c9139168e` in the clean `raw-viewer-upgrade` worktree before this document.

## Evidence and ownership

Product owner: `/Users/tai/research-projects/tools/raw-viewer`; existing isolated checkout: `/Users/tai/agent-development/worktrees/raw-viewer-upgrade`. Planning artifacts remain in the product repo. Later bounded implementation briefs go to Tai's selected Codex or OpenCode executor; control plane verifies diffs and real checks.

Fresh audit: `Scripts/check_core.sh` passed, including app-layer typecheck. `swift test` could not compile tests because `Testing` was unavailable; no full suite pass. No Windows execution has occurred.

Installed app: ARM64 Mach-O, macOS 14 minimum; linked Apple SwiftUI/AppKit/Combine/CoreGraphics/CryptoKit/Darwin dependencies. Bundling the current binary cannot establish Windows compatibility.

SwiftOpenUI inspected at `8100d9ca2f46b0f2a9251c33afd466c166939229`:
- `https://github.com/codelynx/SwiftOpenUI/blob/8100d9ca2f46b0f2a9251c33afd466c166939229/docs/architecture/swiftui-parity-matrix.md`
- `https://github.com/codelynx/SwiftOpenUI/blob/8100d9ca2f46b0f2a9251c33afd466c166939229/docs/api/implementation-tracker/views.md`
- `https://github.com/codelynx/SwiftOpenUI/blob/8100d9ca2f46b0f2a9251c33afd466c166939229/docs/guides/app-bundle-packaging.md`
- `https://github.com/codelynx/SwiftOpenUI/blob/8100d9ca2f46b0f2a9251c33afd466c166939229/Examples/Showcase/SimplePaint/main.swift`

Source reuse is plausible; RawView compatibility is unverified. Tracker reports Table and Settings missing, parity matrix reports AppStorage missing, Windows Canvas remains a subset. Older Canvas docs differ from newer code/examples: inspect pinned implementation before treating individual gaps as current.

## Review Focus

1. Unicode/case/drive/UNC paths and reparse-point races must not escape the selected root or silently follow forbidden links.
2. Dense traces, gaps, overlays, and repeated/reversed sweep points must render without altering arrays or dropping acquired rows.
3. Publication exports must preserve calibrated dimensions, typography, styles, and vector PDF behavior; screenshots are not substitutes.
4. Read-only roots and unavailable/private-cache locations must remain usable without writes to raw evidence.
5. A clean non-admin Windows machine without Swift/Visual Studio must launch the bundle with all required resources and runtimes; developer-machine success is insufficient.

## Resumption gates

### Gate 1: Freeze the macOS parity baseline
- [ ] Obtain Tai's explicit approval to resume Windows after macOS feature completion.
- [ ] Re-read instructions, current CONTRACT.md, README.md, RELEASE_GATE.md, and Git state.
- [ ] Inventory every user-visible feature and create a parity checklist covering open/discovery, profiles, diagnostics, table, plot/overlay, inspector, settings, snapshots, exports, keyboard/accessibility, and packaging.
- [ ] Execute available macOS checks and record unassessed behavior separately. Do not assume this audit's pass applies to later code.

### Gate 2: Approve a bounded feasibility probe
- [ ] Confirm Windows CPU architecture, supported OS version, and available Windows test host.
- [ ] Present a throwaway probe brief and get approval; do not install dependencies or create product scaffolding first.
- [ ] Evaluate the actual RawView Canvas drawing calls and export path against pinned SwiftOpenUI implementation, alongside targeted UI/state compatibility checks.
- [ ] Run the probe on Windows and report compile failures, rendering/export differences, latency, and memory using synthetic representative fixtures; no fabricated performance thresholds.
- [ ] Recommend SwiftOpenUI or a technically supported alternative. Retaining the probe as product code requires separate approval.

### Gate 3: Approve platform design
- [ ] Design secure Windows file access and private cache behavior with tests for Review Focus items 1 and 4. Audit Darwin calls in ProjectContext.swift/MeasurementCache.swift, CryptoKit imports, and SQLite build linkage.
- [ ] Design UI source reuse and platform adapters for dialogs, application entry point, settings, graphics, and exports; inspect RawViewApp.swift, ProjectGalleryViews.swift, PlotRenderingEngine.swift, FigureExporter.swift, and SettingsView.swift.
- [ ] Specify synthetic regression fixtures for Review Focus items 2 and 3, plus macOS non-regression checks.
- [ ] Specify resource discovery and complete runtime dependency closure for Review Focus item 5. The upstream create-bundle guide is not proof all Swift/CRT dependencies are included.
- [ ] Present design sections, save a product-owned written spec only after conversational approval, and obtain written-spec approval. Do not auto-commit the spec.

### Gate 4: Write execution-ready plans
- [ ] Invoke writing-plans after the written spec is approved. Split into independently verifiable core-portability, Windows UI/full parity, and standalone distribution plans.
- [ ] Define exact file/interface changes and RED/GREEN checks from the selected design, not speculative signatures invented before feasibility evidence.
- [ ] Obtain Tai's plan review and executor choice. No execution while deferred.

### Gate 5: Build, verify, and distribute only within authorized scope
- [ ] Route task-sized briefs to the selected executor in valid isolation and review each returned diff.
- [ ] Run shared core correctness/security tests on Windows and macOS; verify full parity checklist and measured performance against approved baseline/targets.
- [ ] Build portable Windows artifact first, verify on a clean machine, then create the approved installer and verify install/uninstall without touching user data.
- [ ] Report feature/test evidence and remaining gaps. Request separate authorization for integration, release signing, publication, or installation.

## Self-review and handoff

This document preserves the agreed eventual outcome and suspension decision without pretending unresolved feasibility and platform choices are settled. It is not an implementation authorization. Resume at Gate 1; do not skip to dependency installation or porting. No Windows implementation artifact was produced by this planning step.
