//! Resources without Java on the player's machine (#1750's design).
//!
//! [`pack_facts`] runs where Java is (once per version): it walks a fully prepared resources
//! folder and sorts every file into a copy of a client-jar member, a copy of an asset-store
//! object, or a table Horizon computed (the data generator's reports, the exporters' output and
//! the Rust steps' derived files). Only the computed files go into the facts pack, beside a
//! manifest naming every file of the tree with its source and SHA-256.
//!
//! [`assemble`] runs on the player's machine (the iOS app): it rebuilds that exact tree from the
//! facts pack, the player's own client jar and the player's own asset store, checking every
//! file's SHA-256, so the result is the folder a full preparation would have written.

use horizon_prepare::pyjson::{self, Value};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

type Zip = zip::ZipArchive<fs::File>;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn open_zip(path: &Path) -> Result<Zip, String> {
    let file = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    zip::ZipArchive::new(file).map_err(|e| format!("{}: {e}", path.display()))
}

fn zip_bytes(archive: &mut Zip, name: &str) -> Result<Vec<u8>, String> {
    let mut entry = archive.by_name(name).map_err(|e| format!("{name}: {e}"))?;
    let mut data = Vec::with_capacity(entry.size() as usize);
    entry
        .read_to_end(&mut data)
        .map_err(|e| format!("{name}: {e}"))?;
    Ok(data)
}

fn zip_text(archive: &mut Zip, name: &str) -> Result<String, String> {
    String::from_utf8(zip_bytes(archive, name)?).map_err(|e| format!("{name}: {e}"))
}

/// The manifest's format; [`assemble`] refuses another.
pub const FORMAT: i64 = 1;
const MANIFEST: &str = "manifest.json";
const FACTS_DIR: &str = "facts/";
/// Written last by [`assemble`]: until it is there, the folder is not a finished preparation.
const STAMP: &str = "horizon-prepare.json";

/// Kept out of a pack: the exporters' compiled classes and logs, and the preparation lock.
fn skipped(relative: &str) -> bool {
    relative.starts_with("classes/")
        || relative.starts_with("client-classes/")
        || relative.ends_with(".log")
        || relative.ends_with(".horizon-prepare.lock")
}

fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

fn sha1_hex(data: &[u8]) -> String {
    hex(&Sha1::digest(data))
}

fn relative_to(root: &Path, path: &Path) -> Result<String, String> {
    Ok(path
        .strip_prefix(root)
        .map_err(|e| e.to_string())?
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/"))
}

/// The files under `root` and its empty folders (both relative, sorted), without [`skipped`].
fn files_under(root: &Path) -> Result<(Vec<String>, Vec<String>), String> {
    let mut out = Vec::new();
    let mut empty = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries: Vec<_> = fs::read_dir(&dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .collect();
        if entries.is_empty() && dir != root {
            let relative = relative_to(root, &dir)?;
            if !skipped(&format!("{relative}/")) {
                empty.push(relative);
            }
        }
        for entry in entries {
            let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
            let path = entry.path();
            let kind = entry
                .file_type()
                .map_err(|e| format!("{}: {e}", path.display()))?;
            if kind.is_dir() {
                stack.push(path);
            } else if kind.is_file() {
                let relative = relative_to(root, &path)?;
                if !skipped(&relative) {
                    out.push(relative);
                }
            }
        }
    }
    out.sort();
    empty.sort();
    Ok((out, empty))
}

/// The asset index `id` (`indexes/<id>.json`): object hash by name.
fn asset_objects(assets: &Path, index: &str) -> Result<(Vec<u8>, HashSet<String>), String> {
    let path = assets.join("indexes").join(format!("{index}.json"));
    let bytes = fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let text = String::from_utf8(bytes.clone()).map_err(|e| format!("{}: {e}", path.display()))?;
    let json = pyjson::loads(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let objects = json
        .get("objects")
        .and_then(Value::as_object)
        .ok_or_else(|| format!("{}: no objects", path.display()))?;
    let hashes = objects
        .iter()
        .filter_map(|(_, o)| o.get("hash").and_then(Value::as_str).map(str::to_owned))
        .collect();
    Ok((bytes, hashes))
}

fn object_path(assets: &Path, hash: &str) -> PathBuf {
    assets.join("objects").join(&hash[..2]).join(hash)
}

/// What [`pack_facts`] found.
#[derive(Debug, Default)]
pub struct PackSummary {
    pub files: usize,
    pub from_jar: usize,
    pub from_assets: usize,
    pub facts: usize,
    pub facts_bytes: u64,
}

/// Packs the computed files of `resources` (a finished preparation from `client_jar` and the
/// asset store `assets` with index `asset_index`) into `out`, with the manifest.
pub fn pack_facts(
    resources: &Path,
    client_jar: &Path,
    assets: &Path,
    asset_index: &str,
    version: &str,
    out: &Path,
) -> Result<PackSummary, String> {
    if !resources.join(STAMP).exists() {
        return Err(format!(
            "{}: not a finished preparation (no {STAMP})",
            resources.display()
        ));
    }
    let jar_bytes = fs::read(client_jar).map_err(|e| format!("{}: {e}", client_jar.display()))?;
    let jar_sha1 = sha1_hex(&jar_bytes);
    drop(jar_bytes);
    // Every client-jar member by its SHA-256 (the first name wins; a file at the same path is
    // matched to its own member below).
    let mut jar = open_zip(client_jar)?;
    let mut members: HashMap<String, String> = HashMap::new();
    let mut member_names: HashSet<String> = HashSet::new();
    for i in 0..jar.len() {
        let mut entry = jar.by_index(i).map_err(|e| e.to_string())?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().map_err(|e| e.to_string())?.into_owned();
        let mut data = Vec::with_capacity(entry.size() as usize);
        entry
            .read_to_end(&mut data)
            .map_err(|e| format!("{name}: {e}"))?;
        members
            .entry(sha256_hex(&data))
            .or_insert_with(|| name.clone());
        member_names.insert(name);
    }
    let (index_bytes, objects) = asset_objects(assets, asset_index)?;

    let file = fs::File::create(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .last_modified_time(zip::DateTime::default());
    let mut summary = PackSummary::default();
    let mut entries = Vec::new();
    let (files, empty_dirs) = files_under(resources)?;
    for relative in files {
        let data = fs::read(resources.join(&relative)).map_err(|e| format!("{relative}: {e}"))?;
        let sha256 = sha256_hex(&data);
        let mut entry = Value::Object(Vec::new());
        entry.insert("path", Value::str(relative.as_str()));
        entry.insert("sha256", Value::str(sha256.as_str()));
        entry.insert("size", Value::Int(data.len().to_string()));
        let same_path = member_names.contains(&relative)
            && members.get(&sha256).is_some_and(|m| m == &relative);
        if let Some(member) = same_path
            .then_some(&relative)
            .or_else(|| members.get(&sha256))
        {
            entry.insert("from", Value::str("jar"));
            entry.insert("member", Value::str(member.as_str()));
            summary.from_jar += 1;
        } else if objects.contains(&sha1_hex(&data)) {
            entry.insert("from", Value::str("asset"));
            entry.insert("hash", Value::str(sha1_hex(&data)));
            summary.from_assets += 1;
        } else {
            entry.insert("from", Value::str("facts"));
            zip.start_file(format!("{FACTS_DIR}{relative}"), options)
                .map_err(|e| e.to_string())?;
            zip.write_all(&data).map_err(|e| e.to_string())?;
            summary.facts += 1;
            summary.facts_bytes += data.len() as u64;
        }
        summary.files += 1;
        entries.push(entry);
    }
    let mut manifest = Value::Object(Vec::new());
    manifest.insert("format", Value::Int(FORMAT.to_string()));
    manifest.insert("version", Value::str(version));
    manifest.insert("client_jar_sha1", Value::str(jar_sha1));
    manifest.insert("asset_index", Value::str(asset_index));
    manifest.insert("asset_index_sha1", Value::str(sha1_hex(&index_bytes)));
    manifest.insert("files", Value::Array(entries));
    manifest.insert(
        "empty_dirs",
        Value::Array(empty_dirs.into_iter().map(Value::str).collect()),
    );
    zip.start_file(MANIFEST, options)
        .map_err(|e| e.to_string())?;
    zip.write_all(pyjson::dumps(&manifest, &pyjson::INDENT2).as_bytes())
        .map_err(|e| e.to_string())?;
    zip.finish().map_err(|e| e.to_string())?;
    Ok(summary)
}

/// The player's own files and the facts pack [`assemble`] builds from.
pub struct Sources<'a> {
    pub facts: &'a Path,
    pub client_jar: &'a Path,
    /// The asset store: `indexes/` and `objects/`.
    pub assets: &'a Path,
}

/// Rebuilds the prepared resources into `out` from `sources`, checking every file. `progress`
/// hears (files done, files in all). An earlier, unfinished `out` is replaced.
pub fn assemble(
    sources: &Sources,
    out: &Path,
    progress: &dyn Fn(usize, usize),
) -> Result<usize, String> {
    let mut pack = open_zip(sources.facts)?;
    let manifest = zip_text(&mut pack, MANIFEST)?;
    let manifest = pyjson::loads(&manifest).map_err(|e| format!("{MANIFEST}: {e}"))?;
    if manifest.get("format").and_then(Value::as_i64) != Some(FORMAT) {
        return Err(format!(
            "{}: not a format {FORMAT} facts pack",
            sources.facts.display()
        ));
    }
    let field = |key: &str| {
        manifest
            .get(key)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("{MANIFEST}: no {key}"))
    };
    let jar_bytes = fs::read(sources.client_jar)
        .map_err(|e| format!("{}: {e}", sources.client_jar.display()))?;
    if sha1_hex(&jar_bytes) != field("client_jar_sha1")? {
        return Err(format!(
            "{}: not the client jar this facts pack is for ({})",
            sources.client_jar.display(),
            field("version")?
        ));
    }
    drop(jar_bytes);
    let index = field("asset_index")?;
    let index_path = sources.assets.join("indexes").join(format!("{index}.json"));
    let index_bytes =
        fs::read(&index_path).map_err(|e| format!("{}: {e}", index_path.display()))?;
    if sha1_hex(&index_bytes) != field("asset_index_sha1")? {
        return Err(format!(
            "{}: not the pinned asset index",
            index_path.display()
        ));
    }
    let files = manifest
        .get("files")
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{MANIFEST}: no files"))?;

    // Into a sibling folder first, moved into place once complete.
    let partial = out.with_extension("assembling");
    if partial.exists() {
        fs::remove_dir_all(&partial).map_err(|e| format!("{}: {e}", partial.display()))?;
    }
    let mut jar = open_zip(sources.client_jar)?;
    let total = files.len();
    let mut stamp = None;
    for (done, entry) in files.iter().enumerate() {
        let get = |key: &str| {
            entry
                .get(key)
                .and_then(Value::as_str)
                .ok_or_else(|| format!("{MANIFEST}: a file without {key}"))
        };
        let relative = get("path")?;
        if relative.split('/').any(|c| c == ".." || c.is_empty()) || relative.starts_with('/') {
            return Err(format!("{MANIFEST}: refused path {relative}"));
        }
        let data = match get("from")? {
            "jar" => zip_bytes(&mut jar, get("member")?)?,
            "asset" => {
                let hash = get("hash")?;
                let path = object_path(sources.assets, hash);
                fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?
            }
            "facts" => zip_bytes(&mut pack, &format!("{FACTS_DIR}{relative}"))?,
            other => return Err(format!("{MANIFEST}: unknown source {other}")),
        };
        if sha256_hex(&data) != get("sha256")? {
            return Err(format!("{relative}: its SHA-256 isn't the pinned one"));
        }
        if relative == STAMP {
            stamp = Some(data);
        } else {
            let target = partial.join(relative);
            fs::create_dir_all(target.parent().unwrap())
                .map_err(|e| format!("{}: {e}", target.display()))?;
            fs::write(&target, &data).map_err(|e| format!("{}: {e}", target.display()))?;
        }
        progress(done + 1, total);
    }
    for dir in manifest
        .get("empty_dirs")
        .and_then(Value::as_array)
        .unwrap_or(&[])
    {
        let dir = dir
            .as_str()
            .ok_or_else(|| format!("{MANIFEST}: a folder that isn't text"))?;
        if dir.split('/').any(|c| c == ".." || c.is_empty()) || dir.starts_with('/') {
            return Err(format!("{MANIFEST}: refused folder {dir}"));
        }
        fs::create_dir_all(partial.join(dir)).map_err(|e| format!("{dir}: {e}"))?;
    }
    let stamp = stamp.ok_or_else(|| format!("{MANIFEST}: no {STAMP}"))?;
    fs::write(partial.join(STAMP), stamp).map_err(|e| format!("{STAMP}: {e}"))?;
    if out.exists() {
        fs::remove_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    }
    fs::rename(&partial, out).map_err(|e| format!("{}: {e}", out.display()))?;
    Ok(total)
}

/// `horizon-facts pack-facts|assemble ...`: `None` when `args` is neither.
pub fn cli(args: &[String]) -> Option<Result<(), String>> {
    let command = args.first()?.as_str();
    if command != "pack-facts" && command != "assemble" {
        return None;
    }
    let mut flags: HashMap<&str, &str> = HashMap::new();
    let mut rest = args[1..].iter();
    while let Some(flag) = rest.next() {
        match rest.next() {
            Some(value) => {
                flags.insert(flag.as_str(), value.as_str());
            }
            None => return Some(Err(format!("{flag} takes a value"))),
        }
    }
    let need = |flag: &str| {
        flags
            .get(flag)
            .map(PathBuf::from)
            .ok_or_else(|| format!("{command} needs {flag}"))
    };
    Some((|| {
        if command == "pack-facts" {
            let summary = pack_facts(
                &need("--resources")?,
                &need("--client-jar")?,
                &need("--assets-dir")?,
                flags.get("--asset-index").copied().unwrap_or("34"),
                flags.get("--version").copied().unwrap_or("26.3"),
                &need("--out")?,
            )?;
            println!(
                "Packed {} files: {} from the client jar, {} from the asset store, {} computed ({:.1} MB)",
                summary.files,
                summary.from_jar,
                summary.from_assets,
                summary.facts,
                summary.facts_bytes as f64 / 1e6
            );
        } else {
            let sources = Sources {
                facts: &need("--facts")?,
                client_jar: &need("--client-jar")?,
                assets: &need("--assets-dir")?,
            };
            let total = assemble(&sources, &need("--out")?, &|_, _| {})?;
            println!("Assembled {total} files");
        }
        Ok(())
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("horizon-facts-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn assemble_rebuilds_the_packed_tree_exactly() {
        let root = scratch("roundtrip");
        // The player's own files: a client jar and an asset store.
        let jar = root.join("client.jar");
        let mut zip = zip::ZipWriter::new(fs::File::create(&jar).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("assets/minecraft/lang/en_us.json", options)
            .unwrap();
        zip.write_all(b"{\"a\": \"b\"}").unwrap();
        zip.finish().unwrap();
        let sound = b"ogg bytes";
        let hash = sha1_hex(sound);
        let assets = root.join("assets");
        fs::create_dir_all(assets.join("indexes")).unwrap();
        fs::create_dir_all(object_path(&assets, &hash).parent().unwrap()).unwrap();
        fs::write(object_path(&assets, &hash), sound).unwrap();
        fs::write(
            assets.join("indexes/34.json"),
            format!("{{\"objects\": {{\"minecraft/sounds/a.ogg\": {{\"hash\": \"{hash}\", \"size\": 9}}}}}}"),
        )
        .unwrap();
        // A prepared tree: one file of each kind, an empty folder, and what a pack leaves out.
        let resources = root.join("resources");
        for (path, data) in [
            ("assets/minecraft/lang/en_us.json", &b"{\"a\": \"b\"}"[..]),
            ("assets/minecraft/sounds/a.ogg", sound),
            ("facts.json", b"{\"computed\": 1}"),
            (STAMP, b"{\"output_version\": 4}"),
            ("export.log", b"left out"),
            ("classes/A.class", b"left out"),
        ] {
            let target = resources.join(path);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(target, data).unwrap();
        }
        fs::create_dir_all(resources.join("assets/minecraft/resourcepacks")).unwrap();

        let pack = root.join("facts.zip");
        let summary = pack_facts(&resources, &jar, &assets, "34", "26.3", &pack).unwrap();
        assert_eq!(
            (
                summary.files,
                summary.from_jar,
                summary.from_assets,
                summary.facts
            ),
            (4, 1, 1, 2)
        );
        let out = root.join("assembled");
        let sources = Sources {
            facts: &pack,
            client_jar: &jar,
            assets: &assets,
        };
        assert_eq!(assemble(&sources, &out, &|_, _| {}).unwrap(), 4);
        for path in [
            "assets/minecraft/lang/en_us.json",
            "assets/minecraft/sounds/a.ogg",
            "facts.json",
            STAMP,
        ] {
            assert_eq!(
                fs::read(out.join(path)).unwrap(),
                fs::read(resources.join(path)).unwrap(),
                "{path}"
            );
        }
        assert!(out.join("assets/minecraft/resourcepacks").is_dir());
        assert!(!out.join("export.log").exists() && !out.join("classes").exists());

        // Another client jar is refused before anything is written.
        let other = root.join("other.jar");
        let mut zip = zip::ZipWriter::new(fs::File::create(&other).unwrap());
        zip.start_file("x", options).unwrap();
        zip.finish().unwrap();
        let sources = Sources {
            facts: &pack,
            client_jar: &other,
            assets: &assets,
        };
        assert!(assemble(&sources, &root.join("refused"), &|_, _| {}).is_err());
        assert!(!root.join("refused").exists());
        let _ = fs::remove_dir_all(&root);
    }
}
