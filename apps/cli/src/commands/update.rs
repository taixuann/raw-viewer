use crate::envelope::{CliResult, EXIT_IO};
use serde_json::json;
use std::env;
use std::fs;
use std::process::Command;

const REPO: &str = "taixuann/raw-viewer";

pub fn run(check: bool, json_output: bool) -> CliResult {
    let current_version = env!("CARGO_PKG_VERSION");
    let current_tag = format!("v{}", current_version.trim_start_matches('v'));

    // Fetch latest release metadata from GitHub API using curl
    let output = match Command::new("curl")
        .args([
            "-sSfL",
            "-H",
            "Accept: application/vnd.github.v3+json",
            "-H",
            "User-Agent: raw-viewer-cli",
            &format!("https://api.github.com/repos/{REPO}/releases/latest"),
        ])
        .output()
    {
        Ok(out) if out.status.success() => out,
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            return CliResult {
                exit_code: EXIT_IO,
                output: Err((
                    "io_error".into(),
                    format!("failed to fetch latest release from GitHub: {err}"),
                    json!({}),
                )),
            };
        }
        Err(e) => {
            return CliResult {
                exit_code: EXIT_IO,
                output: Err((
                    "io_error".into(),
                    format!("curl command execution failed: {e}"),
                    json!({}),
                )),
            };
        }
    };

    let release: serde_json::Value = match serde_json::from_slice(&output.stdout) {
        Ok(val) => val,
        Err(e) => {
            return CliResult {
                exit_code: EXIT_IO,
                output: Err((
                    "io_error".into(),
                    format!("failed to parse GitHub release JSON: {e}"),
                    json!({}),
                )),
            };
        }
    };

    let latest_tag = release["tag_name"].as_str().unwrap_or("").to_string();
    let release_url = release["html_url"].as_str().unwrap_or("").to_string();
    let is_newer = is_newer_version(&latest_tag, &current_tag);

    if check {
        if json_output {
            return CliResult::ok(json!({
                "current_version": current_tag,
                "latest_version": latest_tag,
                "update_available": is_newer,
                "release_url": release_url,
            }));
        } else {
            if is_newer {
                println!(
                    "Update available: {current_tag} -> {latest_tag}\nRelease page: {release_url}\nRun 'raw-viewer update' to install."
                );
            } else {
                println!("raw-viewer is up to date ({current_tag}).");
            }
            return CliResult::ok(json!({
                "update_available": is_newer
            }));
        }
    }

    if !is_newer {
        if json_output {
            return CliResult::ok(json!({
                "status": "up_to_date",
                "version": current_tag,
            }));
        } else {
            println!("raw-viewer is already up to date ({current_tag}).");
            return CliResult::ok(json!({ "status": "up_to_date" }));
        }
    }

    let target = get_target_triple();
    let expected_asset = format!("raw-viewer-{target}.tar.gz");
    let fallback_asset = if target.contains("apple-darwin") {
        Some("raw-viewer-universal-apple-darwin.tar.gz".to_string())
    } else {
        None
    };

    let assets = release["assets"].as_array();
    let mut download_url = None;
    if let Some(assets) = assets {
        for a in assets {
            if let Some(name) = a["name"].as_str() {
                if name == expected_asset {
                    download_url = a["browser_download_url"].as_str().map(|s| s.to_string());
                    break;
                }
            }
        }
        if download_url.is_none() {
            if let Some(ref fb) = fallback_asset {
                for a in assets {
                    if let Some(name) = a["name"].as_str() {
                        if name == fb {
                            download_url =
                                a["browser_download_url"].as_str().map(|s| s.to_string());
                            break;
                        }
                    }
                }
            }
        }
    }

    let download_url = match download_url {
        Some(url) => url,
        None => {
            return CliResult {
                exit_code: EXIT_IO,
                output: Err((
                    "not_found".into(),
                    format!("no matching release asset found for target {target}"),
                    json!({ "latest_tag": latest_tag, "target": target }),
                )),
            };
        }
    };

    let current_exe = match env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            return CliResult {
                exit_code: EXIT_IO,
                output: Err((
                    "io_error".into(),
                    format!("failed to determine current executable path: {e}"),
                    json!({}),
                )),
            };
        }
    };

    if !json_output {
        println!("Downloading {latest_tag} for {target}...");
    }

    let tmp_dir = env::temp_dir().join(format!("raw-viewer-update-{}", std::process::id()));
    if let Err(e) = fs::create_dir_all(&tmp_dir) {
        return CliResult {
            exit_code: EXIT_IO,
            output: Err((
                "io_error".into(),
                format!("failed to create temporary download directory: {e}"),
                json!({}),
            )),
        };
    }

    let tar_file = tmp_dir.join("archive.tar.gz");
    let curl_status = Command::new("curl")
        .args(["-sSfL", "-o", tar_file.to_str().unwrap(), &download_url])
        .status();

    if !curl_status.map(|s| s.success()).unwrap_or(false) {
        let _ = fs::remove_dir_all(&tmp_dir);
        return CliResult {
            exit_code: EXIT_IO,
            output: Err((
                "io_error".into(),
                format!("failed to download release archive from {download_url}"),
                json!({}),
            )),
        };
    }

    let tar_status = Command::new("tar")
        .args([
            "-xzf",
            tar_file.to_str().unwrap(),
            "-C",
            tmp_dir.to_str().unwrap(),
        ])
        .status();

    if !tar_status.map(|s| s.success()).unwrap_or(false) {
        let _ = fs::remove_dir_all(&tmp_dir);
        return CliResult {
            exit_code: EXIT_IO,
            output: Err((
                "io_error".into(),
                "failed to unpack release archive".into(),
                json!({}),
            )),
        };
    }

    let new_binary = tmp_dir.join("raw-viewer");
    if !new_binary.exists() {
        let _ = fs::remove_dir_all(&tmp_dir);
        return CliResult {
            exit_code: EXIT_IO,
            output: Err((
                "not_found".into(),
                "extracted archive did not contain raw-viewer binary".into(),
                json!({}),
            )),
        };
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&new_binary, fs::Permissions::from_mode(0o755));
    }

    let staging = current_exe.with_extension("tmp-update");
    if let Err(e) = fs::copy(&new_binary, &staging) {
        let _ = fs::remove_dir_all(&tmp_dir);
        return CliResult {
            exit_code: EXIT_IO,
            output: Err((
                "io_error".into(),
                format!("failed to stage updated binary: {e}"),
                json!({}),
            )),
        };
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&staging, fs::Permissions::from_mode(0o755));
    }

    if let Err(e) = fs::rename(&staging, &current_exe) {
        if let Err(copy_err) = fs::copy(&staging, &current_exe) {
            let _ = fs::remove_file(&staging);
            let _ = fs::remove_dir_all(&tmp_dir);
            return CliResult {
                exit_code: EXIT_IO,
                output: Err((
                    "io_error".into(),
                    format!(
                        "failed to replace binary at {}: {e} / {copy_err}",
                        current_exe.display()
                    ),
                    json!({}),
                )),
            };
        }
        let _ = fs::remove_file(&staging);
    }

    let _ = fs::remove_dir_all(&tmp_dir);

    if json_output {
        CliResult::ok(json!({
            "status": "updated",
            "previous_version": current_tag,
            "current_version": latest_tag,
            "path": current_exe.display().to_string(),
        }))
    } else {
        println!(
            "Successfully updated raw-viewer from {current_tag} to {latest_tag} at {}!",
            current_exe.display()
        );
        CliResult::ok(json!({
            "status": "updated",
            "version": latest_tag,
        }))
    }
}

pub fn parse_version(s: &str) -> (u64, u64, u64) {
    let clean = s.trim().trim_start_matches('v');
    let mut parts = clean.split('.');
    let major = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    let minor = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    let patch = parts
        .next()
        .and_then(|p| p.split('-').next().unwrap_or("0").parse().ok())
        .unwrap_or(0);
    (major, minor, patch)
}

pub fn is_newer_version(latest: &str, current: &str) -> bool {
    let l = parse_version(latest);
    let c = parse_version(current);
    l > c
}

fn get_target_triple() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "aarch64-apple-darwin"
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        "x86_64-apple-darwin"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        "x86_64-unknown-linux-gnu"
    }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        "x86_64-pc-windows-msvc"
    }
    #[cfg(not(any(
        all(
            target_os = "macos",
            any(target_arch = "aarch64", target_arch = "x86_64")
        ),
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "windows", target_arch = "x86_64")
    )))]
    {
        "unknown"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_parsing_and_comparison() {
        assert!(is_newer_version("v0.2.0", "v0.1.0"));
        assert!(is_newer_version("0.2.1", "0.2.0"));
        assert!(is_newer_version("v1.0.0", "v0.9.9"));
        assert!(!is_newer_version("v0.1.0", "v0.2.0"));
        assert!(!is_newer_version("v0.2.0", "v0.2.0"));
    }
}
