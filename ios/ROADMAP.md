# Horizon for iOS: self-contained launcher roadmap

Fork: `Raymon82777/horizon`, long-lived branch **`ios-main`** (built on the spike in `IOS_SPIKE.md` (in this folder)). Upstream-able platform fixes go out as small PRs (`pr-drafts/`); iOS-only pieces live here.

**Goal:** one iPhone/iPad app. Sign in with Microsoft, download Minecraft 26.3 for an account that owns it, assemble Horizon's resources on the device, and play. No computer, no JVM, no JIT.

## Architecture

```
SwiftUI app (ios/App)            owns UIApplicationMain + UIScene (iOS 27 requires it)
  ├─ Launcher UI                 sign-in, download/assemble progress, worlds, settings
  ├─ Auth (Swift)                ASWebAuthenticationSession → MSA → XBL → XSTS → Minecraft token
  ├─ Downloader (Swift or Rust)  version JSON, client jar, asset objects (Mojang, owner only)
  └─ Play → horizon_ios_run()    ios/rust/horizon-ios (staticlib) → horizon-client
                                   └─ winit embedded mode (ios/rust/winit): the game's window
                                      attaches to the app's UIWindowScene; the game turns the
                                      main run loop from then on
Resources
  ├─ player's own: client jar + asset store (downloaded on the device)
  └─ facts pack: the Java-derived tables (horizon-facts pack-facts on a computer, once per
     version; published privately, SHA-256 pinned) → `horizon-facts assemble` on the device
```

## Milestones

### M1: the SwiftUI app hosts the game (done)
- [x] winit 0.30.13 vendored with an embedded iOS mode (no `UIApplicationMain`, windows attach to the host's scene, nested main run loop)
- [x] `ios/rust/horizon-ios`: static library, `horizon_ios_run(argc, argv)`; `entry::set_args` replaces the process command line
- [x] `ios/App`: xcodegen SwiftUI app with a UIScene lifecycle, memory entitlements, 64 MiB main stack; Play with world, seed, mode and render distance
- [x] Runs on the iPhone with resources copied in: a real iOS 27.2 SDK build with a UIScene lifecycle, no `vtool` stamp (2026-11-10)
- [x] Fill the whole screen (winit's `inner_size` is the whole view, as 0.31's `surface_size`)
- [x] Lifecycle: winit sends `Focused` on resign / become active (the game pauses, `pauseOnLostFocus`); the world saves when the app enters the background (`Occluded(true)`), so closing it from the app switcher keeps everything

### M2: Microsoft sign-in
- [ ] **Ray:** register an Azure app (personal Microsoft account, public client, redirect `horizon-ios://auth`), then **ask Mojang to approve the app ID for the Minecraft services API**. New app IDs get 403 from `api.minecraftservices.com` until approved, and upstream forbids borrowing another launcher's ID.
- [x] Swift (`ios/App/Sources/Auth/`): ASWebAuthenticationSession (auth code + PKCE), XBL → XSTS → `login_with_xbox`, entitlement check, profile; tokens in the Keychain; several accounts; renewal and owner check at every Play. Untested against the live services until the Azure app is approved (`ios/SIGN_IN_SETUP.md`)
- [x] Hand the session to the game the way the desktop launcher does (`--session-file`, 0600 in Caches, read once and deleted)

### M3: download the game on the device
- [ ] Owner-gated: only after the entitlement check passes (upstream's rule, #4942)
- [ ] Version manifest → 26.3 JSON → client jar (SHA-1) and asset index and objects (about 480 MB, resumable, SHA-1 per object), into the app's Application Support
- [ ] Libraries aren't needed on the device (no JVM); only what `assemble` reads

### M4: assemble resources without Java (#1750's design) (done on the device, 2026-11-10)
- [x] `horizon-facts pack-facts`: package only the computed tables (the data generator's reports plus the 8 exporters' output, the files in `.mc/resources` that don't come from the jar or asset store) as `horizon-facts-26.3.zip` with a SHA-256
- [x] `horizon-facts assemble` as a library (`Sources { facts, client_jar, asset_index }`), called from `horizon-ios`: extracts the player's jar and assets, adds the facts and sounds, stamps `horizon-prepare.json`
- [ ] Facts hosting: a release asset on the private fork for now (personal use); public distribution waits for upstream's legal decision on #1750
- [x] Check: assembled resources equal prepared-on-Mac ones (every file SHA-256 checked against the manifest; Mac round-trip diff is empty). The launcher's Build resources and Play work on the iPhone.
- [ ] Note: the worldgen/*.json and damage-types.json bundles are copied from the prepared tree although they derive from the jar; a public facts pack should regenerate them on assemble instead.

### M5: play on a phone
- [x] Touch (`crates/horizon-client/src/game/touch_input.rs`): upstream's touch layout and aim helpers, driven through the pad's paths (`input_move`, `input_look`, `pad_action`). Joystick, drag to look, tap to use, hold to mine, layout buttons, hotbar taps; a finger is the mouse in menus
- [x] On-screen keyboard bar (winit): Esc and Hide over the keyboard, Return as Enter
- [x] Two-finger scroll in menus (a mouse wheel); taps click on lift, drags press on first move
- [x] Touch layout editor in the launcher (Settings → Edit touch layout): move, resize, opacity, look speed; saved as `touch-controls.json` in the game's own layout format, which the game loads at start
- [ ] GameController (`GCController`) and Bluetooth keyboard and mouse (`GCMouse`, pointer lock)
- [ ] Phone defaults: GUI scale, resolution scale, SDR versus HDR, 120 Hz pacing, battery mode; safe areas

### M6: polish
- [ ] UIPasteboard clipboard, AVSpeechSynthesizer narrator
- [x] Launcher tabs (`ios/App/Sources/Screens/`): Worlds (play, new, rename, duplicate, delete, zip import and export), Packs & mods (resource packs, shader packs, `.hmod` import and delete), Logs (latest log, crash reports), Settings (accounts, rebuild resources, storage, about)
- [x] App icon (original pixel-art sunset, `ios/tools/make-icon.swift`), dark launch screen, version 0.2.0; Files-app sharing and above-60 Hz keys in `ios/App/Info.plist`
- [x] Play tab: seed and mode only for a new world
- [x] `ios/install.sh`: one command builds the Rust library and the app and installs it (cable or Wi-Fi)

## Known platform constraints
- No JIT: Horizon's wasm mods need an interpreter runtime on iOS (out of scope for now).
- No subprocesses: dedicated server, "open folder", anything that runs `Command` gets stubbed or replaced.
- The main thread runs the game: anything the launcher needs afterwards must come from the game's UI.
