fn main() {
    ensure_sidecar_placeholder();
    tauri_build::build()
}

/// tauri-build requires every externalBin to exist for the host triple at
/// compile time. On macOS the real apple-ai-helper is compiled first by
/// `pnpm run build:helper`; for bare `cargo check`/`cargo build` and
/// non-macOS platforms, drop in an empty placeholder so the build works.
fn ensure_sidecar_placeholder() {
    let triple = std::env::var("TARGET").unwrap_or_default();
    if triple.is_empty() {
        return;
    }
    let dir = std::path::Path::new("binaries");
    let path = dir.join(format!("apple-ai-helper-{}", triple));
    if path.exists() {
        return;
    }
    let _ = std::fs::create_dir_all(dir);
    let _ = std::fs::write(&path, b"");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755));
    }
}
