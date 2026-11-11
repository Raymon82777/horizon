//! The launcher's helpers for the iOS app (ios/App), linked into it as a static library: building
//! the game's resources from the facts pack, unzipping, and the mod registry's checks. The game
//! itself is a separate framework (`horizon-ios`), loaded only when Play is pressed.

use std::ffi::{CStr, CString, c_char, c_void};
use std::path::Path;

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
