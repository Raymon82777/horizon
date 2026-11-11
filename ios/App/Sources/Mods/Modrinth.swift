import CryptoKit
import Foundation

/// Modrinth's public API (api.modrinth.com/v2, no key), for what Horizon can load from it:
/// resource packs and data packs. Its mods are Java code and its shader packs need more of the
/// format than Horizon reads, so neither is offered (the desktop launcher's rules,
/// launcher/src/browser/modrinth.rs).
enum Modrinth {
    static let api = "https://api.modrinth.com/v2"
    static let site = "https://modrinth.com"
    /// Files are only taken from Modrinth's own file server.
    static let fileHost = "https://cdn.modrinth.com/"

    /// The record key of a Modrinth project in ios-registry.json, apart from the registry's ids.
    static func recordKey(_ projectID: String) -> String { "modrinth:\(projectID)" }

    enum Sort: String, CaseIterable, Identifiable {
        case relevance, downloads, updated, newest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .relevance: "Relevance"
            case .downloads: "Downloads"
            case .updated: "Recently updated"
            case .newest: "Newest"
            }
        }
    }

    /// Modrinth's project type and the version loader whose files Horizon takes.
    static func projectType(_ kind: RegistryKind) -> String? {
        switch kind {
        case .resourcepack: "resourcepack"
        case .datapack: "datapack"
        case .mod, .shader: nil
        }
    }

    static func loader(_ kind: RegistryKind) -> String {
        kind == .datapack ? "datapack" : "minecraft"
    }

    // MARK: Requests

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Modrinth asks for a user agent that names the project.
        config.httpAdditionalHeaders = [
            "User-Agent": "horizon-rust/horizon horizon-ios/\(Bundle.main.version) (github.com/horizon-rust/horizon)",
        ]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(string: api + path)!
        if !query.isEmpty { components.queryItems = query }
        let (data, response) = try await session.data(from: components.url!)
        try check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AuthError.message("Modrinth answered \(code).") }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "[]"
    }

    /// A page of search hits for `kind`; unless `everything`, only projects with a 26.3 version.
    static func search(_ text: String, kind: RegistryKind, sort: Sort, everything: Bool,
                       offset: Int, limit: Int = 30) async throws -> [Hit] {
        guard let type = projectType(kind) else { return [] }
        var facets = [["project_type:\(type)"]]
        if !everything { facets.append(["versions:\(ModRegistry.game)"]) }
        var query = [URLQueryItem(name: "facets", value: json(facets)),
                     URLQueryItem(name: "index", value: sort.rawValue),
                     URLQueryItem(name: "offset", value: String(offset)),
                     URLQueryItem(name: "limit", value: String(limit))]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { query.append(URLQueryItem(name: "query", value: trimmed)) }
        let page: SearchPage = try await get("/search", query)
        return page.hits
    }

    static func project(_ id: String) async throws -> Project {
        try await get("/project/\(id)")
    }

    /// A project's listed versions with files for `kind`'s loader, newest first.
    static func versions(_ projectID: String, kind: RegistryKind) async throws -> [Version] {
        let all: [Version] = try await get("/project/\(projectID)/version",
                                           [URLQueryItem(name: "loaders", value: json([loader(kind)]))])
        return all.filter { ($0.status ?? "listed") == "listed" && $0.file != nil }
            .sorted { $0.datePublished > $1.datePublished }
    }

    /// The version to install: the newest made for 26.3, or with `everything` the newest at all.
    static func pick(_ versions: [Version], everything: Bool) -> Version? {
        versions.first { $0.gameVersions.contains(ModRegistry.game) } ?? (everything ? versions.first : nil)
    }

    /// The newest 26.3 version for each installed file's SHA-512 (`POST /version_files/update`).
    static func updates(sha512: [String], kind: RegistryKind) async throws -> [String: Version] {
        guard !sha512.isEmpty else { return [:] }
        struct Body: Encodable {
            let hashes: [String]
            let algorithm = "sha512"
            let loaders: [String]
            let game_versions: [String]
        }
        var request = URLRequest(url: URL(string: api + "/version_files/update")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(hashes: sha512, loaders: [loader(kind)],
                                                         game_versions: [ModRegistry.game]))
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try JSONDecoder().decode([String: Version].self, from: data)
    }

    // MARK: Install

    /// Downloads a version's file, checks its SHA-512, and puts it in `kind`'s folder under
    /// `root` (an instance's folder, or a world's for a data pack), replacing what an earlier
    /// install of the same project put there.
    static func install(projectID: String, title: String, _ version: Version, kind: RegistryKind,
                        into root: URL) async throws {
        guard let file = version.file else { throw AuthError.message("\(title) has no file to download.") }
        guard file.url.hasPrefix(fileHost), let url = URL(string: file.url) else {
            throw AuthError.message("\(title)'s file isn't on Modrinth's file server.")
        }
        guard let expected = file.hashes.sha512?.lowercased() else {
            throw AuthError.message("Modrinth gives no checksum for \(title).")
        }
        let (temp, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temp) }
        try check(response)
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        let actual = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw AuthError.message("\(title) arrived damaged (its checksum doesn't match). Try again.")
        }
        guard data.starts(with: [0x50, 0x4B]) else {
            throw AuthError.message("\(title)'s file isn't a zip, so Minecraft can't load it.")
        }

        let folder = kind.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records = InstalledRecords.load(root)
        let key = recordKey(projectID)
        if let old = records[key] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.file))
        }
        var name = file.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = String(name.drop { $0 == "." })
        if name.isEmpty { name = "\(projectID).zip" }
        if !name.lowercased().hasSuffix(".zip") { name += ".zip" }
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        records[key] = InstalledRecord(kind: kind.rawValue, version: version.versionNumber, sha256: "", file: name,
                                       source: "modrinth", title: title, versionID: version.id, sha512: expected)
        InstalledRecords.save(records, root)
    }

    // MARK: Types

    struct SearchPage: Decodable {
        let hits: [Hit]
    }

    struct Hit: Decodable, Identifiable, Hashable {
        let projectID: String
        let slug: String
        let title: String
        let description: String
        let author: String?
        let downloads: Int
        let iconURL: String?
        let versions: [String]?
        var id: String { projectID }
        var madeFor26: Bool { versions?.contains(ModRegistry.game) == true }

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id", slug, title, description, author, downloads
            case iconURL = "icon_url", versions
        }
    }

    struct Project: Decodable {
        let id: String
        let slug: String
        let title: String
        let description: String
        let body: String?
        let downloads: Int
        let iconURL: String?
        let sourceURL: String?
        let license: License?
        let gallery: [Image]?

        struct License: Decodable { let id: String; let name: String? }
        struct Image: Decodable, Hashable { let url: String; let title: String? }

        enum CodingKeys: String, CodingKey {
            case id, slug, title, description, body, downloads, license, gallery
            case iconURL = "icon_url", sourceURL = "source_url"
        }
    }

    struct Version: Decodable, Identifiable, Hashable {
        let id: String
        let projectID: String
        let versionNumber: String
        let changelog: String?
        let datePublished: String
        let gameVersions: [String]
        let loaders: [String]
        let status: String?
        let files: [File]

        /// The primary file, or the only one.
        var file: File? { files.first { $0.primary } ?? files.first }

        enum CodingKeys: String, CodingKey {
            case id, changelog, loaders, status, files
            case projectID = "project_id", versionNumber = "version_number"
            case datePublished = "date_published", gameVersions = "game_versions"
        }
    }

    struct File: Decodable, Hashable {
        let url: String
        let filename: String
        let primary: Bool
        let size: Int64
        let hashes: Hashes

        struct Hashes: Decodable, Hashable { let sha512: String?; let sha1: String? }
    }
}
