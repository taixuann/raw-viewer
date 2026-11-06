use crate::envelope::CliResult;
use serde_json::json;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

const SHIPPED_SKILLS: &[&str] = &["set-grammar", "set-profile"];

fn find_skill_source(name: &str) -> Option<PathBuf> {
    // 1. Check current directory or ancestors for .agents/skills/<name>
    if let Ok(mut cur) = env::current_dir() {
        loop {
            let candidate = cur.join(".agents").join("skills").join(name);
            if candidate.is_dir() {
                return Some(candidate);
            }
            if !cur.pop() {
                break;
            }
        }
    }

    // 2. Check binary directory
    if let Ok(exe) = env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let candidates = [
                exe_dir.join("../Resources/skills").join(name),
                exe_dir.join("skills").join(name),
                exe_dir.join("../../.agents/skills").join(name),
                exe_dir.join("../share/raw-viewer/skills").join(name),
            ];
            for c in &candidates {
                if c.is_dir() {
                    return Some(c.clone());
                }
            }
        }
    }

    None
}

pub fn manage_skills(action: &str, dry_run: bool) -> CliResult {
    let home = env::var("HOME")
        .or_else(|_| env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".to_string());
    let home_path = Path::new(&home);

    let target_parents = [
        home_path.join(".agents").join("skills"),
        home_path.join(".claude").join("skills"),
    ];

    let mut reports = Vec::new();

    for name in SHIPPED_SKILLS {
        let source_opt = find_skill_source(name);

        for parent in &target_parents {
            let target = parent.join(name);

            // If target is an existing real directory (and NOT a symlink)
            let is_symlink = target.is_symlink();
            let is_real_dir = target.is_dir() && !is_symlink;

            if is_real_dir {
                reports.push(json!({
                    "skill": name,
                    "target": target.display().to_string().replace('\\', "/"),
                    "status": "skipped_real_directory",
                    "message": "target is a real directory, refusing to overwrite or nest link inside it"
                }));
                continue;
            }

            let source = match source_opt {
                Some(ref s) => s.clone(),
                None => {
                    reports.push(json!({
                        "skill": name,
                        "target": target.display().to_string().replace('\\', "/"),
                        "status": "error_source_not_found",
                        "message": format!("shipped skill source for \"{name}\" not found")
                    }));
                    continue;
                }
            };

            let needs_update = if is_symlink {
                // Check if target points to source
                match fs::read_link(&target) {
                    Ok(dest) => dest != source,
                    Err(_) => true, // dangling
                }
            } else {
                true // does not exist yet
            };

            if !needs_update {
                reports.push(json!({
                    "skill": name,
                    "target": target.display().to_string().replace('\\', "/"),
                    "source": source.display().to_string().replace('\\', "/"),
                    "status": "already_linked",
                    "action": "none"
                }));
                continue;
            }

            if dry_run {
                reports.push(json!({
                    "skill": name,
                    "target": target.display().to_string().replace('\\', "/"),
                    "source": source.display().to_string().replace('\\', "/"),
                    "status": if is_symlink { "retarget_needed" } else { "link_needed" },
                    "action": if is_symlink { "retarget (dry-run)" } else { "create_symlink (dry-run)" }
                }));
                continue;
            }

            // Perform link/repair
            if !parent.exists() {
                if let Err(e) = fs::create_dir_all(parent) {
                    reports.push(json!({
                        "skill": name,
                        "target": target.display().to_string().replace('\\', "/"),
                        "status": "error_mkdir",
                        "message": format!("failed to create parent dir: {e}")
                    }));
                    continue;
                }
            }

            if is_symlink {
                if target.is_dir() {
                    let _ = fs::remove_dir(&target);
                } else {
                    let _ = fs::remove_file(&target);
                }
            }

            #[cfg(unix)]
            let link_res = std::os::unix::fs::symlink(&source, &target);

            #[cfg(windows)]
            let link_res = std::os::windows::fs::symlink_dir(&source, &target).or_else(|_| {
                // Fallback to directory junction via cmd mklink /J
                let s_str = source.display().to_string().replace('/', "\\");
                let t_str = target.display().to_string().replace('/', "\\");
                std::process::Command::new("cmd")
                    .args(["/C", "mklink", "/J", &t_str, &s_str])
                    .output()
                    .map_err(|e| std::io::Error::other(e.to_string()))
                    .and_then(|out| {
                        if out.status.success() {
                            Ok(())
                        } else {
                            Err(std::io::Error::other(
                                String::from_utf8_lossy(&out.stderr).to_string(),
                            ))
                        }
                    })
            });

            match link_res {
                Ok(_) => {
                    reports.push(json!({
                        "skill": name,
                        "target": target.display().to_string().replace('\\', "/"),
                        "source": source.display().to_string().replace('\\', "/"),
                        "status": "linked",
                        "action": if is_symlink { "retargeted" } else { "created" }
                    }));
                }
                Err(e) => {
                    reports.push(json!({
                        "skill": name,
                        "target": target.display().to_string().replace('\\', "/"),
                        "status": "error_symlink",
                        "message": format!("failed to create symlink: {e}")
                    }));
                }
            }
        }
    }

    CliResult::ok(json!({
        "action": format!("skills.{action}"),
        "dry_run": dry_run,
        "results": reports,
    }))
}
