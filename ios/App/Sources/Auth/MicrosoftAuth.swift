import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum AuthError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// What a sign-in keeps secret (Keychain), per account.
struct Secrets: Codable {
    var refreshToken: String
    var minecraftToken: String
    var minecraftExpiry: Date
    var xuid: String?
    /// The last ownership answer (the owner gate): kept with the tokens, not in public data.
    var owns: Bool
    /// Signed in on the temporary legacy path (AuthConfig.legacy): renewals go there too.
    var legacy: Bool?
}

/// The public part of an account.
struct Account: Codable, Identifiable, Equatable {
    var uuid: String
    var name: String
    var skinURL: String?
    var id: String { uuid }
}

/// Microsoft account → Xbox Live → XSTS → Minecraft, as upstream's launcher does it
/// (docs/microsoft-account.md), with the authorization-code flow (PKCE) in an
/// ASWebAuthenticationSession instead of the device code: on a phone the browser sheet is the
/// natural place to sign in.
enum MicrosoftAuth {
    private static let authorize = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!
    private static let token = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!

    // MARK: Sign in

    /// The whole sign-in: the browser sheet, then the token chain and the owner checks.
    @MainActor
    static func signIn(anchor: ASPresentationAnchor) async throws -> (Account, Secrets) {
        if AuthConfig.legacy {
            return try await legacySignIn(anchor: anchor)
        }
        let verifier = randomURLSafe(32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)
        var url = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "client_id", value: AuthConfig.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: AuthConfig.redirectURI),
            .init(name: "scope", value: AuthConfig.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Always offer the account picker, so a second account can be added.
            .init(name: "prompt", value: "select_account"),
        ]
        let callback = try await browser(url: url.url!, anchor: anchor)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") {
            throw AuthError.message(item("error_description") ?? "Microsoft sign-in failed (\(error)).")
        }
        guard item("state") == state, let code = item("code") else {
            throw AuthError.message("Microsoft sign-in returned an unexpected answer.")
        }
        let ms = try await oauth([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": AuthConfig.redirectURI,
            "code_verifier": verifier,
        ])
        return try await minecraft(from: ms)
    }

    /// The temporary path (AuthConfig.legacy): the legacy live.com sign-in Amethyst uses.
    @MainActor
    private static func legacySignIn(anchor: ASPresentationAnchor) async throws -> (Account, Secrets) {
        var url = URLComponents(string: "https://login.live.com/oauth20_authorize.srf")!
        url.queryItems = [
            .init(name: "client_id", value: AuthConfig.legacyClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: AuthConfig.legacyScope),
            .init(name: "redirect_url", value: AuthConfig.legacyRedirect),
        ]
        let callback = try await browser(url: url.url!, anchor: anchor,
                                         scheme: AuthConfig.legacyCallbackScheme, ephemeral: true)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") {
            if error.hasPrefix("access_denied") { throw CancellationError() }
            throw AuthError.message(item("error_description") ?? "Microsoft sign-in failed (\(error)).")
        }
        guard let code = item("code") else {
            throw AuthError.message("Microsoft sign-in returned an unexpected answer.")
        }
        let ms = try await legacyToken(["grant_type": "authorization_code", "code": code])
        var (account, secrets) = try await minecraft(from: ms, legacy: true)
        secrets.legacy = true
        return (account, secrets)
    }

    private static func legacyToken(_ fields: [String: String]) async throws -> MSTokens {
        var url = URLComponents(string: "https://login.live.com/oauth20_token.srf")!
        var all = fields
        all["client_id"] = AuthConfig.legacyClientID
        all["redirect_url"] = AuthConfig.legacyRedirect
        all["scope"] = AuthConfig.legacyScope
        url.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = body["error"] as? String {
            if error == "invalid_grant" { throw AuthError.message("The sign-in expired. Sign in again.") }
            throw AuthError.message(body["error_description"] as? String ?? "Microsoft sign-in failed (\(error)).")
        }
        guard let access = body["access_token"] as? String else {
            throw AuthError.message("Microsoft sign-in returned no token.")
        }
        return MSTokens(access: access, refresh: body["refresh_token"] as? String ?? fields["refresh_token"] ?? "")
    }

    /// Renews the Minecraft token from the refresh token when it has under an hour left, then
    /// asks again whether the account owns the game (the owner gate, at every launch).
    static func refresh(_ secrets: Secrets) async throws -> (Account, Secrets) {
        if secrets.legacy == true {
            let ms = try await legacyToken(["grant_type": "refresh_token", "refresh_token": secrets.refreshToken])
            var (account, renewed) = try await minecraft(from: ms, legacy: true)
            renewed.legacy = true
            return (account, renewed)
        }
        let ms = try await oauth([
            "grant_type": "refresh_token",
            "refresh_token": secrets.refreshToken,
        ])
        return try await minecraft(from: ms)
    }

    // MARK: The chain

    private struct MSTokens { let access: String; let refresh: String }

    private static func minecraft(from ms: MSTokens, legacy: Bool = false) async throws -> (Account, Secrets) {
        // Xbox Live.
        let xbl = try await json(
            URL(string: "https://user.auth.xboxlive.com/user/authenticate")!,
            body: [
                "Properties": [
                    "AuthMethod": "RPS",
                    "SiteName": "user.auth.xboxlive.com",
                    // The legacy live.com token goes as it is; v2.0 tokens take "d=".
                    "RpsTicket": legacy ? ms.access : "d=\(ms.access)",
                ],
                "RelyingParty": "http://auth.xboxlive.com",
                "TokenType": "JWT",
            ])
        guard let xblToken = xbl["Token"] as? String else {
            throw AuthError.message("Xbox Live didn't accept the Microsoft sign-in.")
        }
        // XSTS for the Minecraft services.
        let (xsts, xstsStatus) = try await jsonWithStatus(
            URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!,
            body: [
                "Properties": ["SandboxId": "RETAIL", "UserTokens": [xblToken]],
                "RelyingParty": "rp://api.minecraftservices.com/",
                "TokenType": "JWT",
            ])
        if xstsStatus == 401, let code = xsts["XErr"] as? Int {
            throw AuthError.message(xstsMessage(code))
        }
        guard let xstsToken = xsts["Token"] as? String,
              let claims = (xsts["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]],
              let uhs = claims.first?["uhs"] as? String
        else {
            throw AuthError.message("Xbox Live refused the sign-in (\(xstsStatus)).")
        }
        let xuid = claims.first?["xid"] as? String
        // Minecraft.
        let (mc, mcStatus) = try await jsonWithStatus(
            URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!,
            body: ["identityToken": "XBL3.0 x=\(uhs);\(xstsToken)"])
        if mcStatus == 403 {
            throw AuthError.message("This app is not approved by Mojang yet (ios/SIGN_IN_SETUP.md, step 2).")
        }
        guard let mcToken = mc["access_token"] as? String else {
            throw AuthError.message("Minecraft services refused the sign-in (\(mcStatus)).")
        }
        let expiresIn = (mc["expires_in"] as? Double) ?? 86_400
        // Ownership (Game Pass included), then the profile.
        let entitlements = try await get(
            URL(string: "https://api.minecraftservices.com/entitlements/mcstore")!, bearer: mcToken).0
        let names = ((entitlements["items"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        let owns = names.contains("game_minecraft") || names.contains("product_minecraft")
        let (profile, profileStatus) = try await get(
            URL(string: "https://api.minecraftservices.com/minecraft/profile")!, bearer: mcToken)
        if profileStatus == 404 {
            throw AuthError.message(owns
                ? "Create your Minecraft profile on minecraft.net first."
                : "This account doesn't own Minecraft: Java Edition.")
        }
        guard let uuid = profile["id"] as? String, let name = profile["name"] as? String else {
            throw AuthError.message("Couldn't read the Minecraft profile (\(profileStatus)).")
        }
        let skin = ((profile["skins"] as? [[String: Any]])?.first { ($0["state"] as? String) == "ACTIVE" })?["url"] as? String
        let account = Account(uuid: uuid, name: name, skinURL: skin)
        let secrets = Secrets(
            refreshToken: ms.refresh,
            minecraftToken: mcToken,
            minecraftExpiry: Date().addingTimeInterval(expiresIn),
            xuid: xuid,
            owns: owns)
        return (account, secrets)
    }

    private static func xstsMessage(_ code: Int) -> String {
        switch code {
        case 2148916233: return "This Microsoft account has no Xbox profile yet. Sign in once at xbox.com to create one."
        case 2148916235: return "Xbox Live isn't available in this account's country."
        case 2148916236, 2148916237: return "This account needs adult verification on xbox.com."
        case 2148916238: return "This is a child account: an adult has to add it to a Microsoft family first."
        default: return "Xbox Live refused the sign-in (XErr \(code))."
        }
    }

    // MARK: HTTP

    private static func oauth(_ fields: [String: String]) async throws -> MSTokens {
        var all = fields
        all["client_id"] = AuthConfig.clientID
        all["scope"] = AuthConfig.scope
        var request = URLRequest(url: token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = body["error"] as? String {
            if error == "invalid_grant" {
                throw AuthError.message("The sign-in expired. Sign in again.")
            }
            throw AuthError.message(body["error_description"] as? String ?? "Microsoft sign-in failed (\(error)).")
        }
        guard let access = body["access_token"] as? String else {
            throw AuthError.message("Microsoft sign-in returned no token.")
        }
        return MSTokens(access: access, refresh: body["refresh_token"] as? String ?? fields["refresh_token"] ?? "")
    }

    private static func json(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        try await jsonWithStatus(url, body: body).0
    }

    private static func jsonWithStatus(_ url: URL, body: [String: Any]) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], status)
    }

    private static func get(_ url: URL, bearer: String) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], status)
    }

    // MARK: Browser sheet

    @MainActor
    private static func browser(url: URL, anchor: ASPresentationAnchor,
                                scheme: String = AuthConfig.callbackScheme,
                                ephemeral: Bool = false) async throws -> URL {
        let provider = AnchorProvider(anchor: anchor)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? AuthError.message("Microsoft sign-in failed."))
                }
            }
            session.presentationContextProvider = provider
            // Microsoft's own cookies: an already signed-in account is offered in the picker.
            session.prefersEphemeralWebBrowserSession = ephemeral
            objc_setAssociatedObject(session, &anchorKey, provider, .OBJC_ASSOCIATION_RETAIN)
            session.start()
        }
    }

    private static var anchorKey = 0

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor
        init(anchor: ASPresentationAnchor) { self.anchor = anchor }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    }

    // MARK: PKCE

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
