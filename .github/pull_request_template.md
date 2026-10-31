## Summary

<!-- What changed and why. -->

## Acceptance case → test mapping

<!-- One row per acceptance case from the task contract. Use the exact case name from the contract. -->

| Acceptance case | Test or vector |
| --- | --- |
| _(example)_ | `myNamedTest` or `fixtures/.../vectors.yaml` row `vector-id` |

## Checklist

- [ ] Every acceptance case in the task contract appears in the mapping table above.
- [ ] Each acceptance case has its own named test or shared vector row in code.
- [ ] Multi-value acceptance cases assert every column or element, not only the first.
- [ ] `./apps/macos/Scripts/check_core.sh` and `./apps/macos/Scripts/check_index_cli.sh` pass when Swift/macOS code changed (or CI swift job is green).
- [ ] `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D warnings`, and `cargo test --workspace` pass when Rust code changed (or CI rust jobs are green).
