import AuthenticationServices
import Foundation
import UIKit

/// The signed-in accounts: public data in Application Support (accounts.json), secrets in the
/// Keychain, one item per account. One account is selected; Play uses it.
@MainActor
final class Accounts: ObservableObject {
    @Published private(set) var list: [Account] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var error: String?

    private struct File: Codable {
        var accounts: [Account]
        var selected: String?
    }

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(File.self, from: data)
        {
            // An account whose secrets are gone (a restored backup: the Keychain items are
            // this-device-only) is signed out.
            list = saved.accounts.filter { Keychain.load(account: $0.uuid) != nil }
            selected = saved.selected.flatMap { s in list.contains { $0.uuid == s } ? s : nil }
                ?? list.first?.uuid
        }
    }

    var current: Account? { list.first { $0.uuid == selected } ?? list.first }

    func select(_ account: Account) {
        selected = account.uuid
        save()
    }

    func signIn() {
        guard let anchor = Self.anchor() else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let (account, secrets) = try await MicrosoftAuth.signIn(anchor: anchor)
                try store(account, secrets)
                selected = account.uuid
                save()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func signOut(_ account: Account) {
        Keychain.delete(account: account.uuid)
        list.removeAll { $0.uuid == account.uuid }
        if selected == account.uuid { selected = list.first?.uuid }
        save()
    }

    /// The session for a game about to start, as a file the game reads once and deletes
    /// (`--session-file`). Renews the token first when it has under an hour left, and asks the
    /// Minecraft services whether the account owns the game; offline, the last answer stands.
    func sessionFile(for account: Account) async throws -> URL {
        guard let data = Keychain.load(account: account.uuid),
              var secrets = try? JSONDecoder().decode(Secrets.self, from: data)
        else {
            throw AuthError.message("Sign in again: this account's sign-in is gone.")
        }
        var account = account
        // Every launch renews the token and asks about ownership again (the owner gate);
        // renewing is one refresh-token call, so it isn't worth keeping a 24 h token around.
        do {
            (account, secrets) = try await MicrosoftAuth.refresh(secrets)
            try store(account, secrets)
        } catch is URLError {
            // Offline: play with what the last check said (online servers will refuse an
            // expired token, offline worlds don't care).
        }
        guard secrets.owns else {
            throw AuthError.message("\(account.name) doesn't own Minecraft: Java Edition.")
        }
        return try Self.writeSession(account, secrets)
    }

    private func store(_ account: Account, _ secrets: Secrets) throws {
        try Keychain.save(try JSONEncoder().encode(secrets), account: account.uuid)
        if let i = list.firstIndex(where: { $0.uuid == account.uuid }) {
            list[i] = account
        } else {
            list.append(account)
        }
        save()
    }

    private func save() {
        let data = try? JSONEncoder().encode(File(accounts: list, selected: selected))
        try? data?.write(to: file, options: .atomic)
    }

    /// Caches (not Documents: the Files app shows Documents), this user only, a fresh name.
    private static func writeSession(_ account: Account, _ secrets: Secrets) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Leftovers of games that never read theirs (the game refuses one after two minutes).
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        var body: [String: Any] = [
            "name": account.name,
            "uuid": account.uuid,
            "access_token": secrets.minecraftToken,
            "user_type": "msa",
        ]
        if let xuid = secrets.xuid { body["xuid"] = xuid }
        let data = try JSONSerialization.data(withJSONObject: body)
        let name = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let url = dir.appendingPathComponent("session-\(name).json")
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600])
        else {
            throw AuthError.message("Couldn't hand the sign-in to the game.")
        }
        return url
    }

    private static func anchor() -> ASPresentationAnchor? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
