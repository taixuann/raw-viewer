// Prevents an extra console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![core_status])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// Returns the placeholder core identity for the shell to display.
#[tauri::command]
fn core_status() -> String {
    raw_viewer_core::core_placeholder().to_string()
}
