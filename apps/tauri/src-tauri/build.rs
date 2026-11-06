fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "core_status",
            "open_project",
            "inventory",
            "list_profiles",
            "match_file",
            "inspect",
            "load_measurement",
        ]),
    ))
    .expect("failed to run tauri-build");
}
