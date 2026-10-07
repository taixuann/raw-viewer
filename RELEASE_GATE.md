# Release gate — RawView v0.1.0
#
# HISTORICAL RECEIPT: this file records the v0.1.0 release checks as run on
# 2026-10-02. It does not describe the current reader boundary (app-owned
# readers replaced the `reader.py` trust model in ticket #2) and must not be
# overwritten with new PASS marks; preserve it as evidence.

Date: 2026-10-02. Checker: orchestrator (improve + opencode-delegate session), executor `opencode-go/deepseek-v4.1-flash` (max).

## Checked commands and results

| Check | Command | Result |
|---|---|---|
| Tracked set | `git ls-files` | 23 files (source, tests, scripts, docs, LICENSE, .gitignore) |
| Secrets scan | `git grep -nE "ghp_\|sk-ant-\|API_KEY\|PASSWORD\|SECRET\|TOKEN"` | 0 hits |
| Local paths | `git grep -n "/Users/\|/private/tmp\|/var/folders"` | 0 hits after `885b471` (generic `/tmp` defaults; overridable via `RAWVIEW_*` env vars) |
| Email/PII scan | `git grep -nE "[a-zA-Z0-9._]+@[a-zA-Z0-9]+\.[a-z]{2,}"` | 0 hits (LICENSE holder alias `TAO-QKV` only) |
| Mojibake scan | `git grep -nP "\x{FFFD}"` | 0 hits |
| Whitespace | `git diff --check` | clean |
| Tests/smocks | `Scripts/check_core.sh` (SwiftPM) | not run at release time — Swift toolchain build not executed in this session; release proceeds as developer preview |

## Intentional exceptions

1. No CI configured in this repository. Per the github-repo-care rule "release tag exists but CI is red", the absence of CI is recorded here as an intentional exception rather than a red run.
2. README states the package script is a developer build, not distribution-ready. The release is tagged as a developer preview (`v0.1.0`), matching that disclaimer.
3. Reader-trust model: the app executes `data/instruments/reader.py` with the user's permissions after explicit per-project approval (documented in README and CONTRACT.md). This is a documented product behavior, not a vulnerability finding.

## Remaining warnings

- None open at publish time.
