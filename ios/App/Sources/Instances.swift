import SwiftUI

/// One instance: its own game folder (`--game-dir` and `--home`): worlds, options.txt, packs,
/// shaders, mods, servers, logs. Every instance shares the Minecraft files and the built
/// resources (Horizon plays one version, so instances differ by content, not by version).
struct Instance: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var color: Int
    /// Relative to Documents; "" is Documents itself (the Default instance, from before
    /// instances existed, left where it was).
    var folder: String
    var created: Date
    var lastPlayed: Date?
    var world: String = "New World"
    var renderDistance: Int = 8
    var seed: String = ""
    var creative: Bool = true

    var isDefault: Bool { folder.isEmpty }
    var url: URL {
        folder.isEmpty ? GameBridge.documents : GameBridge.documents.appendingPathComponent(folder, isDirectory: true)
    }
    var tint: Color { Instance.palette[color % Instance.palette.count] }

    static let icons = ["cube.fill", "leaf.fill", "flame.fill", "drop.fill", "mountain.2.fill", "house.fill",
                        "bolt.fill", "star.fill", "moon.stars.fill", "sparkles", "hammer.fill", "map.fill",
                        "shield.fill", "crown.fill", "tree.fill", "fish.fill"]
    static let palette: [Color] = [.green, .blue, .orange, .purple, .red, .teal, .pink, .yellow, .indigo, .brown]
}

/// The instances, which one is selected, and what's done to them.
@MainActor
final class Instances: ObservableObject {
    @Published private(set) var list: [Instance] = []
    @Published private(set) var selectedID: String = ""

    /// Not an instance's own: shared by all, or Documents' other contents. Never copied or
    /// exported with an instance.
    static let shared: Set<String> = ["minecraft", "resources", "instances", "logs", "crash-reports",
                                      ".horizon-cache", "touch-controls.json", "benchmarks"]

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instances.json")
    }

    private struct Saved: Codable {
        var instances: [Instance]
        var selected: String
    }

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.instances.isEmpty
        {
            list = saved.instances
            selectedID = list.contains { $0.id == saved.selected } ? saved.selected : list[0].id
        } else {
            // First run with instances: what was there becomes Default, settings and all.
            let defaults = UserDefaults.standard
            var first = Instance(id: UUID().uuidString, name: "Default", icon: "cube.fill", color: 0,
                                 folder: "", created: Date())
            first.world = defaults.string(forKey: "world") ?? first.world
            if defaults.object(forKey: "renderDistance") != nil {
                first.renderDistance = Int(defaults.double(forKey: "renderDistance"))
            }
            first.seed = defaults.string(forKey: "seed") ?? ""
            if defaults.object(forKey: "creative") != nil { first.creative = defaults.bool(forKey: "creative") }
            list = [first]
            selectedID = first.id
            save()
        }
        publishFolder()
    }

    var current: Instance { list.first { $0.id == selectedID } ?? list[0] }

    func select(_ instance: Instance) {
        selectedID = instance.id
        publishFolder()
        save()
    }

    func update(_ instance: Instance) {
        guard let i = list.firstIndex(where: { $0.id == instance.id }) else { return }
        list[i] = instance
        save()
    }

    /// Changes the selected instance in place (its world, render distance…).
    func updateCurrent(_ change: (inout Instance) -> Void) {
        var instance = current
        change(&instance)
        update(instance)
    }

    /// A new, empty instance; with `settingsFrom`, it starts with that one's options.txt (GUI
    /// scale, controls, video settings) and servers list.
    @discardableResult
    func create(name: String, icon: String, color: Int, settingsFrom: Instance?) throws -> Instance {
        let folder = try newFolder(for: name)
        if let source = settingsFrom {
            for file in ["options.txt", "servers.dat"] {
                let from = source.url.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: from.path) {
                    try? FileManager.default.copyItem(at: from, to: GameBridge.documents
                        .appendingPathComponent(folder).appendingPathComponent(file))
                }
            }
        }
        let instance = Instance(id: UUID().uuidString, name: name, icon: icon, color: color, folder: folder,
                                created: Date())
        list.append(instance)
        save()
        return instance
    }

    /// A copy of an instance: everything in its folder but the shared parts.
    @discardableResult
    func duplicate(_ source: Instance) throws -> Instance {
        let name = uniqueName("\(source.name) copy")
        let folder = try newFolder(for: name)
        let target = GameBridge.documents.appendingPathComponent(folder)
        for item in Self.ownItems(of: source) {
            try FileManager.default.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
        }
        // A copied world isn't open in the copy.
        let saves = target.appendingPathComponent("saves")
        for world in GameFolders.entries(saves) {
            try? FileManager.default.removeItem(at: world.appendingPathComponent("session.lock"))
        }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = name
        copy.folder = folder
        copy.created = Date()
        copy.lastPlayed = nil
        list.append(copy)
        save()
        return copy
    }

    /// Deletes an instance and its folder. The Default instance is Documents itself and stays.
    func delete(_ instance: Instance) throws {
        guard !instance.isDefault else { return }
        try? FileManager.default.removeItem(at: instance.url)
        list.removeAll { $0.id == instance.id }
        if selectedID == instance.id { select(list[0]) }
        save()
    }

    /// A zip of the instance's own files, plus horizon-instance.json (its name, icon, settings),
    /// for sharing or a backup.
    func export(_ instance: Instance) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(instance.name, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        for item in Self.ownItems(of: instance) {
            try FileManager.default.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
        }
        try JSONEncoder().encode(instance).write(to: staging.appendingPathComponent("horizon-instance.json"))
        return try GameFolders.zipped(staging)
    }

    /// An exported instance's zip (or any zipped game folder) as a new instance.
    @discardableResult
    func importInstance(_ zip: URL) throws -> Instance {
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }
        let unpacked = try GameFolders.unzip(zip)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        // Its contents: the top, or the one folder inside.
        var top = unpacked
        let entries = GameFolders.entries(unpacked)
        if entries.count == 1, GameFolders.isDirectory(entries[0]) { top = entries[0] }
        let meta = try? JSONDecoder().decode(Instance.self, from: Data(contentsOf: top.appendingPathComponent("horizon-instance.json")))
        let name = uniqueName(meta?.name ?? zip.deletingPathExtension().lastPathComponent)
        let folder = try newFolder(for: name)
        let target = GameBridge.documents.appendingPathComponent(folder)
        for item in GameFolders.entries(top) where item.lastPathComponent != "horizon-instance.json"
            && !Self.shared.contains(item.lastPathComponent)
        {
            try FileManager.default.moveItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
        }
        var instance = meta ?? Instance(id: "", name: name, icon: "cube.fill", color: 1, folder: folder, created: Date())
        instance.id = UUID().uuidString
        instance.name = name
        instance.folder = folder
        instance.created = Date()
        instance.lastPlayed = nil
        list.append(instance)
        save()
        return instance
    }

    func markPlayed() {
        updateCurrent { $0.lastPlayed = Date() }
    }

    // MARK: Helpers

    static func ownItems(of instance: Instance) -> [URL] {
        GameFolders.entries(instance.url).filter { !shared.contains($0.lastPathComponent) }
    }

    private func uniqueName(_ name: String) -> String {
        var candidate = name
        var n = 2
        while list.contains(where: { $0.name == candidate }) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    /// A fresh folder under Documents/instances, named after the instance.
    private func newFolder(for name: String) throws -> String {
        let base = GameBridge.documents.appendingPathComponent("instances", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        clean = String(clean.drop { $0 == "." })
        let url = GameFolders.unique(clean.isEmpty ? "Instance" : clean, in: base)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return "instances/\(url.lastPathComponent)"
    }

    /// The selected instance's folder, for the screens that work in it (GameFolders.root).
    private func publishFolder() {
        UserDefaults.standard.set(current.folder, forKey: "instanceFolder")
    }

    private func save() {
        let data = try? JSONEncoder().encode(Saved(instances: list, selected: selectedID))
        try? data?.write(to: file, options: .atomic)
    }
}
