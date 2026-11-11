import SwiftUI
import UniformTypeIdentifiers

struct World: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var lastPlayed: Date?
    var size: Int64
    var icon: UIImage?
}

/// The worlds in saves/: play one, make one, rename, duplicate, delete, import and export.
struct WorldsView: View {
    @AppStorage("world") private var selectedWorld = "New World"
    @AppStorage("tab") private var tab = Tab.play
    @State private var worlds: [World] = []
    @State private var renaming: World?
    @State private var newName = ""
    @State private var creating = false
    @State private var deleting: World?
    @State private var importing = false
    @State private var shared: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if worlds.isEmpty {
                    ContentUnavailableView("No worlds yet", systemImage: "globe",
                                           description: Text("Make one, or import a world from the Files app."))
                }
                ForEach(worlds) { world in
                    row(world)
                }
            }
            .navigationTitle("Worlds")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                    Button("New world", systemImage: "plus") {
                        newName = "New World"
                        creating = true
                    }
                }
            }
            .refreshable { reload() }
        }
        .onAppear(perform: reload)
        .alert("New world", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = GameFolders.unique(clean(newName), in: GameFolders.saves).lastPathComponent
                play(name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The world is generated when you first play it, with the seed and mode from the Play tab.")
        }
        .alert("Rename world", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let world = renaming { rename(world, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete world", role: .destructive) { if let world = deleting { delete(world) } }
        } message: {
            Text("This can't be undone. Export it first to keep a copy.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder]) { result in
            do { try importWorld(result.get()) } catch { self.error = error.localizedDescription }
        }
        .sheet(item: Binding(get: { shared.map(SharedFile.init) }, set: { shared = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ world: World) -> some View {
        HStack(spacing: 14) {
            Group {
                if let icon = world.icon {
                    Image(uiImage: icon).interpolation(.none).resizable()
                } else {
                    Image(systemName: "globe.europe.africa.fill").resizable().padding(10)
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 52, height: 52)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(world.name).font(.headline)
                    if world.name == selectedWorld {
                        Text("Selected").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.25), in: Capsule())
                    }
                }
                Text([world.lastPlayed.map { "Played \($0.formatted(.relative(presentation: .named)))" },
                      GameFolders.format(world.size)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Play") { play(world.name) }
                .buttonStyle(.borderedProminent)
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newName = world.name
                    renaming = world
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(world) }
                Button("Export", systemImage: "square.and.arrow.up") { export(world) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = world }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selectedWorld = world.name }
    }

    // MARK: Actions

    private func reload() {
        worlds = GameFolders.entries(GameFolders.saves)
            .filter(GameFolders.isDirectory)
            .map { url in
                let level = url.appendingPathComponent("level.dat")
                return World(
                    url: url,
                    lastPlayed: GameFolders.modified(level) ?? GameFolders.modified(url),
                    size: GameFolders.size(url),
                    icon: UIImage(contentsOfFile: url.appendingPathComponent("icon.png").path))
            }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    /// Select the world and go to the Play tab.
    private func play(_ name: String) {
        selectedWorld = name
        tab = .play
    }

    /// Folder names: no path separators, no leading dots.
    private func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stripped = String(trimmed.drop { $0 == "." })
        return stripped.isEmpty ? "New World" : stripped
    }

    private func rename(_ world: World, to name: String) {
        let target = GameFolders.unique(clean(name), in: GameFolders.saves)
        do {
            try FileManager.default.moveItem(at: world.url, to: target)
            if selectedWorld == world.name { selectedWorld = target.lastPathComponent }
        } catch { self.error = error.localizedDescription }
        reload()
    }

    private func duplicate(_ world: World) {
        let target = GameFolders.unique("\(world.name) copy", in: GameFolders.saves)
        do {
            try FileManager.default.copyItem(at: world.url, to: target)
            // A copy isn't the same world while it's open: the session lock stays behind.
            try? FileManager.default.removeItem(at: target.appendingPathComponent("session.lock"))
        } catch { self.error = error.localizedDescription }
        reload()
    }

    private func delete(_ world: World) {
        do { try FileManager.default.removeItem(at: world.url) } catch { self.error = error.localizedDescription }
        reload()
    }

    private func export(_ world: World) {
        do { shared = try GameFolders.zipped(world.url) } catch { self.error = error.localizedDescription }
    }

    /// A world's zip (its folder at the top, or level.dat at the root) or its folder.
    private func importWorld(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: GameFolders.saves, withIntermediateDirectories: true)
        var folder = source
        var name = source.deletingPathExtension().lastPathComponent
        var unpacked: URL?
        if !GameFolders.isDirectory(source) {
            unpacked = try GameFolders.unzip(source)
            folder = unpacked!
        }
        defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
        // The folder holding level.dat: the top, or one level down (a zipped world folder).
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("level.dat").path) {
            guard let inner = GameFolders.entries(folder).first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("level.dat").path)
            }) else {
                throw AuthError.message("That isn't a Minecraft world: no level.dat inside.")
            }
            folder = inner
            name = inner.lastPathComponent
        }
        let target = GameFolders.unique(clean(name), in: GameFolders.saves)
        if unpacked != nil {
            try FileManager.default.moveItem(at: folder, to: target)
        } else {
            try FileManager.default.copyItem(at: folder, to: target)
        }
        reload()
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// UIActivityViewController: AirDrop, Save to Files, Messages…
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
