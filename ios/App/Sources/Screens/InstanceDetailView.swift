import SwiftUI

/// One instance's page: its worlds, mods, resource packs, shaders and logs, each its own,
/// whichever instance is selected; Play, Edit and the rest at the top.
struct InstanceDetailView: View {
    enum Section: String, CaseIterable, Identifiable {
        case worlds = "Worlds", mods = "Mods", resourcePacks = "Resource packs", shaders = "Shaders", logs = "Logs"
        var id: String { rawValue }
    }

    let instanceID: String
    @EnvironmentObject private var instances: Instances
    @AppStorage("tab") private var tab = Tab.play
    @State private var section = Section.mods
    @State private var editing = false

    private var instance: Instance? { instances.list.first { $0.id == instanceID } }

    var body: some View {
        if let instance {
            VStack(spacing: 0) {
                header(instance)
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                Group {
                    switch section {
                    case .worlds: WorldsView(instanceID: instance.id)
                    case .mods: PacksView(root: instance.url, kind: .mod)
                    case .resourcePacks: PacksView(root: instance.url, kind: .resourcepack)
                    case .shaders: PacksView(root: instance.url, kind: .shader)
                    case .logs: LogsView(root: instance.url)
                    }
                }
                .id(section)
            }
            .navigationTitle(instance.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Edit", systemImage: "pencil") { editing = true }
            }
            .sheet(isPresented: $editing) {
                InstanceEditor(mode: .edit(instance)) { name, icon, color, renderDistance, _ in
                    var changed = instance
                    changed.name = name
                    changed.icon = icon
                    changed.color = color
                    changed.renderDistance = renderDistance
                    instances.update(changed)
                }
            }
        } else {
            ContentUnavailableView("This instance is gone", systemImage: "questionmark.folder")
        }
    }

    private func header(_ instance: Instance) -> some View {
        HStack(spacing: 14) {
            InstanceIcon(instance: instance, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name).font(.title3.bold())
                Text("Minecraft 26.3" + (instance.lastPlayed.map { " · played \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if instance.id == instances.selectedID {
                Label("Selected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            Button {
                instances.select(instance)
                tab = .play
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
