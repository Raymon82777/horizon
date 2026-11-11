import Foundation

/// Builds of the instances' native mods on the player's Mac, asked for from anywhere over
/// Tailscale: ios/build-server.py there builds them into the app and serves it to install over the
/// air (ios/remote-install.sh). The Mac's tailnet name is written into the app when it's built
/// (HorizonBuildHost); an app built without Tailscale on the Mac has none, and can't ask.
@MainActor
final class MacBuild: ObservableObject {
    static let shared = MacBuild()

    struct Status: Decodable, Equatable {
        var state: String
        var step: String?
        var log: [String]?
        var install: String?
        var warning: String?
        var error: String?
        var started: Double?
        var finished: Double?
    }

    @Published private(set) var status: Status?
    @Published private(set) var error: String?

    /// https://<Mac>.<tailnet>.ts.net/horizon-build, or nil.
    static var base: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "HorizonBuildHost") as? String,
              !host.isEmpty, !host.hasPrefix("$(")
        else { return nil }
        return URL(string: "https://\(host)/horizon-build")
    }

    static var host: String? { base?.host }

    var building: Bool { status?.state == "building" }

    /// Sends every instance's native mods and starts a build.
    func start(_ instances: [Instance]) async {
        guard let base = Self.base else { return }
        struct Mod: Encodable { let id, name, version, sha256: String }
        struct Inst: Encodable { let name: String; let nativeMods: [Mod] }
        struct Body: Encodable { let instances: [Inst] }
        let body = Body(instances: instances.map { inst in
            Inst(name: inst.name, nativeMods: (inst.nativeMods ?? []).map {
                Mod(id: $0.id, name: $0.name, version: $0.version, sha256: $0.sha256)
            })
        })
        var request = URLRequest(url: base.appendingPathComponent("build"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 20
        await send(request)
    }

    /// The build's progress, if the Mac answers.
    func refresh() async {
        guard let base = Self.base else { return }
        var request = URLRequest(url: base.appendingPathComponent("status"))
        request.timeoutInterval = 15
        await send(request)
    }

    private func send(_ request: URLRequest) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try? JSONDecoder().decode(Status.self, from: data)
            if (200..<300).contains(code) || code == 409, let decoded, decoded.state != "" {
                status = decoded
                error = code == 409 ? "A build is already running on the Mac." : nil
            } else if code == 404 || code == 502 || code == 503 {
                error = "The Mac isn't taking builds. Start it there: ios/build-server.py --trust-native-code"
            } else {
                struct Reply: Decodable { let error: String? }
                error = (try? JSONDecoder().decode(Reply.self, from: data))?.error ?? "The Mac answered \(code)."
            }
        } catch {
            self.error = "Couldn't reach \(Self.host ?? "the Mac"): is Tailscale on here and the Mac awake?"
        }
    }
}
