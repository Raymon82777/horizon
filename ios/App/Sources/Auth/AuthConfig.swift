import Foundation

/// The fork's own Azure app (docs/forking.md: never Horizon's client ID). Client IDs are
/// public, so it lives in the source. Setup steps: ios/SIGN_IN_SETUP.md.
enum AuthConfig {
    static let clientID = ""

    /// TEMPORARY, until the fork's own app is approved by Mojang: with no client ID of
    /// our own, sign in as Amethyst and PojavLauncher do, with the official Minecraft
    /// Launcher's legacy ID on login.live.com. It's Mojang's ID, not ours: Microsoft can block
    /// it at any time, and builds that use it mustn't be shared. Setting `clientID` above
    /// turns it off.
    static let legacyClientID = "00000000402b5328"
    static var legacy: Bool { clientID.isEmpty }
    static let legacyScope = "service::user.auth.xboxlive.com::MBI_SSL"
    static let legacyRedirect = "https://login.live.com/oauth20_desktop.srf"
    static let legacyCallbackScheme = "ms-xal-00000000402b5328"

    /// The redirect registered on the Azure app ("Mobile and desktop applications").
    static let redirectURI = "horizon-ios://auth"
    static let callbackScheme = "horizon-ios"
    static let scope = "XboxLive.signin offline_access"

    /// Sign-in is available: our own app, else the temporary legacy path.
    static var configured: Bool { true }
}
