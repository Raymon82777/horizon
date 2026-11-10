import Foundation

/// The fork's own Azure app (docs/forking.md: never Horizon's or another launcher's client ID).
/// Client IDs are public, so it lives in the source. Empty: sign-in isn't configured, and the
/// launcher says so. Setup steps: ios/SIGN_IN_SETUP.md.
enum AuthConfig {
    static let clientID = ""

    /// The redirect registered on the Azure app ("Mobile and desktop applications").
    static let redirectURI = "horizon-ios://auth"
    static let callbackScheme = "horizon-ios"
    static let scope = "XboxLive.signin offline_access"

    static var configured: Bool { !clientID.isEmpty }
}
