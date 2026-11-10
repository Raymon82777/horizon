//! The game for the iOS app. The SwiftUI shell (`ios/App`) owns `UIApplicationMain` and the
//! UIScene; pressing Play calls [`horizon_ios_run`] on the main thread, which starts the game the
//! way `horizon-client`'s `main` does. winit's embedded iOS mode (ios/rust/winit) then attaches
//! the game's window to the app's scene and keeps the main run loop turning: it never returns.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::Path;

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

/// Progress of [`horizon_ios_assemble`]: (files done, files in all, the caller's context).
pub type AssembleProgress = extern "C" fn(usize, usize, *mut c_void);

/// Builds the prepared resources in `out` from the facts pack, the player's client jar and asset
/// store (`horizon_facts::assemble`), on the calling thread. Returns null when done, else
/// an error message the caller frees with [`horizon_ios_free_string`].
///
/// # Safety
/// The four paths are valid NUL-terminated UTF-8 strings; `progress` may be called from this
/// thread with `context` until this returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_assemble(
    facts: *const c_char,
    client_jar: *const c_char,
    assets: *const c_char,
    out: *const c_char,
    progress: Option<AssembleProgress>,
    context: *mut c_void,
) -> *mut c_char {
    // SAFETY: the caller passes valid C strings.
    let path = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    let (facts, client_jar, assets, out) = (path(facts), path(client_jar), path(assets), path(out));
    let sources = horizon_facts::Sources {
        facts: Path::new(&facts),
        client_jar: Path::new(&client_jar),
        assets: Path::new(&assets),
    };
    let report = |done: usize, total: usize| {
        // Every 64 files and the last: the UI needs no more.
        if let Some(progress) = progress
            && (done % 64 == 0 || done == total)
        {
            progress(done, total, context);
        }
    };
    match horizon_facts::assemble(&sources, Path::new(&out), &report) {
        Ok(_) => std::ptr::null_mut(),
        Err(e) => CString::new(e).map_or(std::ptr::null_mut(), CString::into_raw),
    }
}

/// Frees a string [`horizon_ios_assemble`] returned.
///
/// # Safety
/// `text` came from this library and isn't used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_free_string(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: made by CString::into_raw above.
        drop(unsafe { CString::from_raw(text) });
    }
}
