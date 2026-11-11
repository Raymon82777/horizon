//! The game for the iOS app, built as a framework (`HorizonGame.framework`, and one more per
//! instance's set of native mods). The SwiftUI shell (`ios/App`) owns `UIApplicationMain` and the
//! UIScene; pressing Play loads the instance's framework and calls [`horizon_ios_run`] on the
//! main thread, which starts the game the way `horizon-client`'s `main` does. winit's embedded
//! iOS mode (ios/rust/winit) then attaches the game's window to the app's scene and keeps the
//! main run loop turning: it never returns, so one process plays one framework.
//!
//! The launcher's own helpers (resources, unzip, the mod registry's checks) are
//! `horizon-ios-tools`, linked into the app: no game is loaded until Play.

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

/// The game controller Apple's GameController framework calls current connected: `family` 0
/// Xbox, 1 PlayStation, 2 Nintendo, anything else unknown (Xbox glyphs); `name` its name.
///
/// # Safety
/// `name` is a valid NUL-terminated UTF-8 string or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_pad_connected(family: c_int, name: *const c_char) {
    use horizon_client::gamepad::GlyphStyle;
    let style = match family {
        0 => GlyphStyle::Xbox,
        1 => GlyphStyle::PlayStation,
        2 => GlyphStyle::Nintendo,
        _ => GlyphStyle::Auto,
    };
    let name = if name.is_null() {
        String::new()
    } else {
        // SAFETY: the caller passes a valid C string.
        unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned()
    };
    horizon_client::gamepad::platform::connect(style, &name);
}

/// The current controller went away.
#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_pad_disconnected() {
    horizon_client::gamepad::platform::disconnect();
}

/// The current controller's whole state: `buttons` a bit set in `gamepad::Button`'s order
/// (south, east, west, north, LB, RB, LT, RT, select, start, LS, RS, D-pad up, down, left,
/// right), sticks with right and up positive (-1..1), triggers 0..1.
#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_pad_state(
    buttons: u32,
    lx: f32,
    ly: f32,
    rx: f32,
    ry: f32,
    lt: f32,
    rt: f32,
) {
    horizon_client::gamepad::platform::set_state(horizon_client::gamepad::PadState {
        buttons,
        left: [lx, ly],
        right: [rx, ry],
        triggers: [lt, rt],
    });
}
