import SwiftUI
import UniformTypeIdentifiers

/// Resource packs, shader packs and Horizon content mods: import from the Files app, delete.
/// Turning them on happens in the game (Options → Resource Packs, the mod browser), as on desktop.
struct PacksView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case resourcePacks = "Resource packs"
        case shaderPacks = "Shader packs"
        case mods = "Mods"
        var id: String { rawValue }

        var folder: URL {
            switch self {
            case .resourcePacks: GameFolders.resourcePacks
            case .shaderPacks: GameFolders.shaderPacks
            case .mods: GameFolders.mods
            }
        }

        var types: [UTType] {
            switch self {
            case .resourcePacks: [.zip]
            case .shaderPacks: [.hshader, .zip]
            case .mods: [.hmod]
            }
        }

        var hint: String {
            switch self {
            case .resourcePacks: "Java Edition resource packs (.zip). Turn them on in the game: Options → Resource Packs."
            case .shaderPacks: "Horizon shader packs (.hshader). Pick one in the game's video settings."
            case .mods: "Horizon content mods (.hmod). Java mods (Fabric, Forge) can't run: Horizon has no JVM."
            }
        }

        var icon: String {
            switch self {
            case .resourcePacks: "photo.stack"
            case .shaderPacks: "sun.max"
            case .mods: "puzzlepiece.extension"
            }
        }
    }

    @State private var kind = Kind.resourcePacks
    @State private var files: [URL] = []
    @State private var importing = false
    @State private var deleting: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(kind.hint)
                }
                Section {
                    if files.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: kind.icon,
                                               description: Text("Import one from the Files app."))
                    }
                    ForEach(files, id: \.self) { file in
                        HStack {
                            Image(systemName: kind.icon).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(file.deletingPathExtension().lastPathComponent)
                                Text(GameFolders.format(GameFolders.size(file)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }
                        }
                    }
                }
            }
            .navigationTitle("Packs & mods")
            .toolbar {
                Button("Import", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: kind) { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: kind.types,
                      allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { _ = try GameFolders.importFile(url, into: kind.folder) }
            } catch { self.error = error.localizedDescription }
            reload()
        }
        .confirmationDialog(
            "Delete \(deleting?.lastPathComponent ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = deleting { try? FileManager.default.removeItem(at: file) }
                reload()
            }
        }
        .alert("Couldn't import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func reload() {
        files = GameFolders.entries(kind.folder)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
