import Foundation
import UniformTypeIdentifiers

/// The game folder (`--game-dir .`, the app's Documents, shown in the Files app) and the
/// folders in it the launcher manages.
enum GameFolders {
    /// The selected instance's folder (Instances keeps "instanceFolder" up to date).
    static var root: URL {
        let folder = UserDefaults.standard.string(forKey: "instanceFolder") ?? ""
        return folder.isEmpty ? GameBridge.documents : GameBridge.documents.appendingPathComponent(folder, isDirectory: true)
    }
    static var saves: URL { root.appendingPathComponent("saves", isDirectory: true) }
    static var resourcePacks: URL { root.appendingPathComponent("resourcepacks", isDirectory: true) }
    static var shaderPacks: URL { root.appendingPathComponent("shaderpacks", isDirectory: true) }
    /// Horizon's content mods (`.hmod`), as its mod browser installs them.
    static var mods: URL { root.appendingPathComponent("horizon-mods", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static var crashReports: URL { root.appendingPathComponent("crash-reports", isDirectory: true) }

    static func entries(_ folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        return ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Bytes in a file or a folder tree.
    static func size(_ url: URL) -> Int64 {
        guard isDirectory(url) else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = walker?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `name`, else `name (2)`, `name (3)`…: the first that isn't taken in `folder`.
    static func unique(_ name: String, in folder: URL, ext: String = "") -> URL {
        let file = { (n: String) in folder.appendingPathComponent(ext.isEmpty ? n : "\(n).\(ext)") }
        var candidate = file(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = file("\(name) (\(n))")
            n += 1
        }
        return candidate
    }

    /// Copies a file the Files app handed over (security-scoped) into `folder`.
    static func importFile(_ source: URL, into folder: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension
        let target = unique(source.deletingPathExtension().lastPathComponent, in: folder, ext: ext)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// A zip of a folder, for sharing (the system zips it: NSFileCoordinator's `forUploading`).
    static func zipped(_ folder: URL) throws -> URL {
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zip in
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(folder.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: out)
            result = Result { try FileManager.default.copyItem(at: zip, to: out); return out }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }

    /// Unpacks `zip` (Rust: horizon_ios_unzip) into a new temporary folder.
    static func unzip(_ zip: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if let error = horizon_ios_unzip(zip.path, out.path) {
            defer { horizon_ios_free_string(error) }
            throw AuthError.message(String(cString: error))
        }
        return out
    }
}

extension UTType {
    static let hmod = UTType(filenameExtension: "hmod") ?? .data
    static let hshader = UTType(filenameExtension: "hshader") ?? .data
}
