# RawView reader contract v1

RawView first invokes the project reader once per bounded metadata batch:

```text
reader.py inspect-many --paths-json
```

Standard input is a JSON array of project-relative `data/raw` paths with at most
256 entries. Standard output is one object with a `sources` array containing one
row per path. A successful row may include `size`, `instrument_id`,
`instrument_name`, `application_mode`, `timestamp`, `device_id`, `study_token`,
`support_status`, `validation_state`, `reader_version`, `profile_id`, and
`profile_hash`. A failed row includes its `source` path and an `error` string;
one failed source must not suppress other rows. Unknown metadata is omitted,
not inferred.

Inspection and loading begin only after the user approves the project reader.
Approval is bound to the canonical project path and reader SHA-256. The user
must approve again when the reader changes, and can revoke the saved approval.
The reader and configured shared parsers execute with the user's permissions
and may access or change files available to that account.

RawView inventories and inspects every discovered source, then loads successful
sources with at most two concurrent reader processes. Inspection and load
progress update as batches and sources finish. Cancellation stops queued work;
errors remain isolated to their source and can be retried. The app validates
paths under `data/raw` and verifies source hashes before and after parsing.

For each successfully inspected source, RawView invokes:

```text
reader.py load <absolute-source-path>
```

The process runs with the project root as its working directory. Standard output
must contain one JSON object. Standard error is reserved for diagnostics; a
non-zero exit status displays its diagnostic on that source's panel. Each
process has a five-minute limit, a 32 MiB standard-output limit, and only the
final 4 KiB of standard-error diagnostics are retained.

Required JSON fields:

| Field | Shape | Meaning |
|---|---|---|
| `contract_version` | integer, exactly `1` | Contract version. |
| `source.path` | string | Project-relative source path. Must match the source being loaded. |
| `source.sha256` | 64 hexadecimal characters | SHA-256 of the source before parsing. RawView independently checks the hash before and after the reader runs. |
| `instrument.id`, `instrument.name` | strings | Reader-reported instrument identity. |
| `view.kind` | `xy`, `timeseries`, `spectrum`, `regions`, `table`, or `metadata-only` | View representation. |
| `view.preserve_order` | boolean | Must be `true` for data views. Acquisition order is retained. |
| `channels` | array | Ordered named channels with `name`, `label`, `unit`, and finite numeric `values`. Channel names must be unique and channel lengths equal. |
| `metadata_sections` | array | Sections with a `title` and fields containing `key`, `label`, primitive `value`, optional `unit`, and `kind`. |
| `warnings` | array of strings | Reader-reported parsing limitations or warnings. |
| `support_status` | string | Reader-reported support state. |
| `provenance` | optional string-to-string object | Reader-reported provenance; displayed as reported, not independently established. |

Optional `application_mode` is a string. For non-metadata-only views, `view.x`
must name a channel and `view.y` must contain one or more channel names. The
reader supplies extracted values and labels; RawView does not infer scientific
meaning from them. Data tables preserve channel order and values. Absolute and
linear/log transformations apply only to figures and share one setting per axis
across the project. A log-domain failure appears on only the affected figure;
it does not alter the table or block another source. Source paths, hashes,
reader entrypoint hash, and unchanged-source verification are checked by the app.
