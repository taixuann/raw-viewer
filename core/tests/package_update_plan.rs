//! Update planning for lab packages at package and profile level (issue #121, cases 1 to 6).

use raw_viewer_core::package::{
    parse_package_manifest, plan_update, profile_revision, render_manifest, select_writes,
    upgraded_manifest, PackageManifest, ProfileFile, ProfileUpdateState, VersionChange,
};
use raw_viewer_core::profile::sha256_hex;

const KEITHLEY: &str = "usth/keithley-2400";
const AUTOLAB: &str = "usth/autolab-usth";

fn ids(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn profile_text(revision: u32, body: &str) -> String {
    format!("schema_version: 4\nrevision: {revision}\nname: {body}\n")
}

/// Builds a manifest text from (profile id, file text) pairs, recording each file's sha256.
fn manifest_for(version: &str, files: &[(&str, &str)]) -> PackageManifest {
    let mut text = format!(
        "schema_version: 1\nid: usth-lab\nversion: \"{version}\"\ndisplay_name: \"USTH Lab\"\nprofiles:\n"
    );
    for (id, body) in files {
        let stem = id.rsplit('/').next().unwrap();
        text.push_str(&format!(
            "  - id: {id}\n    path: profiles/{stem}.yaml\n    sha256: {}\n",
            sha256_hex(body.as_bytes())
        ));
    }
    parse_package_manifest(&text, "test:manifest").expect("manifest text is valid")
}

fn file_state(id: &str, on_disk: &str) -> ProfileFile {
    ProfileFile {
        id: id.to_string(),
        revision: profile_revision(on_disk),
        sha256: Some(sha256_hex(on_disk.as_bytes())),
    }
}

#[test]
fn case1_same_version_and_revisions_list_no_update() {
    let keithley = profile_text(1, "keithley");
    let autolab = profile_text(1, "autolab");
    let installed = manifest_for("0.1.0", &[(KEITHLEY, &keithley), (AUTOLAB, &autolab)]);
    let bundled = manifest_for("0.1.0", &[(KEITHLEY, &keithley), (AUTOLAB, &autolab)]);
    let files = [
        file_state(KEITHLEY, &keithley),
        file_state(AUTOLAB, &autolab),
    ];
    let revisions = [(KEITHLEY.to_string(), 1), (AUTOLAB.to_string(), 1)];

    let plan = plan_update(&installed, &files, &bundled, &revisions, &[]);

    assert_eq!(plan.package_update, None);
    assert!(
        plan.profiles.is_empty(),
        "no profile is listed: {:?}",
        plan.profiles
    );
    assert!(select_writes(&plan, &[], &[]).unwrap().is_empty());
}

#[test]
fn case2_newer_bundled_package_version_lists_package_with_changed_profiles() {
    let keithley_old = profile_text(1, "keithley");
    let autolab = profile_text(1, "autolab");
    let installed = manifest_for("0.1.0", &[(KEITHLEY, &keithley_old), (AUTOLAB, &autolab)]);
    let keithley_new = profile_text(2, "keithley new");
    let bundled = manifest_for("0.2.0", &[(KEITHLEY, &keithley_new), (AUTOLAB, &autolab)]);
    let files = [
        file_state(KEITHLEY, &keithley_old),
        file_state(AUTOLAB, &autolab),
    ];
    let revisions = [(KEITHLEY.to_string(), 2), (AUTOLAB.to_string(), 1)];

    let plan = plan_update(&installed, &files, &bundled, &revisions, &[]);

    assert_eq!(plan.package_id, "usth-lab");
    assert_eq!(
        plan.package_update,
        Some(VersionChange {
            installed: "0.1.0".to_string(),
            bundled: "0.2.0".to_string(),
        })
    );
    assert_eq!(plan.profiles.len(), 1, "only the changed profile is listed");
    assert_eq!(plan.profiles[0].id, KEITHLEY);
    assert_eq!(plan.profiles[0].installed_revision, Some(1));
    assert_eq!(plan.profiles[0].bundled_revision, 2);
    assert_eq!(plan.profiles[0].state, ProfileUpdateState::UpdateAvailable);
}

#[test]
fn case3_one_newer_profile_updates_alone_and_others_stay_untouched() {
    let keithley_old = profile_text(1, "keithley");
    let autolab = profile_text(1, "autolab");
    let installed = manifest_for("0.1.0", &[(KEITHLEY, &keithley_old), (AUTOLAB, &autolab)]);
    let keithley_new = profile_text(2, "keithley new");
    let bundled = manifest_for("0.1.0", &[(KEITHLEY, &keithley_new), (AUTOLAB, &autolab)]);
    let files = [
        file_state(KEITHLEY, &keithley_old),
        file_state(AUTOLAB, &autolab),
    ];
    let revisions = [(KEITHLEY.to_string(), 2), (AUTOLAB.to_string(), 1)];

    let plan = plan_update(&installed, &files, &bundled, &revisions, &[]);

    assert_eq!(plan.package_update, None);
    assert_eq!(plan.profiles.len(), 1);
    assert_eq!(plan.profiles[0].id, KEITHLEY);
    assert_eq!(plan.profiles[0].state, ProfileUpdateState::UpdateAvailable);

    let writes = select_writes(&plan, &[], &[]).unwrap();
    assert_eq!(writes, ids(&[KEITHLEY]), "autolab is not written");
    let single = select_writes(&plan, &ids(&[KEITHLEY]), &[]).unwrap();
    assert_eq!(single, ids(&[KEITHLEY]));

    let after = upgraded_manifest(&installed, &bundled, &writes);
    assert_eq!(after.profiles.len(), 2);
    assert_eq!(
        after.profiles[0].sha256.as_str(),
        sha256_hex(keithley_new.as_bytes())
    );
    assert_eq!(
        after.profiles[1].sha256.as_str(),
        sha256_hex(autolab.as_bytes())
    );
}

#[test]
fn case4_edited_profile_is_kept_without_consent_and_replaced_with_consent() {
    let keithley_installed = profile_text(1, "keithley");
    let keithley_edited = profile_text(1, "keithley with my edit");
    let installed = manifest_for("0.1.0", &[(KEITHLEY, &keithley_installed)]);
    let keithley_new = profile_text(2, "keithley new");
    let bundled = manifest_for("0.2.0", &[(KEITHLEY, &keithley_new)]);
    let files = [file_state(KEITHLEY, &keithley_edited)];
    let revisions = [(KEITHLEY.to_string(), 2)];

    let plan = plan_update(&installed, &files, &bundled, &revisions, &[]);

    assert_eq!(plan.profiles.len(), 1);
    assert_eq!(plan.profiles[0].state, ProfileUpdateState::LocallyEdited);
    assert_eq!(plan.profiles[0].installed_revision, Some(1));
    assert_eq!(plan.profiles[0].bundled_revision, 2);

    let kept = select_writes(&plan, &[], &[]).unwrap();
    assert!(kept.is_empty(), "edited profile is kept: {kept:?}");
    let kept_manifest = upgraded_manifest(&installed, &bundled, &kept);
    assert_eq!(kept_manifest.version.as_str(), "0.2.0");
    assert_eq!(
        kept_manifest.profiles[0].sha256.as_str(),
        sha256_hex(keithley_installed.as_bytes()),
        "manifest keeps the sha of the file that is still on disk"
    );

    let refused = select_writes(&plan, &ids(&[KEITHLEY]), &[]).unwrap_err();
    assert!(
        refused.contains("--replace usth/keithley-2400"),
        "{refused}"
    );

    let replaced = select_writes(&plan, &ids(&[KEITHLEY]), &ids(&[KEITHLEY])).unwrap();
    assert_eq!(replaced, ids(&[KEITHLEY]));
    let replaced_manifest = upgraded_manifest(&installed, &bundled, &replaced);
    assert_eq!(
        replaced_manifest.profiles[0].sha256.as_str(),
        sha256_hex(keithley_new.as_bytes())
    );
}

#[test]
fn case5_project_local_override_is_reported_and_never_changed() {
    let keithley_old = profile_text(1, "keithley");
    let installed = manifest_for("0.1.0", &[(KEITHLEY, &keithley_old)]);
    let keithley_new = profile_text(2, "keithley new");
    let bundled = manifest_for("0.2.0", &[(KEITHLEY, &keithley_new)]);
    let files = [file_state(KEITHLEY, &keithley_old)];
    let revisions = [(KEITHLEY.to_string(), 2)];
    let overrides = ids(&[KEITHLEY]);

    let plan = plan_update(&installed, &files, &bundled, &revisions, &overrides);

    assert_eq!(plan.profiles.len(), 1);
    assert_eq!(plan.profiles[0].state, ProfileUpdateState::ProjectOverride);
    assert!(select_writes(&plan, &[], &ids(&[KEITHLEY]))
        .unwrap()
        .is_empty());
    let scoped = select_writes(&plan, &ids(&[KEITHLEY]), &[]).unwrap_err();
    assert!(scoped.contains("project-local"), "{scoped}");
}

#[test]
fn case6_manifest_after_update_has_new_version_and_sha256_values() {
    let keithley_old = profile_text(1, "keithley");
    let installed = manifest_for("0.1.0", &[(KEITHLEY, &keithley_old)]);
    let keithley_new = profile_text(2, "keithley new");
    let bundled = manifest_for("0.2.0", &[(KEITHLEY, &keithley_new)]);
    let files = [file_state(KEITHLEY, &keithley_old)];
    let revisions = [(KEITHLEY.to_string(), 2)];
    let plan = plan_update(&installed, &files, &bundled, &revisions, &[]);
    let writes = select_writes(&plan, &[], &[]).unwrap();

    let after = upgraded_manifest(&installed, &bundled, &writes);
    let rendered = render_manifest(&after);
    let reparsed = parse_package_manifest(&rendered, "test:rendered").expect("rendered manifest");

    assert_eq!(reparsed.version, "0.2.0");
    assert_eq!(reparsed.profiles.len(), 1);
    assert_eq!(reparsed.profiles[0].id.as_str(), KEITHLEY);
    assert_eq!(
        reparsed.profiles[0].path.as_str(),
        "profiles/keithley-2400.yaml"
    );
    assert_eq!(
        reparsed.profiles[0].sha256.as_str(),
        sha256_hex(keithley_new.as_bytes())
    );
}

#[test]
fn package_version_compares_numerically_not_lexically() {
    let body = profile_text(1, "keithley");
    let installed = manifest_for("0.9.0", &[(KEITHLEY, &body)]);
    let bundled = manifest_for("0.10.0", &[(KEITHLEY, &body)]);
    let files = [file_state(KEITHLEY, &body)];
    let revisions = [(KEITHLEY.to_string(), 1)];

    let plan = plan_update(&installed, &files, &bundled, &revisions, &[]);

    assert_eq!(
        plan.package_update,
        Some(VersionChange {
            installed: "0.9.0".to_string(),
            bundled: "0.10.0".to_string(),
        })
    );
    assert!(plan.profiles.is_empty());
}
