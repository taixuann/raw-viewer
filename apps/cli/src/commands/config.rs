use crate::envelope::CliResult;
use raw_viewer_core::config::project_config_file;
use raw_viewer_core::paths;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};

fn get_config_path(global: bool, project: Option<&Path>) -> Result<PathBuf, CliResult> {
    if global {
        let dummy = Path::new("/dummy");
        let resolved = paths::resolve_paths_from_env(dummy).map_err(|e| {
            CliResult::io(format!("failed to resolve global config directory: {e}"))
        })?;
        Ok(Path::new(&resolved.global_config_dir).join("config.yaml"))
    } else if let Some(p) = project {
        if !p.exists() {
            return Err(CliResult::not_found(format!(
                "project path does not exist: {}",
                p.display().to_string().replace('\\', "/")
            )));
        }
        Ok(project_config_file(p))
    } else {
        Err(CliResult::validation(
            "must specify either --global or --project <PATH>",
        ))
    }
}

pub fn get(global: bool, project: Option<&Path>) -> CliResult {
    let path = match get_config_path(global, project) {
        Ok(p) => p,
        Err(res) => return res,
    };

    if !path.exists() {
        return CliResult::not_found(format!(
            "config file does not exist: {}",
            path.display().to_string().replace('\\', "/")
        ));
    }

    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => return CliResult::io(format!("failed to read config file: {e}")),
    };

    let yaml_val: serde_yaml::Value = match serde_yaml::from_str(&text) {
        Ok(v) => v,
        Err(e) => return CliResult::validation(format!("malformed YAML in config: {e}")),
    };

    let json_val = serde_json::to_value(yaml_val).unwrap_or(json!({}));
    CliResult::ok(json!({
        "path": path.display().to_string().replace('\\', "/"),
        "config": json_val
    }))
}

pub fn set(
    global: bool,
    project: Option<&Path>,
    key: &str,
    value: &str,
    dry_run: bool,
) -> CliResult {
    let path = match get_config_path(global, project) {
        Ok(p) => p,
        Err(res) => return res,
    };

    let mut yaml_val: serde_yaml::Value = if path.exists() {
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => return CliResult::io(format!("failed to read config file: {e}")),
        };
        serde_yaml::from_str(&text)
            .unwrap_or_else(|_| serde_yaml::Value::Mapping(Default::default()))
    } else {
        serde_yaml::Value::Mapping(Default::default())
    };

    let map = match yaml_val {
        serde_yaml::Value::Mapping(ref mut m) => m,
        _ => {
            return CliResult::validation("root of config YAML is not a mapping");
        }
    };

    // Ensure schema_version: 1
    let schema_key = serde_yaml::Value::String("schema_version".to_string());
    if !map.contains_key(&schema_key) {
        map.insert(schema_key, serde_yaml::Value::Number(1.into()));
    }

    if key == "profiles.enabled" {
        let profiles_key = serde_yaml::Value::String("profiles".to_string());
        let profiles_map = map
            .entry(profiles_key)
            .or_insert_with(|| serde_yaml::Value::Mapping(Default::default()));
        if let serde_yaml::Value::Mapping(ref mut pm) = profiles_map {
            let enabled_key = serde_yaml::Value::String("enabled".to_string());
            let list: Vec<serde_yaml::Value> = value
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| serde_yaml::Value::String(s.to_string()))
                .collect();
            pm.insert(enabled_key, serde_yaml::Value::Sequence(list));
        }
    } else if key == "profiles.disabled" {
        let profiles_key = serde_yaml::Value::String("profiles".to_string());
        let profiles_map = map
            .entry(profiles_key)
            .or_insert_with(|| serde_yaml::Value::Mapping(Default::default()));
        if let serde_yaml::Value::Mapping(ref mut pm) = profiles_map {
            let disabled_key = serde_yaml::Value::String("disabled".to_string());
            let list: Vec<serde_yaml::Value> = value
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| serde_yaml::Value::String(s.to_string()))
                .collect();
            pm.insert(disabled_key, serde_yaml::Value::Sequence(list));
        }
    } else {
        let k = serde_yaml::Value::String(key.to_string());
        map.insert(k, serde_yaml::Value::String(value.to_string()));
    }

    if dry_run {
        let json_val = serde_json::to_value(&yaml_val).unwrap_or(json!({}));
        return CliResult::ok(json!({
            "action": "set",
            "dry_run": true,
            "key": key,
            "value": value,
            "target_path": path.display().to_string().replace('\\', "/"),
            "planned_config": json_val
        }));
    }

    if let Some(parent) = path.parent() {
        if !parent.exists() {
            if let Err(e) = fs::create_dir_all(parent) {
                return CliResult::io(format!(
                    "failed to create directory {}: {}",
                    parent.display(),
                    e
                ));
            }
        }
    }

    let out_str = match serde_yaml::to_string(&yaml_val) {
        Ok(s) => s,
        Err(e) => return CliResult::validation(format!("failed to serialize YAML: {e}")),
    };

    if let Err(e) = fs::write(&path, out_str) {
        return CliResult::io(format!(
            "failed to write config to {}: {}",
            path.display(),
            e
        ));
    }

    CliResult::ok(json!({
        "action": "set",
        "dry_run": false,
        "key": key,
        "value": value,
        "target_path": path.display().to_string().replace('\\', "/")
    }))
}
