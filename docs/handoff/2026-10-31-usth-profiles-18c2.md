# usth v4 profiles and `.raw-viewer/profiles/` discovery (issue #18, contract 18c-2)

## Discovery

Profile catalogs now scan, in order:

1. `<project>/.raw-viewer/profiles/`
2. `<project>/.rawviewer/instrument/`
3. `<project>/data/.rawview/instrument/`
4. `<project>/data/instruments/` (companion `rawview/` when present)

The usth-lab workspace ships four schema-v4 profiles under `.raw-viewer/profiles/` with namespaced ids (`usth/autolab-usth`, `usth/keithley-2400`, `usth/horiba-labram`, `usth/iop-hanoi`).

## Keithley LVM metadata probe (L224)

Generic tabular `header_metadata` on the dual-sweep fixture yields extra second-block keys (for example `Channels`, `Samples`, `X_Dimension`) and omits the single-cell `LabVIEW Measurement` row. **Probe result: not sufficient.** v4 schema-v4 `usth/keithley-2400` measurements apply an ordered 11-key Acquisition list in Rust and Swift without changing v2 golden JSON.

## Grammar

Deferred to #24; usth routing uses `when` filename/content selectors only.
