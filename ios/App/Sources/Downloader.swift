import CryptoKit
import Foundation

/// Downloads Minecraft 26.3 from Mojang for an account that owns it (the owner gate:
/// docs/microsoft-account.md, "Downloading the game for an owner"): the version file, the
/// client jar, the asset index and the asset objects, each checked against the SHA-1 and
/// size Mojang lists. Only what the game reads on a phone: no libraries (there is no JVM).
/// Files already present and correct are kept, so a stopped download goes on where it was, and
/// the same run repairs a damaged install.
final class Downloader {
    struct Progress {
        var done: Int64
        var total: Int64
        var step: String
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    static let manifest = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!
    static let objects = "https://resources.download.minecraft.net"

    let version: String
    let root: URL  // the launcher-style folder: versions/, assets/
    private let session: URLSession
    private let report: (Progress) -> Void

    init(version: String, root: URL, report: @escaping (Progress) -> Void) {
        self.version = version
        self.root = root
        self.report = report
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    /// Returns how many files it downloaded (0: everything was already there and correct).
    func run() async throws -> Int {
        report(Progress(done: 0, total: 0, step: "Finding Minecraft \(version)…"))
        let manifest = try await json(from: Self.manifest)
        guard let entry = (manifest["versions"] as? [[String: Any]])?.first(where: { $0["id"] as? String == version }),
              let versionURL = (entry["url"] as? String).flatMap(URL.init(string:))
        else {
            throw AuthError.message("Mojang doesn't list Minecraft \(version).")
        }
        // The version file.
        let versionDir = root.appendingPathComponent("versions/\(version)", isDirectory: true)
        let versionFile = versionDir.appendingPathComponent("\(version).json")
        var fetched = 0
        fetched += try await fetch(versionURL, to: versionFile, sha1: entry["sha1"] as? String, size: nil)
        guard let versionJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: versionFile)) as? [String: Any],
              let client = (versionJSON["downloads"] as? [String: Any])?["client"] as? [String: Any],
              let index = versionJSON["assetIndex"] as? [String: Any],
              let indexID = index["id"] as? String
        else {
            throw AuthError.message("Minecraft \(version)'s version file isn't what was expected.")
        }
        // The asset index, then the plan: the jar and every object not yet on disk.
        let indexFile = root.appendingPathComponent("assets/indexes/\(indexID).json")
        fetched += try await fetch(try url(index["url"]), to: indexFile, sha1: index["sha1"] as? String, size: nil)
        let objects = (try JSONSerialization.jsonObject(with: Data(contentsOf: indexFile)) as? [String: Any])?["objects"]
            as? [String: [String: Any]] ?? [:]
        var jobs: [(URL, URL, String, Int64)] = []
        let jar = versionDir.appendingPathComponent("\(version).jar")
        jobs.append((try url(client["url"]), jar, client["sha1"] as? String ?? "", (client["size"] as? NSNumber)?.int64Value ?? 0))
        var seen = Set<String>()
        for object in objects.values {
            guard let hash = object["hash"] as? String, hash.count == 40, seen.insert(hash).inserted else { continue }
            let size = (object["size"] as? NSNumber)?.int64Value ?? 0
            let prefix = String(hash.prefix(2))
            jobs.append((URL(string: "\(Self.objects)/\(prefix)/\(hash)")!,
                         root.appendingPathComponent("assets/objects/\(prefix)/\(hash)"), hash, size))
        }
        // Files already there at the right size are checked (SHA-1) as they're counted.
        report(Progress(done: 0, total: 0, step: "Checking files already here…"))
        let missing = await Self.missing(jobs)
        let total = missing.reduce(0) { $0 + $1.3 }
        if missing.isEmpty {
            report(Progress(done: 1, total: 1, step: "All game files are present."))
            return fetched
        }
        let counter = Counter()
        let step = "Downloading \(missing.count) files (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))…"
        report(Progress(done: 0, total: total, step: step))
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var queue = missing[...]
            // 16 at a time.
            for _ in 0..<min(16, queue.count) {
                let job = queue.removeFirst()
                group.addTask { try await self.fetchObject(job) }
            }
            while let bytes = try await group.next() {
                let done = await counter.add(bytes)
                report(Progress(done: done, total: total, step: step))
                if let job = queue.popFirst() {
                    group.addTask { try await self.fetchObject(job) }
                }
            }
        }
        return fetched + missing.count
    }

    // MARK: Files

    private actor Counter {
        var done: Int64 = 0
        func add(_ n: Int64) -> Int64 { done += n; return done }
    }

    private func url(_ value: Any?) throws -> URL {
        guard let text = value as? String, let url = URL(string: text) else {
            throw AuthError.message("Minecraft \(version)'s version file has a bad link.")
        }
        return url
    }

    /// The jobs whose file is missing, the wrong size or the wrong SHA-1.
    private static func missing(_ jobs: [(URL, URL, String, Int64)]) async -> [(URL, URL, String, Int64)] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: job.1.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value
                    guard size == job.3, let data = try? Data(contentsOf: job.1, options: .mappedIfSafe) else {
                        return (i, true)
                    }
                    return (i, sha1(data) != job.2)
                }
            }
            var result: [(URL, URL, String, Int64)] = []
            for await (i, isMissing) in group where isMissing { result.append(jobs[i]) }
            return result
        }
    }

    private func fetchObject(_ job: (URL, URL, String, Int64)) async throws -> Int64 {
        _ = try await fetch(job.0, to: job.1, sha1: job.2, size: job.3, force: true)
        return job.3
    }

    /// Downloads `url` to `file` unless it's already there with this SHA-1; returns 1 if it
    /// downloaded. Three tries; a file that doesn't match what Mojang lists is never kept.
    @discardableResult
    private func fetch(_ url: URL, to file: URL, sha1 expected: String?, size: Int64?, force: Bool = false) async throws -> Int {
        if !force, let expected, let data = try? Data(contentsOf: file), Self.sha1(data) == expected {
            return 0
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (temp, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw AuthError.message("\(url.lastPathComponent): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                let data = try Data(contentsOf: temp, options: .mappedIfSafe)
                if let expected, Self.sha1(data) != expected {
                    throw AuthError.message("\(url.lastPathComponent) didn't match Mojang's checksum.")
                }
                if let size, Int64(data.count) != size {
                    throw AuthError.message("\(url.lastPathComponent) is the wrong size.")
                }
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: temp, to: file)
                return 1
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw lastError ?? AuthError.message("Couldn't download \(url.lastPathComponent).")
    }

    private func json(from url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AuthError.message("Couldn't reach Mojang's download server.")
        }
        return object
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
