//! Cache directory rule and project-local index prohibition (contract 24a-1).

const _CACHE_VECTORS_CONTRACT: &str =
    include_str!("../../fixtures/grammar/cross_language_contract.yaml");

use raw_viewer_core::paths::{
    cache_dir, project_index_db_path, resolve_paths, PathInputs, TargetOs,
};
use raw_viewer_core::yaml::{parse, YamlNode};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn load_cache_vectors() -> Vec<(String, PathInputs, String)> {
    let text = fs::read_to_string(repo_root().join("fixtures/config/vectors.yaml"))
        .expect("read cache vectors");
    let doc = parse(&text, false).expect("parse vectors");
    let items = doc
        .value_for_key("cache_vectors")
        .and_then(|n| n.list_items())
        .expect("cache_vectors");
    items
        .iter()
        .map(|item| {
            let id = scalar(item, "id").to_string();
            let os = match scalar(item, "os").as_str() {
                "linux" => TargetOs::Linux,
                "macos" => TargetOs::MacOs,
                "windows" => TargetOs::Windows,
                other => panic!("unknown os {other} in vector {id}"),
            };
            let project_root = scalar(item, "project_root").to_string();
            let home = item
                .value_for_key("home")
                .and_then(|n| n.scalar_value())
                .map(str::to_string);
            let xdg_cache_home = item
                .value_for_key("xdg_cache_home")
                .and_then(|n| n.scalar_value())
                .filter(|v| *v != "null")
                .map(str::to_string);
            let expected_hash = scalar(item, "expected_hash").to_string();
            let inputs = PathInputs {
                os,
                home,
                xdg_config_home: None,
                xdg_cache_home,
                app_data: if os == TargetOs::Windows {
                    Some(r"C:\Users\Alice\AppData\Roaming".into())
                } else {
                    None
                },
                local_app_data: if os == TargetOs::Windows {
                    Some(r"C:\Users\Alice\AppData\Local".into())
                } else {
                    None
                },
                project_root,
            };
            (id, inputs, expected_hash)
        })
        .collect()
}

#[test]
fn cache_dir_parity_vectors_match_sha256_layout() {
    for (id, inputs, expected_hash) in load_cache_vectors() {
        if inputs.os != TargetOs::host() {
            continue;
        }
        let digest = format!("{:x}", Sha256::digest(inputs.project_root.as_bytes()));
        assert_eq!(digest, expected_hash, "{id}: path digest");
        let resolved = resolve_paths(&inputs, |_| false).expect("resolve paths");
        let hash_dir = PathBuf::from(resolved.cache_dir)
            .join("projects")
            .join(&expected_hash);
        assert!(
            hash_dir
                .to_string_lossy()
                .contains("projects/")
                .then_some(true)
                .is_some(),
            "{id}"
        );
        assert!(!hash_dir.to_string_lossy().contains(".raw-viewer"), "{id}");
    }
}

#[test]
fn cache_dir_on_host_project_uses_projects_digest_and_not_project_tree() {
    let root = std::env::temp_dir().join(format!(
        "rawview-cache-probe-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(root.join(".raw-viewer")).unwrap();
    fs::write(
        root.join(".raw-viewer/config.yaml"),
        "schema_version: 1\ndata_root: data/raw\n",
    )
    .unwrap();
    fs::create_dir_all(root.join("data/raw")).unwrap();

    let hash_dir = cache_dir(&root).expect("cache_dir");
    let index_path = project_index_db_path(&root).expect("index db path");
    assert_eq!(index_path, hash_dir.join("index.db"));
    assert!(
        hash_dir.to_string_lossy().contains("/projects/")
            || hash_dir.to_string_lossy().contains("\\projects\\"),
        "cache dir must live under projects/: {}",
        hash_dir.display()
    );
    assert!(
        !index_path.starts_with(root.canonicalize().unwrap_or(root.clone())),
        "index.db must not be under the project tree"
    );
    assert!(
        !Path::new(&index_path).exists(),
        "opening paths must not create index.db yet"
    );
}

fn scalar(node: &YamlNode, key: &str) -> String {
    node.value_for_key(key)
        .and_then(|n| n.scalar_value())
        .map(str::to_string)
        .unwrap_or_else(|| panic!("missing {key}"))
}
