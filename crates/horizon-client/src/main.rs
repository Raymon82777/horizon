//! Horizon: native Rust client for Minecraft Java Edition 26.3 gameplay.
#![forbid(unsafe_code)]

#[cfg(not(any(feature = "system-allocator", feature = "alloc-census")))]
#[global_allocator]
static ALLOCATOR: horizon_threads::Allocator = horizon_threads::ALLOCATOR;
#[cfg(all(feature = "alloc-census", not(feature = "system-allocator")))]
#[global_allocator]
static ALLOCATOR: horizon_threads::CensusAllocator = horizon_threads::CensusAllocator;

/// The mod API level this game serves, kept in the program for the launcher
/// to read without running it (`horizon_mods::api_level::MARK`). `main`
/// reads it, so the linker keeps it.
static MOD_API_LEVEL: [u8; 27] = horizon_mods::api_level::MARK;

fn main() {
    std::hint::black_box(&MOD_API_LEVEL);
    // iOS starts apps in `/`, outside the sandbox: work in the app's Documents folder (Files
    // app visible), so relative `--resources`, `--game-dir` and `--home` land there.
    #[cfg(target_os = "ios")]
    if let Some(home) = std::env::var_os("HOME") {
        let docs = std::path::Path::new(&home).join("Documents");
        let _ = std::fs::create_dir_all(&docs);
        let _ = std::env::set_current_dir(&docs);
    }
    horizon_client::entry::main();
}
