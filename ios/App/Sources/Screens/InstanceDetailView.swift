import SwiftUI

/// One instance's page: its worlds, mods, resource packs, shaders and logs, each its own,
/// whichever instance is selected; Play, Edit and the rest at the top.
struct InstanceDetailView: View {
    enum Section: String, CaseIterable, Identifiable {
        case worlds = "Worlds", mods = "Mods", native = "Native mods", resourcePacks = "Resource packs", shaders = "Shaders", logs = "Logs"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .worlds: "globe"
            case .mods: "puzzlepiece.extension"
            case .native: "hammer"
            case .resourcePacks: "photo.stack"
            case .shaders: "sun.max"
            case .logs: "doc.text"
            }
        }
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
                sectionBar
                Group {
                    switch section {
                    case .worlds: WorldsView(instanceID: instance.id)
                    case .mods: PacksView(root: instance.url, kind: .mod)
                    case .native: NativeModsView(instanceID: instance.id)
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

    /// The sections as a row of chips that scrolls sideways: every name in full, in portrait too.
    private var sectionBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Section.allCases) { item in
                        let on = item == section
                        Button {
                            withAnimation(.snappy) { section = item }
                        } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                                .foregroundStyle(on ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(item)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .onChange(of: section) { withAnimation { proxy.scrollTo(section, anchor: .center) } }
        }
    }

    /// Name and Play side by side when there's room, else stacked with a full-width Play.
    private func header(_ instance: Instance) -> some View {
        let selected = instance.id == instances.selectedID
        let subtitle = "Minecraft 26.3" + (instance.lastPlayed.map { " · played \($0.formatted(.relative(presentation: .named)))" } ?? "")
        let title = HStack(spacing: 14) {
            InstanceIcon(instance: instance, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if selected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
        }
        let play = Button {
            instances.select(instance)
            tab = .play
        } label: {
            Label("Play", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                title
                Spacer(minLength: 16)
                play.frame(width: 160)
            }
            .frame(minWidth: 560)
            VStack(alignment: .leading, spacing: 12) {
                title
                play
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
