import Foundation

/// Builds of the instances' native mods on the player's Mac: ios/build-server.py there builds them
/// into the app and installs it straight onto the phone when it's plugged in or on the Mac's network,
/// else serves it to install over the air (ios/remote-install.sh). The phone asks the Mac on its own
/// network first (HorizonBuildLocal, with the secret HorizonBuildToken), and over Tailscale only when
/// that doesn't answer (HorizonBuildHost, the tailnet name; none when the Mac had no Tailscale).
@MainActor
final class MacBuild: ObservableObject {
    static let shared = MacBuild()

    struct Status: Decodable, Equatable {
        var state: String
        var step: String?
        var log: [String]?
        var install: String?
        /// The device the Mac installed the build on directly, if it did.
        var installed: String?
        var warning: String?
        var error: String?
        var started: Double?
        var finished: Double?
    }

    @Published private(set) var status: Status?
    @Published private(set) var error: String?

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    /// http://<Mac>.local:8767 on the Mac's own network, with its secret, or nil.
    static var local: URL? {
        guard let host = info("HorizonBuildLocal"), token != nil else { return nil }
        return URL(string: "http://\(host)")
    }

    private static var token: String? { info("HorizonBuildToken") }

    /// https://<Mac>.<tailnet>.ts.net/horizon-build, or nil.
    static var tailnet: URL? {
        info("HorizonBuildHost").flatMap { URL(string: "https://\($0)/horizon-build") }
    }

    /// Whether this app knows a way to its Mac.
    static var base: URL? { local ?? tailnet }

    /// The Mac's name, without .local or the tailnet.
    static var host: String? {
        (local ?? tailnet)?.host.map { String($0.prefix { $0 != "." }) }
    }

    /// How the Mac answered last: on this network or over Tailscale.
    @Published private(set) var viaTailscale = false

    var building: Bool { status?.state == "building" }

    /// Sends the shared native mods and starts a build.
    func start(_ mods: [NativeModChoice]) async {
        struct Body: Encodable { let nativeMods: [NativeModChoice] }
        let body = try? JSONEncoder().encode(Body(nativeMods: mods))
        await send("build", timeout: 20) { request in
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
    }

    /// The build's progress, if the Mac answers.
    func refresh() async {
        await send("status", timeout: 15) { _ in }
    }

    /// Asks the Mac on this network first (a short wait: it either answers at once or isn't here),
    /// then over Tailscale.
    private func send(_ path: String, timeout: TimeInterval, _ fill: (inout URLRequest) -> Void) async {
        if let local = Self.local, let token = Self.token {
            var request = URLRequest(url: local.appendingPathComponent(path))
            fill(&request)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 3
            if let answer = try? await URLSession.shared.data(for: request) {
                viaTailscale = false
                handle(answer.0, answer.1)
                return
            }
        }
        guard let tailnet = Self.tailnet else {
            error = "Couldn't reach \(Self.host ?? "the Mac") on this network: is the phone on the Mac's Wi-Fi and the Mac awake?"
            return
        }
        var request = URLRequest(url: tailnet.appendingPathComponent(path))
        fill(&request)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            viaTailscale = true
            handle(data, response)
        } catch {
            self.error = "Couldn't reach \(Self.host ?? "the Mac") on this network or over Tailscale: is the Mac awake?"
        }
    }

    private func handle(_ data: Data, _ response: URLResponse) {
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
    }
}
