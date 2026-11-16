//! Revision-bump check for bundled USTH profiles (issue #121, acceptance case 7).

use raw_viewer_core::package::{
    profile_bump_violations, BundledTable, USTH_LAB_PACKAGE_ID, USTH_LAB_PACKAGE_VERSION,
};
use raw_viewer_core::profile::BUILTIN_PROFILES;

const COMMITTED_TABLE: &str =
    include_str!("../../fixtures/packages/usth-lab/bundled-profiles.json");

fn committed_table() -> BundledTable {
    serde_json::from_str(COMMITTED_TABLE).expect("committed table parses")
}

fn bundled_profiles() -> Vec<(String, String)> {
    BUILTIN_PROFILES
        .iter()
        .map(|(rel, text)| {
            let stem = rel.rsplit('/').next().unwrap().trim_end_matches(".yaml");
            (format!("usth/{stem}"), text.to_string())
        })
        .collect()
}

fn as_refs(owned: &[(String, String)]) -> Vec<(&str, &str)> {
    owned
        .iter()
        .map(|(id, text)| (id.as_str(), text.as_str()))
        .collect()
}

#[test]
fn bundled_usth_profiles_match_committed_revision_table() {
    let table = committed_table();
    assert_eq!(table.package_id, USTH_LAB_PACKAGE_ID);
    assert_eq!(table.version, USTH_LAB_PACKAGE_VERSION);
    assert_eq!(table.profiles.len(), 4);

    let bundled = bundled_profiles();
    let violations = profile_bump_violations(&table.profiles, &as_refs(&bundled));
    assert!(
        violations.is_empty(),
        "bundled profiles drifted from the committed table: {violations:?}"
    );
}

#[test]
fn changed_bundled_profile_with_unchanged_revision_fails_check() {
    let table = committed_table();
    let mut bundled = bundled_profiles();
    let keithley = bundled
        .iter_mut()
        .find(|(id, _)| id == "usth/keithley-2400")
        .expect("keithley bundled");
    keithley.1.push_str("# edited without a revision bump\n");

    let violations = profile_bump_violations(&table.profiles, &as_refs(&bundled));
    assert_eq!(
        violations.len(),
        1,
        "exactly one profile changed: {violations:?}"
    );
    assert!(violations[0].contains("usth/keithley-2400"));
    assert!(violations[0].contains("without a revision bump"));
}
