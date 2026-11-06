// Prevents an extra console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use raw_viewer_core::explorer::{
    Explorer, InspectionReport, InventoryReport, MatchOutcome, ProfileSummary, ProjectSummary,
};
use std::path::Path;

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            core_status,
            open_project,
            inventory,
            list_profiles,
            match_file,
            inspect,
            load_measurement
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// Returns the placeholder core identity for the shell to display.
#[tauri::command]
fn core_status() -> String {
    raw_viewer_core::core_placeholder().to_string()
}

#[tauri::command]
fn open_project(root: String) -> Result<ProjectSummary, String> {
    let explorer = Explorer::open(Path::new(&root)).map_err(|e| e.to_string())?;
    Ok(explorer.summary())
}

#[tauri::command]
fn inventory(root: String) -> Result<InventoryReport, String> {
    let explorer = Explorer::open(Path::new(&root)).map_err(|e| e.to_string())?;
    explorer.inventory().map_err(|e| e.to_string())
}

#[tauri::command]
fn list_profiles(root: String) -> Result<Vec<ProfileSummary>, String> {
    let explorer = Explorer::open(Path::new(&root)).map_err(|e| e.to_string())?;
    Ok(explorer.list_profiles())
}

#[tauri::command]
fn match_file(root: String, relative_path: String) -> Result<MatchOutcome, String> {
    let explorer = Explorer::open(Path::new(&root)).map_err(|e| e.to_string())?;
    explorer
        .match_file(Path::new(&relative_path))
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn inspect(root: String, relative_path: String) -> Result<InspectionReport, String> {
    let explorer = Explorer::open(Path::new(&root)).map_err(|e| e.to_string())?;
    explorer
        .inspect(Path::new(&relative_path))
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn load_measurement(root: String, relative_path: String) -> Result<serde_json::Value, String> {
    let explorer = Explorer::open(Path::new(&root)).map_err(|e| e.to_string())?;
    let measurement = explorer
        .load_measurement(Path::new(&relative_path))
        .map_err(|e| e.to_string())?;
    Ok(measurement.to_golden_json())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tauri_inventory_and_inspect_match_fixture_values() {
        let fixture_root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../fixtures/workspaces/usth-lab");
        let root_str = fixture_root.display().to_string();

        let inv = inventory(root_str.clone()).expect("inventory");
        assert_eq!(inv.total_files, 7);

        let keithley_path = "data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt";
        let report = inspect(root_str, keithley_path.to_string()).expect("inspect");
        assert_eq!(report.profile_id, "usth/keithley-2400");
        assert_eq!(report.variant, "dual-sweep");
        assert_eq!(report.data_row_count, 121);
        assert_eq!(
            report.tokens.get("device").map(String::as_str),
            Some("keithley-2400")
        );
        assert_eq!(
            report.tokens.get("application-mode").map(String::as_str),
            Some("dual-sweep")
        );
    }
}
