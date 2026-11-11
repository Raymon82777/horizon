import Foundation

/// Horizon's mod registry (github.com/horizon-rust/horizon-mods): its index.json, schema 1
/// (docs/api/mod-index.md). Read at most every ten minutes and kept in Caches.
struct RegistryIndex: Decodable {
    let schema: Int
    let projects: [RegistryProject]
    let revoked: [Revoked]?

    struct Revoked: Decodable {
        let id: String
        let sha256: String?
        let reason: String
    }

    func revocation(id: String, sha256: String) -> String? {
        revoked?.first { $0.id == id && ($0.sha256 == nil || $0.sha256 == sha256) }?.reason
    }
}

struct RegistryProject: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
    let summary: String
    let description: String?
    let authors: [String]?
    let license: String?
    let source: String?
    let icon: String?
    let key: String?
    let downloads: Int?
    let categories: [String]?
    let versions: [RegistryVersion]

    var signed: Bool { key != nil }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RegistryVersion: Decodable {
    let version: String
    let published: String?
    let changelog: String?
    let game: String
    let capabilities: [String]?
    let file: RegistryFile
}

struct RegistryFile: Decodable {
    let name: String
    let url: String
    let size: Int64
    let sha256: String
}

/// What the iOS app can install from the registry, and where it goes.
enum RegistryKind: String, CaseIterable, Identifiable {
    case mod, resourcepack, shader, datapack
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mod: "Mods"
        case .resourcepack: "Resource packs"
        case .shader: "Shaders"
        case .datapack: "Data packs"
        }
    }

    /// Where this kind lives in an instance's folder (a data pack: in a world's folder).
    func folder(in root: URL) -> URL {
        switch self {
        case .mod: root.appendingPathComponent("horizon-mods", isDirectory: true)
        case .resourcepack: root.appendingPathComponent("resourcepacks", isDirectory: true)
        case .shader: root.appendingPathComponent("shaderpacks", isDirectory: true)
        case .datapack: root.appendingPathComponent("datapacks", isDirectory: true)
        }
    }

    /// Whether Modrinth has this kind in a form Horizon loads.
    var onModrinth: Bool { Modrinth.projectType(self) != nil }
}

enum ModRegistry {
    static let indexURL = URL(string: "https://horizon-rust.github.io/horizon-mods/index.json")!
    static let game = "26.3"

    static var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("horizon-index.json")
    }

    /// The index: the cached copy when it's under ten minutes old (or offline), else fresh.
    static func load(force: Bool = false) async throws -> RegistryIndex {
        let cached = cacheFile
        let age = GameFolders.modified(cached).map { -$0.timeIntervalSinceNow } ?? .infinity
        if force || age > 600 {
            do {
                let (data, response) = try await URLSession.shared.data(from: indexURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw AuthError.message("The mod registry answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
                }
                try data.write(to: cached, options: .atomic)
            } catch where FileManager.default.fileExists(atPath: cached.path) {
                // Offline: the last copy will do.
            }
        }
        let index = try JSONDecoder().decode(RegistryIndex.self, from: Data(contentsOf: cached))
        guard index.schema <= 1 else {
            throw AuthError.message("The mod registry is newer than this app: update Horizon.")
        }
        return index
    }

    /// The version the app would install: the newest for 26.3 that wasn't taken down, and for a
    /// mod one that's content only (no code: Horizon on iOS has no runtime for it, and the
    /// desktop launcher doesn't list such mods alone either).
    static func installable(_ project: RegistryProject, in index: RegistryIndex) -> RegistryVersion? {
        project.versions.first { v in
            v.game == game
                && index.revocation(id: project.id, sha256: v.file.sha256) == nil
                && (project.kind != RegistryKind.mod.rawValue || Set(v.capabilities ?? []).isSubset(of: ["registries"]))
        }
    }
}

/// What this app installed from the registry into an instance, so it can tell updates and
/// take-downs (`ios-registry.json` in the instance's folder).
struct InstalledRecord: Codable {
    var kind: String
    var version: String
    var sha256: String
    /// The installed file's name in its kind's folder.
    var file: String
    /// "modrinth" for a Modrinth install (keyed `modrinth:<project id>`); nil for the registry.
    var source: String? = nil
    var title: String? = nil
    var versionID: String? = nil
    var sha512: String? = nil

    var fromModrinth: Bool { source == "modrinth" }
}

enum InstalledRecords {
    static func file(_ root: URL) -> URL { root.appendingPathComponent("ios-registry.json") }

    static func load(_ root: URL) -> [String: InstalledRecord] {
        (try? JSONDecoder().decode([String: InstalledRecord].self, from: Data(contentsOf: file(root)))) ?? [:]
    }

    static func save(_ records: [String: InstalledRecord], _ root: URL) {
        let data = try? JSONEncoder().encode(records)
        try? data?.write(to: file(root), options: .atomic)
    }
}

/// `horizon-mods.txt` beside options.txt: `mod.<id>:true` lines turn content mods on
/// (horizon_client_render::mod_list). Other lines are kept as they are.
enum ModSwitches {
    static func file(_ root: URL) -> URL { root.appendingPathComponent("horizon-mods.txt") }

    static func enabled(_ root: URL) -> Set<String> {
        guard let text = try? String(contentsOf: file(root), encoding: .utf8) else { return [] }
        var on = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].hasPrefix("mod."), parts[1].trimmingCharacters(in: .whitespaces) == "true" {
                on.insert(String(parts[0].dropFirst(4)))
            }
        }
        return on
    }

    /// Turns `id` on or off; `nil` removes its line (an uninstalled mod).
    static func set(_ id: String, _ on: Bool?, _ root: URL) {
        let file = file(root)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.hasPrefix("mod.\(id):") }
        if let on { lines.append("mod.\(id):\(on)") }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// A content mod's manifest (Rust: horizon_ios_mod_manifest).
struct ModManifest: Decodable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let authors: [String]?
    let code: Bool?

    static func read(_ file: URL) -> ModManifest? {
        guard let raw = horizon_ios_mod_manifest(file.path) else { return nil }
        defer { horizon_ios_free_string(raw) }
        return try? JSONDecoder().decode(ModManifest.self, from: Data(String(cString: raw).utf8))
    }
}

enum ModInstaller {
    /// Downloads a registry project's version, checks it with the registry's own checks (Rust:
    /// horizon_ios_mod_check), and puts it in the selected instance. A mod is turned on.
    static func install(_ project: RegistryProject, _ version: RegistryVersion, into root: URL) async throws {
        guard let kind = RegistryKind(rawValue: project.kind) else {
            throw AuthError.message("This app can't install a \(project.kind) yet.")
        }
        guard let url = URL(string: version.file.url), url.scheme == "https" else {
            throw AuthError.message("\(project.name)'s download link isn't https.")
        }
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.message("Couldn't download \(project.name) (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        // The check reads the file by its name's extension: give it the registry's name.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(version.file.name)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: staged)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        if let error = horizon_ios_mod_check(ModRegistry.cacheFile.path, project.id, version.version, staged.path) {
            defer { horizon_ios_free_string(error) }
            throw AuthError.message("\(project.name) didn't pass the registry's checks: \(String(cString: error))")
        }
        var records = InstalledRecords.load(root)
        let folder = kind.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // An update replaces the file the last install put there.
        if let old = records[project.id] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.file))
        }
        let name = kind == .mod ? "\(project.id).hmod" : version.file.name
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staged, to: target)
        records[project.id] = InstalledRecord(kind: kind.rawValue, version: version.version,
                                              sha256: version.file.sha256, file: name)
        InstalledRecords.save(records, root)
        if kind == .mod { ModSwitches.set(project.id, true, root) }
    }

    /// Removes a file from the selected instance (and its switch and record, if any).
    static func remove(file: URL, kind: RegistryKind, id: String?, root: URL) {
        try? FileManager.default.removeItem(at: file)
        var records = InstalledRecords.load(root)
        if let id {
            records[id] = nil
            if kind == .mod { ModSwitches.set(id, nil, root) }
        }
        // A record whose file this was.
        for (key, record) in records where record.file == file.lastPathComponent && record.kind == kind.rawValue {
            records[key] = nil
        }
        InstalledRecords.save(records, root)
    }
}
