import SwiftUI
import UniformTypeIdentifiers

/// The instances: pick one to play, make one, edit, duplicate, export, import, delete.
struct InstancesView: View {
    @EnvironmentObject private var instances: Instances
    @AppStorage("tab") private var tab = Tab.play
    @State private var editing: Instance?
    @State private var creating = false
    @State private var deleting: Instance?
    @State private var importing = false
    @State private var shared: URL?
    @State private var error: String?
    @State private var stats: [String: (worlds: Int, size: Int64)] = [:]

    var body: some View {
        NavigationStack {
            List {
                ForEach(instances.list) { instance in
                    row(instance)
                }
            }
            .navigationTitle("Instances")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                    Button("New instance", systemImage: "plus") { creating = true }
                }
            }
        }
        .onAppear(perform: measure)
        .onChange(of: instances.list) { measure() }
        .sheet(isPresented: $creating) {
            InstanceEditor(mode: .create) { name, icon, color, _, copySettings in
                do {
                    let made = try instances.create(name: name, icon: icon, color: color,
                                                    settingsFrom: copySettings ? instances.current : nil)
                    instances.select(made)
                } catch { self.error = error.localizedDescription }
            }
        }
        .sheet(item: $editing) { instance in
            InstanceEditor(mode: .edit(instance)) { name, icon, color, renderDistance, _ in
                var changed = instance
                changed.name = name
                changed.icon = icon
                changed.color = color
                changed.renderDistance = renderDistance
                instances.update(changed)
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete instance and its worlds", role: .destructive) {
                if let instance = deleting {
                    do { try instances.delete(instance) } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Its worlds, packs, mods and settings are deleted. This can't be undone; export it first to keep a copy.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            do { try instances.importInstance(result.get()) } catch { self.error = error.localizedDescription }
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

    private func row(_ instance: Instance) -> some View {
        let selected = instance.id == instances.selectedID
        return NavigationLink {
            InstanceDetailView(instanceID: instance.id)
        } label: {
            rowContent(instance, selected: selected)
        }
    }

    private func rowContent(_ instance: Instance, selected: Bool) -> some View {
        HStack(spacing: 14) {
            InstanceIcon(instance: instance, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(instance.name).font(.headline)
                    if selected {
                        Text("Selected").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.25), in: Capsule())
                    }
                }
                Text(details(instance)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Play") {
                instances.select(instance)
                tab = .play
            }
            .buttonStyle(.borderedProminent)
            Menu {
                Button("Edit", systemImage: "pencil") { editing = instance }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    do { try instances.duplicate(instance) } catch { self.error = error.localizedDescription }
                }
                Button("Export", systemImage: "square.and.arrow.up") {
                    do { shared = try instances.export(instance) } catch { self.error = error.localizedDescription }
                }
                if !instance.isDefault {
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = instance }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.vertical, 4)
    }

    private func details(_ instance: Instance) -> String {
        var parts: [String] = []
        if let s = stats[instance.id] {
            parts.append(s.worlds == 1 ? "1 world" : "\(s.worlds) worlds")
            parts.append(GameFolders.format(s.size))
        }
        parts.append(instance.lastPlayed.map { "Played \($0.formatted(.relative(presentation: .named)))" } ?? "Not played yet")
        return parts.joined(separator: " · ")
    }

    private func measure() {
        let list = instances.list
        DispatchQueue.global(qos: .utility).async {
            var result: [String: (worlds: Int, size: Int64)] = [:]
            for instance in list {
                let worlds = GameFolders.entries(instance.url.appendingPathComponent("saves")).filter(GameFolders.isDirectory).count
                let size = Instances.ownItems(of: instance).reduce(Int64(0)) { $0 + GameFolders.size($1) }
                result[instance.id] = (worlds, size)
            }
            DispatchQueue.main.async { stats = result }
        }
    }
}

struct InstanceIcon: View {
    let instance: Instance
    var size: CGFloat

    var body: some View {
        Image(systemName: instance.icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(instance.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// Make an instance, or change one's name, icon, colour and render distance.
struct InstanceEditor: View {
    enum Mode {
        case create
        case edit(Instance)
    }

    let mode: Mode
    /// name, icon, colour, render distance, copy the current instance's settings (create only)
    let done: (String, String, Int, Int, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var instances: Instances
    @State private var name = "New Instance"
    @State private var icon = "leaf.fill"
    @State private var color = 1
    @State private var renderDistance = 8.0
    @State private var copySettings = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        InstanceIcon(instance: preview, size: 64)
                        TextField("Name", text: $name).font(.title3)
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(Instance.icons, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(symbol == icon ? Instance.palette[color].opacity(0.4) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { icon = symbol }
                        }
                    }
                    HStack {
                        ForEach(Instance.palette.indices, id: \.self) { i in
                            Circle().fill(Instance.palette[i]).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: i == color ? 3 : 0))
                                .onTapGesture { color = i }
                        }
                    }
                }
                if case .create = mode {
                    Section {
                        Toggle("Copy settings from \(instances.current.name)", isOn: $copySettings)
                    } footer: {
                        Text("Starts with the same game options (controls, video, GUI scale) and server list. Worlds, packs and mods start empty.")
                    }
                }
            }
            .navigationTitle(isCreate ? "New instance" : "Edit instance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreate ? "Create" : "Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        done(trimmed.isEmpty ? "Instance" : trimmed, icon, color, Int(renderDistance), copySettings)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if case .edit(let instance) = mode {
                name = instance.name
                icon = instance.icon
                color = instance.color
                renderDistance = Double(instance.renderDistance)
            }
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var preview: Instance {
        Instance(id: "", name: name, icon: icon, color: color, folder: "x", created: Date())
    }
}
