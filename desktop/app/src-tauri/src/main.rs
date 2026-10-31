// The Slime OS desktop app's shell: one window showing ../ui, which starts
// the Go core (desktop/core, bundled as a sidecar) and drives it over
// stdin/stdout. Everything else lives in the core.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri_plugin_window_state::StateFlags;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        // Opens full screen (or maximized) if it was left that way. Not the
        // size: the plugin would save the full-screen size as the window's.
        .plugin(
            tauri_plugin_window_state::Builder::new()
                .with_state_flags(StateFlags::FULLSCREEN | StateFlags::MAXIMIZED)
                .build(),
        )
        .run(tauri::generate_context!())
        .expect("error while running Slime OS");
}
