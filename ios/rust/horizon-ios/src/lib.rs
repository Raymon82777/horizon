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

/// Unpacks the zip archive `archive` into the folder `out` (made if missing), for the
/// launcher's world import: iOS has no public unzip API. Entries that would land outside `out`
/// are refused. Null when done, else an error to free with [`horizon_ios_free_string`].
///
/// # Safety
/// Both paths are valid NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_unzip(
    archive: *const c_char,
    out: *const c_char,
) -> *mut c_char {
    // SAFETY: the caller passes valid C strings.
    let path = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    let (archive, out) = (path(archive), path(out));
    let result = std::fs::File::open(&archive)
        .map_err(|e| format!("{archive}: {e}"))
        .and_then(|file| zip::ZipArchive::new(file).map_err(|e| format!("{archive}: {e}")))
        .and_then(|mut zip| zip.extract(&out).map_err(|e| format!("{archive}: {e}")));
    match result {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => CString::new(e).map_or(std::ptr::null_mut(), CString::into_raw),
    }
}

fn c_path(p: *const c_char) -> String {
    // SAFETY: callers pass valid NUL-terminated strings (see each function's contract).
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn c_result(result: Result<(), String>) -> *mut c_char {
    match result {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => CString::new(e).map_or(std::ptr::null_mut(), CString::into_raw),
    }
}

/// Checks a file downloaded from Horizon's mod registry before it's installed, with the
/// registry's own checks (`horizon_mods::index::check_file`): size, SHA-256, revocation, the
/// author's signature when the project has a key, and that its manifest says what the index
/// says. `index` is the path of the registry's index.json. Null when the file passes, else why
/// not (free it with [`horizon_ios_free_string`]).
///
/// # Safety
/// The four arguments are valid NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_mod_check(
    index: *const c_char,
    id: *const c_char,
    version: *const c_char,
    file: *const c_char,
) -> *mut c_char {
    let (index, id, version, file) = (c_path(index), c_path(id), c_path(version), c_path(file));
    c_result((|| {
        let text = std::fs::read_to_string(&index).map_err(|e| format!("{index}: {e}"))?;
        let index = horizon_mods::index::Index::parse(&text)?;
        let project = index
            .project(&id)
            .ok_or_else(|| format!("{id} isn't in the registry"))?;
        let entry = project
            .versions
            .iter()
            .find(|v| v.version == version)
            .ok_or_else(|| format!("{id} has no version {version}"))?;
        horizon_mods::index::check_file(&index, project, entry, Path::new(&file)).map(|_| ())
    })())
}

/// A content mod's manifest as JSON (`{"id", "name", "version", "description", "authors",
/// "capabilities", "code"}`; `code`: it carries wasm, which iOS can't run), else
/// `{"error": "…"}`. Free the result with [`horizon_ios_free_string`].
///
/// # Safety
/// `file` is a valid NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn horizon_ios_mod_manifest(file: *const c_char) -> *mut c_char {
    let file = c_path(file);
    let json = match horizon_mods::Package::read(Path::new(&file)) {
        Ok(package) => {
            let m = package.manifest;
            serde_json::json!({
                "id": m.id,
                "name": m.name,
                "version": m.version,
                "description": m.description,
                "authors": m.authors,
                "capabilities": m.capabilities.iter().map(|c| format!("{c:?}").to_lowercase()).collect::<Vec<_>>(),
                "code": package.wasm.is_some(),
            })
        }
        Err(e) => serde_json::json!({ "error": e }),
    };
    CString::new(json.to_string()).map_or(std::ptr::null_mut(), CString::into_raw)
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
        c_path(name)
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
