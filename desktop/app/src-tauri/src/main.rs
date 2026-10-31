// The Slime OS desktop app's shell: one window showing ../ui, which starts
// the Go core (desktop/core, bundled as a sidecar) and drives it over
// stdin/stdout. Everything else lives in the core.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .run(tauri::generate_context!())
        .expect("error while running Slime OS");
}
