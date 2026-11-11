import SwiftUI

/// The game's latest log and its crash reports, readable and shareable.
struct LogsView: View {
    @State private var crashes: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Game log") {
                    NavigationLink {
                        TextFileView(url: GameFolders.logs.appendingPathComponent("latest.log"), tail: true)
                    } label: {
                        Label("Latest log", systemImage: "doc.text")
                    }
                }
                Section("Crash reports") {
                    if crashes.isEmpty {
                        Text("No crashes. 🎉").foregroundStyle(.secondary)
                    }
                    ForEach(crashes, id: \.self) { report in
                        NavigationLink {
                            TextFileView(url: report, tail: false)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(report.deletingPathExtension().lastPathComponent).font(.callout.monospaced())
                                if let date = GameFolders.modified(report) {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Logs")
            .refreshable { reload() }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        crashes = GameFolders.entries(GameFolders.crashReports)
            .sorted { (GameFolders.modified($0) ?? .distantPast) > (GameFolders.modified($1) ?? .distantPast) }
    }
}

/// A text file, monospaced and selectable; long logs show their last lines.
struct TextFileView: View {
    let url: URL
    let tail: Bool
    @State private var text = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear {
                load()
                if tail { DispatchQueue.main.async { proxy.scrollTo("end") } }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise", action: load)
            ShareLink(item: url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            text = "Nothing logged yet."
            return
        }
        let all = String(decoding: data, as: UTF8.self)
        // The last 3000 lines: a long log stays quick to scroll.
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false)
        text = lines.count > 3000 ? lines.suffix(3000).joined(separator: "\n") : all
    }
}
