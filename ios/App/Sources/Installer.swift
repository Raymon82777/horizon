import Foundation

/// Builds the game's resources on the device from the facts pack in the app bundle and the
/// player's own Minecraft 26.3 files (horizon-prepare's assemble; no Java).
@MainActor
final class Installer: ObservableObject {
    enum State: Equatable {
        case needsGame          // no client jar or asset store yet
        case ready              // resources assembled
        case canAssemble        // inputs present, resources not built
        case assembling(Double)
        case failed(String)
    }

    static let version = "26.3"
    static let assetIndex = "34"

    @Published private(set) var state: State = .needsGame

    private var documents: URL { GameBridge.documents }
    /// The player's own files, laid out like a launcher's folder (versions/, assets/).
    var minecraftDir: URL { documents.appendingPathComponent("minecraft") }
    var clientJar: URL { minecraftDir.appendingPathComponent("versions/\(Self.version)/\(Self.version).jar") }
    var assetsDir: URL { minecraftDir.appendingPathComponent("assets") }
    var resourcesDir: URL { documents.appendingPathComponent("resources") }
    var factsPack: URL? { Bundle.main.url(forResource: "horizon-facts-\(Self.version)", withExtension: "zip") }

    func refresh() {
        if case .assembling = state { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: resourcesDir.appendingPathComponent("horizon-prepare.json").path) {
            state = .ready
        } else if fm.fileExists(atPath: clientJar.path),
                  fm.fileExists(atPath: assetsDir.appendingPathComponent("indexes/\(Self.assetIndex).json").path) {
            state = factsPack == nil ? .failed("This build has no facts pack (horizon-facts-\(Self.version).zip).") : .canAssemble
        } else {
            state = .needsGame
        }
    }

    func assemble() {
        guard let facts = factsPack else { return }
        state = .assembling(0)
        let paths = (facts.path, clientJar.path, assetsDir.path, resourcesDir.path)
        let box = ProgressBox { [weak self] fraction in
            Task { @MainActor in self?.state = .assembling(fraction) }
        }
        Thread {
            let context = Unmanaged.passRetained(box).toOpaque()
            let error = horizon_ios_assemble(paths.0, paths.1, paths.2, paths.3, { done, total, context in
                guard let context, total > 0 else { return }
                Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().report(Double(done) / Double(total))
            }, context)
            Unmanaged<ProgressBox>.fromOpaque(context).release()
            var message: String?
            if let error {
                message = String(cString: error)
                horizon_ios_free_string(error)
            }
            Task { @MainActor [weak self] in
                if let message { self?.state = .failed(message) } else { self?.state = .ready }
            }
        }.start()
    }
}

/// Carries the progress callback across the C boundary.
private final class ProgressBox {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
}
