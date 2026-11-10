//! The game for the iOS app. The SwiftUI shell (`ios/App`) owns `UIApplicationMain` and the
//! UIScene; pressing Play calls [`horizon_ios_run`] on the main thread, which starts the game the
//! way `horizon-client`'s `main` does. winit's embedded iOS mode (third_party/winit) then attaches
//! the game's window to the app's scene and keeps the main run loop turning: it never returns.

use std::ffi::{CStr, c_char, c_int};

#[global_allocator]
static ALLOCATOR: horizon_threads::Allocator = horizon_threads::ALLOCATOR;

/// The mod API level this build serves (`horizon_mods::api_level::MARK`), kept like the
/// executable keeps it.
static MOD_API_LEVEL: [u8; 27] = horizon_mods::api_level::MARK;

/// Starts the game with `argc` arguments (no program name), on the main thread. Never returns.
///
/// # Safety
/// `argv` points to `argc` valid NUL-terminated strings, and this is called once, on the main
/// thread, from a running UIKit application.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_run(argc: c_int, argv: *const *const c_char) -> ! {
    std::hint::black_box(&MOD_API_LEVEL);
    let count = usize::try_from(argc).unwrap_or(0);
    let args = (0..count)
        .map(|i| {
            // SAFETY: the caller passes `argc` valid C strings.
            unsafe { CStr::from_ptr(*argv.add(i)) }
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    horizon_client::entry::set_args(args);
    horizon_client::entry::main();
    // winit's embedded loop doesn't return; if the game ever stops before it, end like an app.
    std::process::exit(0)
}
