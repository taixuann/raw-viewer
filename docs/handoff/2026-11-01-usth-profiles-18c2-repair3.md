# usth 18c-2 repair cycle 3 — decision log

Parent handoff: [2026-10-31-usth-profiles-18c2.md](./2026-10-31-usth-profiles-18c2.md) (draft PR #37).

## Decision log

### D1 — Autolab CV plot uses WE(1).Potential, not applied potential

**Decision:** `cv.plot.x` is `electrode_potential` (`WE(1).Potential (V)`). `Potential applied (V)`, `Time (s)`, and auxiliary columns use `role: skip`.

**Evidence:** Fixture header is `Potential applied (V);Time (s);WE(1).Current (A);WE(1).Potential (V);Scan;…`. Tai specified x = `WE(1).Potential (V)` and y = `WE(1).Current (A)`.

**Alternatives:** Keep x on applied potential (repair cycle 1–2 behavior) — rejected per Tai.

### D2 — Scan column is progression with discrete behavior

**Decision:** Column key `scan`, header `Scan`, `role: progression`, `type: custom`, `behavior: discrete`.

**Evidence:** Exact header `Scan` in the CV fixture first row. Tests assert channel `scan` with quantity `index` and profile progression behavior `discrete`.

**Alternatives:** `type: index` — rejected; Scan encodes CV segment index, not a simple row index.

### D3 — EIS Nyquist is the sole v4 `plot`; Bode columns are channels

**Decision:** `eis.plot` is Nyquist (`x: z_prime`, `y: [z_double_prime]`). Bode axes (`frequency`, `z_magnitude`, `phase`) stay `role: channel`. `Index` and `Time (s)` are `skip`.

**Evidence:** Schema v4 allows one `plot` mapping per variant (`core/src/profile/v4.rs:36`, `InstrumentProfileV4.swift:39`). Skip role is supported (`v4.rs:731`, compile omit `v4.rs:272-273`; Swift `InstrumentProfileV4.swift:77`, omit `216`). Multi-y on one x (`PlotSpecV4.y: Vec<String>`, `v4.rs:92-94`) could express Bode only, not Nyquist and Bode together.

**Alternatives:** Invent `plots:` array or second variant — rejected (Tai: schema v4 only). Primary Bode plot — rejected; Nyquist is the default electrochemistry view and matches updated `expected.yaml` plottable axes.

### D4 — `expected.yaml` entry counts are contract gates

**Decision:** Rust and Swift assert total entries `9` and plottable `6`. Swift `parseExpectedEntries` throws on malformed rows instead of `compactMap` dropping them.

**Evidence:** Nine committed fixture rows in `fixtures/workspaces/usth-lab/expected.yaml`; six `plottable: true`.

**Alternatives:** Silent drop on parse failure — rejected per repair cycle 3 brief.

### D5 — `cv_2col` variant unchanged

**Decision:** Leave `cv_2col` as two-column WE(1)_potential / WE(1)_current layout.

**Evidence:** `when.content_contains_any` targets `WE(1)_potential(V)` / `WE(1)_current(A)`; standard `cv` targets `Potential applied (V)`. No usth-lab plottable fixture uses the 2-column header today.

**Alternatives:** Merge variants — rejected; selectors stay disjoint.

## v4 capability summary (repair cycle 3)

| Feature | Supported? | Location |
| --- | --- | --- |
| Column `role: skip` | Yes | Rust decode `core/src/profile/v4.rs:731`; compile skip `272-273`. Swift `InstrumentProfileV4.swift:77`, `216`. |
| Multiple y on one plot | Yes | `PlotSpecV4.y: Vec<String>` at `core/src/profile/v4.rs:92-94`. |
| Multiple plots per variant | No | Single `plot: PlotSpecV4` on `ProfileVariantV4` at `core/src/profile/v4.rs:36` / `InstrumentProfileV4.swift:39`. Bode as a second default view pending schema work. |

## Tai autolab axis summary

| Variant | plot x | plot y | progression | skip (role) |
| --- | --- | --- | --- | --- |
| cv | `electrode_potential` | `current` | `scan` (discrete) | applied_voltage, time, index, q_plus, q_minus, current_range |
| ca | `time` | `current` | — | electrode_potential, corrected_time, index, current_range, overload |
| eis | `z_prime` | `z_double_prime` | — | index, time (Bode columns remain channels for data) |
