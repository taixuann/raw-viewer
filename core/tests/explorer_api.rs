//! Integration tests for raw_viewer_core::explorer::Explorer facade (Issue #21).

use raw_viewer_core::explorer::{
    Explorer, ExplorerError, GrammarSource, MatchOutcome, ProfileSource,
};
use std::fs;
use std::path::{Path, PathBuf};

fn usth_lab_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/workspaces/usth-lab")
}

#[test]
fn explorer_open_usth_lab_summary_and_profiles() {
    let root = usth_lab_root();
    let explorer = Explorer::open(&root).expect("open explorer");

    let summary = explorer.summary();
    assert_eq!(summary.data_root, "data/raw");
    assert_eq!(summary.grammar_source, GrammarSource::Builtin);
    assert_eq!(summary.grammar_id, "standard-scientific");

    let profiles = explorer.list_profiles();
    assert_eq!(profiles.len(), 4);

    let ids: Vec<&str> = profiles.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(
        ids,
        vec![
            "usth/autolab-usth",
            "usth/horiba-labram",
            "usth/iop-hanoi",
            "usth/keithley-2400"
        ]
    );

    for p in &profiles {
        assert!(p.enabled, "profile {} should be enabled", p.id);
        assert_eq!(
            p.source,
            ProfileSource::Project,
            "profile {} should come from project",
            p.id
        );
    }
}

#[test]
fn explorer_inventory_usth_lab() {
    let root = usth_lab_root();
    let explorer = Explorer::open(&root).expect("open explorer");

    let report = explorer.inventory().expect("inventory");

    // 7 supported measurement files in data/raw
    assert_eq!(report.total_files, 7);
    assert_eq!(report.sources.len(), 7);

    for s in &report.sources {
        assert!(
            s.relative_path.ends_with(".txt")
                || s.relative_path.ends_with(".csv")
                || s.relative_path.ends_with(".lvm")
        );
        assert!(!s.relative_path.contains(".intake.log"));
        assert!(!s.relative_path.contains(".quarantine"));
        assert!(!s.relative_path.contains(".DS_Store"));
    }

    assert!(report
        .ignored
        .iter()
        .any(|i| i == "data/raw/2026-10-07/.intake.log"));
    assert!(report
        .ignored
        .iter()
        .any(|i| i == "data/raw/2026-10-07/.quarantine/"));
}

#[test]
fn explorer_match_and_inspect_keithley_dual_sweep() {
    let root = usth_lab_root();
    let explorer = Explorer::open(&root).expect("open explorer");

    let rel = Path::new(
        "data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt",
    );

    let match_res = explorer.match_file(rel).expect("match file");
    match match_res {
        MatchOutcome::Matched {
            profile_id,
            instrument_id,
            variant,
            tokens,
            ..
        } => {
            assert_eq!(profile_id, "usth/keithley-2400");
            assert_eq!(instrument_id, "keithley-2400");
            assert_eq!(variant, "dual-sweep");
            assert_eq!(
                tokens.get("device").map(String::as_str),
                Some("keithley-2400")
            );
            assert_eq!(
                tokens.get("application-mode").map(String::as_str),
                Some("dual-sweep")
            );
        }
        other => panic!("expected Matched, got {:?}", other),
    }

    let report = explorer.inspect(rel).expect("inspect file");
    assert_eq!(report.profile_id, "usth/keithley-2400");
    assert_eq!(report.variant, "dual-sweep");
    assert_eq!(report.data_row_count, 121);
    assert_eq!(report.disposition, "profile_matched");
    assert_eq!(report.columns.len(), 3);
    assert_eq!(report.x_quantity.as_deref(), Some("voltage"));
    assert_eq!(report.x_unit.as_deref(), Some("V"));
    assert_eq!(report.y_quantity.as_deref(), Some("current"));
    assert_eq!(report.y_unit.as_deref(), Some("A"));
}

#[test]
fn explorer_inspect_autolab_cv_and_horiba_raman() {
    let root = usth_lab_root();
    let explorer = Explorer::open(&root).expect("open explorer");

    let cv_rel = Path::new(
        "data/raw/2025-11-27/271125-000000_autolab-usth.cv_[au-pda]_cv.deposition_r.[20mv-ph-8.4].txt",
    );
    let cv_report = explorer.inspect(cv_rel).expect("inspect autolab cv");
    assert_eq!(cv_report.profile_id, "usth/autolab-usth");
    assert_eq!(cv_report.variant, "cv");
    assert_eq!(cv_report.data_row_count, 4100);
    assert_eq!(cv_report.disposition, "profile_matched");

    let raman_rel = Path::new(
        "data/raw/2026-05-25/250526-000000_horiba-labram.raman_[pda.q1-ito.3]_raman.sers.txt",
    );
    let raman_report = explorer.inspect(raman_rel).expect("inspect horiba raman");
    assert_eq!(raman_report.profile_id, "usth/horiba-labram");
    assert_eq!(raman_report.variant, "raman");
    assert_eq!(raman_report.data_row_count, 1853);
    assert_eq!(raman_report.disposition, "profile_matched");
}

#[test]
fn explorer_inspect_header_only_reports_no_data_rows() {
    let root = usth_lab_root();
    let explorer = Explorer::open(&root).expect("open explorer");

    let rel = Path::new(
        "data/raw/2026-10-07/SYNTHETIC_keithley-2400.dual-sweep_header-only_no-data-rows.txt",
    );
    let report = explorer.inspect(rel).expect("inspect header only");
    assert_eq!(report.profile_id, "usth/keithley-2400");
    assert_eq!(report.variant, "dual-sweep");
    assert_eq!(report.data_row_count, 0);
    assert_eq!(report.disposition, "no_data_rows");
}

fn temp_project(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "rawview-explorer-{}-{}-{}",
        label,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

#[test]
fn explorer_ambiguous_profile_surfaces_typed_ambiguous() {
    let root = temp_project("ambiguous");

    // Create .raw-viewer/profiles with 2 competing profiles claiming .txt
    let profiles_dir = root.join(".raw-viewer/profiles");
    fs::create_dir_all(&profiles_dir).expect("create profiles dir");

    let profile_a = r#"
schema_version: 4
id: test/profile-a
instrument:
  id: test-a
  name: Test A
variants:
  default:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: x
      data_prefix: "1"
    columns:
      x:
        role: channel
        header: x
        quantity: voltage
        unit: V
        label: X
      y:
        role: channel
        header: y
        quantity: current
        unit: A
        label: Y
    plot:
      x: x
      y: [y]
    when:
      filename_contains_all: ["sample"]
"#;

    let profile_b = r#"
schema_version: 4
id: test/profile-b
instrument:
  id: test-b
  name: Test B
variants:
  default:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: x
      data_prefix: "1"
    columns:
      x:
        role: channel
        header: x
        quantity: voltage
        unit: V
        label: X
      y:
        role: channel
        header: y
        quantity: current
        unit: A
        label: Y
    plot:
      x: x
      y: [y]
    when:
      filename_contains_all: ["sample"]
"#;

    fs::write(profiles_dir.join("profile-a.yaml"), profile_a).expect("write a");
    fs::write(profiles_dir.join("profile-b.yaml"), profile_b).expect("write b");

    let data_dir = root.join("data/raw");
    fs::create_dir_all(&data_dir).expect("create data dir");
    fs::write(data_dir.join("sample_01.txt"), "x\ty\n1.0\t2.0\n").expect("write sample");

    let explorer = Explorer::open(&root).expect("open explorer");
    let match_res = explorer
        .match_file(Path::new("data/raw/sample_01.txt"))
        .expect("match file");
    match match_res {
        MatchOutcome::AmbiguousProfile { candidate_ids } => {
            assert_eq!(candidate_ids.len(), 2);
            assert!(candidate_ids.iter().any(|c| c.contains("test/profile-a")));
            assert!(candidate_ids.iter().any(|c| c.contains("test/profile-b")));
        }
        other => panic!("expected AmbiguousProfile, got {:?}", other),
    }

    let inspect_err = explorer
        .inspect(Path::new("data/raw/sample_01.txt"))
        .expect_err("inspect should fail with ambiguous");
    match inspect_err {
        ExplorerError::AmbiguousProfile { candidate_ids } => {
            assert_eq!(candidate_ids.len(), 2);
        }
        other => panic!("expected AmbiguousProfile error, got {:?}", other),
    }
}

#[test]
fn explorer_generic_table_fallback_for_unprofiled_data() {
    let root = temp_project("generic-table");

    let data_dir = root.join("data/raw");
    fs::create_dir_all(&data_dir).expect("create data dir");
    fs::write(
        data_dir.join("unprofiled_data.csv"),
        "Time,Temperature,Pressure\n0,25.0,1.01\n1,25.5,1.02\n2,26.0,1.03\n",
    )
    .expect("write csv");

    let explorer = Explorer::open(&root).expect("open explorer");
    let report = explorer
        .inspect(Path::new("data/raw/unprofiled_data.csv"))
        .expect("inspect generic table");

    assert_eq!(report.disposition, "generic_table");
    assert_eq!(report.profile_id, "generic-table");
    assert_eq!(report.data_row_count, 3);
    assert_eq!(report.columns.len(), 3);
}

#[test]
fn explorer_inventory_skips_symlinks_and_affm() {
    let root = temp_project("symlinks");

    let data_dir = root.join("data/raw");
    fs::create_dir_all(&data_dir).expect("create data dir");

    let real_file = data_dir.join("real_run.csv");
    fs::write(&real_file, "a,b\n1,2\n").expect("write real file");

    let affm_file = data_dir.join("scan.affm");
    fs::write(&affm_file, "dummy affm").expect("write affm");

    #[cfg(unix)]
    {
        let symlink_file = data_dir.join("symlink_run.csv");
        std::os::unix::fs::symlink(&real_file, &symlink_file).expect("symlink");
    }

    let explorer = Explorer::open(&root).expect("open explorer");
    let report = explorer.inventory().expect("inventory");

    assert_eq!(report.sources.len(), 1);
    assert_eq!(report.sources[0].relative_path, "data/raw/real_run.csv");

    assert!(report.ignored.iter().any(|i| i.contains("scan.affm")));
    #[cfg(unix)]
    assert!(report.ignored.iter().any(|i| i.contains("(symlink)")));
}

#[test]
fn explorer_zero_project_writes_outside_dot_raw_viewer() {
    let root = usth_lab_root();

    // Snapshot existing entries before run
    let before_files: Vec<PathBuf> = walkdir_entries(&root);

    let explorer = Explorer::open(&root).expect("open");
    let _ = explorer.inventory().expect("inventory");
    let _ = explorer
        .inspect(Path::new(
            "data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt",
        ))
        .expect("inspect");
    let _ = explorer
        .load_measurement(Path::new(
            "data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt",
        ))
        .expect("load measurement");

    let after_files: Vec<PathBuf> = walkdir_entries(&root);

    for p in &after_files {
        if !before_files.contains(p) {
            let rel = p.strip_prefix(&root).unwrap();
            assert!(
                rel.starts_with(".raw-viewer"),
                "unexpected file created in project tree outside .raw-viewer: {}",
                rel.display()
            );
        }
    }
}

#[test]
fn explorer_measurement_cache_and_invalidation() {
    let root = temp_project("cache-invalidation");

    let dot_rv = root.join(".raw-viewer");
    fs::create_dir_all(&dot_rv).expect("create dot rv");
    fs::write(
        dot_rv.join("config.yaml"),
        "schema_version: 1\ndata_root: data/raw\n",
    )
    .expect("write config");

    let data_dir = root.join("data/raw");
    fs::create_dir_all(&data_dir).expect("create data dir");
    fs::write(data_dir.join("sample.csv"), "Time,Value\n0,1.0\n1,2.0\n").expect("write sample");

    let explorer1 = Explorer::open(&root).expect("open 1");
    let rel = Path::new("data/raw/sample.csv");
    let m1 = explorer1.load_measurement(rel).expect("load 1");
    assert_eq!(m1.row_count(), 2);

    let cache_base = raw_viewer_core::paths::cache_dir(&root).expect("cache dir");
    assert!(cache_base.is_dir(), "cache dir should exist");

    // Invalidate by changing disabled profiles list in config
    fs::write(
        dot_rv.join("config.yaml"),
        "schema_version: 1\ndata_root: data/raw\nprofiles:\n  disabled:\n    - some/profile\n",
    )
    .expect("write modified config");

    let explorer2 = Explorer::open(&root).expect("open 2");
    let m2 = explorer2.load_measurement(rel).expect("load 2");
    assert_eq!(m2.row_count(), 2);

    // Verify cache measurements folder has entries under different fingerprints
    let measurements_dir = cache_base.join("measurements");
    assert!(measurements_dir.is_dir());
    let namespaces: Vec<_> = fs::read_dir(&measurements_dir)
        .expect("read namespaces")
        .flatten()
        .filter(|e| e.path().is_dir())
        .collect();
    assert!(
        namespaces.len() >= 2,
        "changing profile configuration should produce a new cache namespace, found {}",
        namespaces.len()
    );
}

fn walkdir_entries(root: &Path) -> Vec<PathBuf> {
    let mut results = Vec::new();
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                results.push(path);
            } else if path.is_dir() {
                results.extend(walkdir_entries(&path));
            }
        }
    }
    results
}
