import Foundation

/// An instance's `horizon-graphics.txt` (horizon_client_render::graphics): Horizon's own graphics
/// settings as `key:value` lines beside options.txt. Missing keys take the game's defaults, so
/// the launcher writes only the ones it changes and keeps every other line as it is.
enum GraphicsFile {
    static func url(_ root: URL) -> URL { root.appendingPathComponent("horizon-graphics.txt") }

    static func value(_ key: String, in root: URL) -> String? {
        guard let text = try? String(contentsOf: url(root), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("\(key):") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    static func set(_ key: String, _ value: String, in root: URL) {
        let file = url(root)
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        if let i = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[i] = "\(key):\(value)"
        } else {
            lines.append("\(key):\(value)")
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The block textures' video memory, MiB; 0 is Horizon's own choice (256 MB).
    static let textureBudgetKey = "textureBudgetMiB"
    static let textureBudgets = [0, 512, 1024, 1536, 2048, 3072]
}
