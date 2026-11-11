import SwiftUI

/// The touch controls' layout, edited on a full-screen canvas the shape of the game's screen.
/// Saved as `touch-controls.json` in the game folder, in the game's own format
/// (`horizon_client_render::touch::layout::Settings`); fields this editor doesn't know stay as
/// they were, and missing ones take the game's defaults.
struct TouchLayoutEditor: View {
    /// One placement: centre (0-1 of the screen), size (a fraction of its height), opacity.
    struct Placement: Equatable {
        var center: CGPoint
        var size: CGFloat
        var opacity: CGFloat
    }

    /// The game's `Control` order (a layout row's index) and its default crosshair row.
    static let names = ["Move", "Sprint", "Jump", "Sneak", "Hit", "Use", "Chat", "II", "Settings",
                        "Inv", "Debug", "F5", "Swap", "Shield"]
    static let defaults: [Placement] = [
        (0.13, 0.76, 0.32), (0.72, 0.78, 0.105), (0.92, 0.78, 0.16), (0.81, 0.86, 0.115),
        (0.80, 0.64, 0.16), (0.92, 0.52, 0.16), (0.46, 0.055, 0.075), (0.50, 0.055, 0.075),
        (0.54, 0.055, 0.075), (0.73, 0.95, 0.075), (0.42, 0.055, 0.075), (0.58, 0.055, 0.075),
        (0.80, 0.96, 0.075), (0.92, 0.36, 0.12),
    ].map { Placement(center: CGPoint(x: $0.0, y: $0.1), size: $0.2, opacity: 0.65) }
    /// What the game draws in the crosshair scheme (Settings, Debug, Swap and Shield don't show).
    static let shown = [0, 1, 2, 3, 4, 5, 6, 7, 9, 11]

    /// Documents, the game's working folder: one layout for every instance.
    static var file: URL { GameBridge.documents.appendingPathComponent("touch-controls.json") }

    @Environment(\.dismiss) private var dismiss
    @State private var row = Self.defaults
    @State private var sensitivity = 1.0
    @State private var selected: Int?
    @State private var dragStart: CGPoint?
    @State private var saved: [String: Any] = [:]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.35),
                                        Color(red: 0.85, green: 0.40, blue: 0.35),
                                        Color(red: 0.13, green: 0.33, blue: 0.23)],
                               startPoint: .top, endPoint: .bottom)
                // The crosshair, for reference.
                Image(systemName: "plus").font(.title2).foregroundStyle(.white.opacity(0.8))
                ForEach(Self.shown, id: \.self) { index in
                    control(index, in: size)
                }
                panel.frame(width: 360).position(x: size.width / 2, y: size.height * 0.42)
            }
            .contentShape(Rectangle())
            .onTapGesture { selected = nil }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear(perform: load)
    }

    private func control(_ index: Int, in size: CGSize) -> some View {
        let p = row[index]
        let diameter = p.size * size.height
        let isMove = index == 0
        return ZStack {
            Circle().fill(Color.black.opacity(0.55 * p.opacity / 0.65))
            if isMove {
                Circle().fill(Color.white.opacity(0.6)).frame(width: diameter * 0.42)
            } else {
                Text(Self.names[index]).font(.system(size: max(10, diameter * 0.22), weight: .semibold))
                    .foregroundStyle(.white)
            }
            if selected == index {
                Circle().stroke(Color.yellow, lineWidth: 3)
            }
        }
        .frame(width: diameter, height: diameter)
        .position(x: p.center.x * size.width, y: p.center.y * size.height)
        .onTapGesture { selected = index }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    selected = index
                    let start = dragStart ?? row[index].center
                    dragStart = start
                    let x = start.x + drag.translation.width / size.width
                    let y = start.y + drag.translation.height / size.height
                    row[index].center = CGPoint(x: min(max(x, 0.025), 0.975), y: min(max(y, 0.025), 0.975))
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    private var panel: some View {
        VStack(spacing: 10) {
            Text(selected.map { "\(Self.label($0))" } ?? "Drag a control to move it; tap one to resize it")
                .font(.headline)
            if let index = selected {
                LabeledSlider(title: "Size", value: Binding(
                    get: { Double(row[index].size) }, set: { row[index].size = CGFloat($0) }), range: 0.045...0.45)
                LabeledSlider(title: "Opacity", value: Binding(
                    get: { Double(row[index].opacity) }, set: { row[index].opacity = CGFloat($0) }), range: 0.1...1)
            } else {
                LabeledSlider(title: "Look speed", value: $sensitivity, range: 0.1...3)
            }
            HStack {
                Button("Reset", role: .destructive) {
                    row = Self.defaults
                    sensitivity = 1
                    selected = nil
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private static func label(_ index: Int) -> String {
        ["Movement", "Sprint", "Jump", "Sneak", "Attack", "Use", "Chat", "Pause", "Settings",
         "Inventory", "Debug", "Camera (F5)", "Swap hands", "Shield"][index]
    }

    // MARK: The file

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        saved = json
        if let rows = json["layouts"] as? [[[String: Any]]], let first = rows.first, first.count == row.count {
            row = zip(first, Self.defaults).map { entry, fallback in
                let center = entry["center"] as? [Double]
                return Placement(
                    center: center.map { CGPoint(x: $0[0], y: $0[1]) } ?? fallback.center,
                    size: (entry["size"] as? Double).map { CGFloat($0) } ?? fallback.size,
                    opacity: (entry["opacity"] as? Double).map { CGFloat($0) } ?? fallback.opacity)
            }
        }
        sensitivity = json["sensitivity"] as? Double ?? 1
    }

    private func save() {
        var json = saved
        let encoded = row.map { p -> [String: Any] in
            ["center": [Double(p.center.x), Double(p.center.y)], "size": Double(p.size), "opacity": Double(p.opacity)]
        }
        // The same row for each scheme: the game uses the crosshair one (the first).
        json["layouts"] = [encoded, encoded, encoded]
        json["sensitivity"] = sensitivity
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%.2f", value)).monospacedDigit().frame(width: 44)
        }
    }
}
