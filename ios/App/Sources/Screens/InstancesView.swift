import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// The instances: pick one to play, make one, edit, duplicate, export, import, delete.
struct InstancesView: View {
    @EnvironmentObject private var instances: Instances
    @AppStorage("tab") private var tab = Tab.play
    @State private var editing: Instance?
    @State private var opened: Instance?
    @State private var creating = false
    @State private var deleting: Instance?
    @State private var importing = false
    @State private var shared: URL?
    @State private var error: String?
    @State private var stats: [String: (worlds: Int, size: Int64)] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(instances.list) { instance in
                        row(instance)
                    }
                } footer: {
                    Text("Tap an instance to select it: Play plays the selected one. › opens its worlds, mods, packs and logs.")
                }
            }
            .navigationDestination(item: $opened) { instance in
                InstanceDetailView(instanceID: instance.id)
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

    /// One instance: tap to select it (the check and the tint show which), ▶ to select and play,
    /// › for its page (worlds, mods, packs, logs), ⋯ for the rest.
    private func row(_ instance: Instance) -> some View {
        let selected = instance.id == instances.selectedID
        return HStack(spacing: 10) {
            Button {
                withAnimation(.snappy) { instances.select(instance) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.green : Color.secondary)
                        .accessibilityLabel(selected ? "Selected" : "Not selected")
                    InstanceIcon(instance: instance, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instance.name)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(details(instance))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                instances.select(instance)
                tab = .play
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Play \(instance.name)")
            Menu {
                Button("Open", systemImage: "folder") { opened = instance }
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
            Button {
                opened = instance
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(instance.name)")
        }
        .padding(.vertical, 4)
        .listRowBackground(selected ? instance.tint.opacity(0.16) : Color(uiColor: .secondarySystemGroupedBackground))
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
    @State private var textureBudget = 0

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
                if case .edit = mode {
                    Section {
                        Picker("Block texture memory", selection: $textureBudget) {
                            ForEach(GraphicsFile.textureBudgets, id: \.self) { mib in
                                Text(mib == 0 ? "Auto (256 MB)" : mib >= 1024 ? "\(mib / 1024).\(mib % 1024 * 10 / 1024) GB" : "\(mib) MB")
                                    .tag(mib)
                            }
                        }
                    } header: {
                        Text("Memory")
                    } footer: {
                        Text("How much memory this instance's block textures may use: more keeps high-resolution resource packs sharp, less leaves more for the world. The other big use is render distance, in the game's Options. iOS lets Horizon use up to \(Self.limit) on this phone (Settings → Diagnostics). Takes effect the next time you play.")
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
                        if case .edit(let instance) = mode {
                            GraphicsFile.set(GraphicsFile.textureBudgetKey, String(textureBudget), in: instance.url)
                        }
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
                let saved = Int(GraphicsFile.value(GraphicsFile.textureBudgetKey, in: instance.url) ?? "") ?? 0
                textureBudget = GraphicsFile.textureBudgets.contains(saved) ? saved : 0
            }
        }
    }

    /// iOS's memory limit for this app, as Diagnostics measures it.
    static var limit: String {
        let bytes = DiagnosticsView.footprint() + UInt64(os_proc_available_memory())
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var preview: Instance {
        Instance(id: "", name: name, icon: icon, color: color, folder: "x", created: Date())
    }
}
