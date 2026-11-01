# usth v4 profiles and `.raw-viewer/profiles/` discovery (issue #18, contract 18c-2)

## Discovery

Profile catalogs now scan, in order:

1. `<project>/.raw-viewer/profiles/`
2. `<project>/.rawviewer/instrument/`
3. `<project>/data/.rawview/instrument/`
4. `<project>/data/instruments/` (companion `rawview/` when present)

The usth-lab workspace ships four schema-v4 profiles under `.raw-viewer/profiles/` with namespaced ids (`usth/autolab-usth`, `usth/keithley-2400`, `usth/horiba-labram`, `usth/iop-hanoi`).

## Keithley LVM metadata probe (L224)

Generic tabular `header_metadata` on the dual-sweep fixture pulls second-block noise (for example `Channels`, `Samples`, duplicate `Date`/`Time` columns) and extra keys RawView does not want on the Acquisition panel. **Probe result: not sufficient.** Tai's decision for this cycle: keep **Date** and **Time** only from the first acquisition header block via v4 row metadata (`row`/`key`/`type`); no plain-string metadata keys and no `LabVIEW Measurement` placeholder.

## Keithley columns

`usth/keithley-2400` maps `Untitled` → voltage (V), `Untitled 1` → current (A), and `Untitled 2` → time progression (s). Plot axes remain voltage vs current.

## Grammar

Deferred to #24; usth routing uses `when` filename/content selectors only.
