# Microsoft sign-in: what Ray registers

The app's sign-in code is done (`ios/App/Sources/Auth/`). It needs this fork's own Azure app, approved by Mojang. Horizon's rules (`docs/forking.md`, "Microsoft sign-in in a fork") don't allow using Horizon's client ID, or any other launcher's, including Amethyst's. Until these steps are done, the app shows "Microsoft sign-in isn't set up in this build yet" and plays offline.

## 1. Register the Azure app (about 5 minutes)

1. Go to https://portal.azure.com and sign in with your Microsoft account. A free account works; no subscription is needed for app registrations.
2. Go to **Microsoft Entra ID → App registrations → New registration**.
   - **Name:** `Horizon for iOS`. Players see this name on Microsoft's consent page.
   - **Supported account types:** **Personal Microsoft accounts only**.
   - **Redirect URI:** platform **Public client/native (mobile & desktop)**, value `horizon-ios://auth`.
3. Select **Register**. On the overview page, copy the **Application (client) ID** (a GUID).
4. Leave **API permissions** alone. The app asks for `XboxLive.signin offline_access` when you sign in, and needs no client secret (it's a public client).

## 2. Ask Mojang to approve the app ID (days to weeks)

New Azure apps get HTTP 403 from the Minecraft services until Mojang approves them. Apply at https://aka.ms/mce-reviewappid (Minecraft Java "App ID review") with:

- **Client ID:** the GUID from step 1.
- **App name:** Horizon for iOS.
- **Project URL:** https://github.com/Raymon82777/horizon
- **Description:** "Personal iOS port of Horizon, an open-source Minecraft Java Edition client written in Rust. Signs the owner in to verify they own the game and to join online-mode servers."

Until approval comes through, signing in works up to the Minecraft step, then says "This app is not approved by Mojang yet".

## 3. Put the client ID in the app

Send the client ID to Claude, or set it yourself in `ios/App/Sources/Auth/AuthConfig.swift`:

```swift
static let clientID = "00000000-0000-0000-0000-000000000000"
```

Client IDs are public (every sign-in URL shows them), so it can be committed. Then rebuild and reinstall the app.

## How it works

- Sign-in uses Microsoft's page in a secure browser sheet (authorization code with PKCE). Then it gets Xbox Live, XSTS and Minecraft tokens, checks that the account owns Java Edition (Game Pass counts), and reads the profile.
- Tokens are stored in the iOS Keychain (this device only), one item per account. `accounts.json` in Application Support keeps only names and UUIDs.
- Every Play renews the token and checks ownership again. With no internet, the last answer stands. The session goes to the game as a private file in Caches; the game reads it once, deletes it, and refuses one older than two minutes (`--session-file`, as upstream's launcher does it).
- You can sign in several accounts. The ⋯ menu next to the account switches between them, adds another, or signs out (which deletes that account's Keychain item).
