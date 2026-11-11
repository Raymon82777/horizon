# Horizon for iOS (fork layer)

Everything iOS lives in this folder, so pulling the newest upstream Horizon is a plain merge.

```
ios/
  App/                 SwiftUI launcher (xcodegen project.yml); owns UIApplicationMain + UIScene
  rust/horizon-ios/    the game as a framework the app loads at Play: horizon_ios_run, controllers
  rust/horizon-ios-tools/  the launcher's helpers, linked into the app: resources, unzip, mod checks
  rust/horizon-facts/  resources without Java: pack-facts (computer) / assemble (device)
  rust/winit/          winit 0.30.13 + embedded iOS mode (patched in via the root Cargo.toml)
  sync-upstream.sh     fetch + merge upstream/main + check the iOS build
  install.sh           build the app and install it on the iPhone (cable or Wi-Fi; --native builds
                       each instance's native mods)
  remote-install.sh    install from anywhere over Tailscale (an Install page on the tailnet)
  native-build.py      each instance's native mods, applied with horizon-mixins and built for iOS
  package-game.sh      wraps a built game as HorizonGame*.framework
  ROADMAP.md           milestones toward a self-contained launcher
  SIGN_IN_SETUP.md     the Azure app and Mojang approval Microsoft sign-in needs
  IOS_SPIKE.md         the original feasibility spike and measurements
  THIRD_PARTY_NOTICES.md
```

Outside this folder the fork changes:

- **Root `Cargo.toml`**: two workspace members (`ios/rust/horizon-ios`, `ios/rust/horizon-facts`) and the `winit` patch line.
- **Platform fixes in upstream crates**: small `cfg` gates (Metal-only backends, no Vulkan or arboard on iOS, `task_info` memory, no fixed window size). These are being sent upstream (horizon-rust/horizon#14779, `pr-drafts/`). Each one that merges drops out of this fork's diff.
- **Hooks with no upstream use yet**: `entry::set_args`/`args` (the host passes the command line) and logging the loading-screen error before exiting.
- **`.github/workflows/ios-upstream-check.yml`**: a nightly merge-and-build check that runs only on this fork.

## Updating to the newest Horizon

```sh
git switch ios-main
ios/sync-upstream.sh        # fetch, merge upstream/main, check the iOS build
git push fork ios-main
```

Then run `ios/install.sh`: the game is compiled into the app.

Always merge, never rebase: ios-main is shared history. If a merge conflicts, it's in one of the files listed above. Keep upstream's change and re-apply the iOS `cfg` gate.

## Building the app

```sh
ios/install.sh --launch     # build, install on the first reachable iPhone (else iPad), open it
```

`--device NAME|UDID` (or `HORIZON_IOS_DEVICE`) picks another device, and `--debug` makes a Debug build. The phone has to be paired with this Mac. For Wi-Fi installs, tick **Connect via network** for it in Xcode → Window → Devices and Simulators, once.

The build runs `build-rust.sh` (`cargo build --release -p horizon-ios --target aarch64-apple-ios`) first. It bundles the facts pack from `.mc/facts/horizon-facts-26.3.zip`, which you build once with:

```sh
cargo run --release -p horizon-facts -- pack-facts --resources .mc/resources \
  --client-jar .mc/versions/26.3/26.3.jar --assets-dir .mc/assets --out .mc/facts/horizon-facts-26.3.zip
```

## Installing without a cable

```sh
ios/remote-install.sh          # build, then serve an Install page on the tailnet
ios/remote-install.sh --stop   # stop serving
```

On the iPhone, with Tailscale on, open `https://<this Mac>.<tailnet>.ts.net/horizon/` in Safari and tap Install. This needs HTTPS Certificates turned on for the tailnet. `devicectl` can't install over Tailscale, because it finds devices by Bonjour.

## Native mods

Native mods are patches to the game's source, so each instance's set is compiled into a game framework of its own on the Mac. On the phone: an instance's page → Native mods → Add. Then on the Mac, with the phone connected:

```sh
ios/install.sh --native --trust-native-code
```

Native mods aren't sandboxed, so building them is the player's decision (`--trust-native-code`). A mod that doesn't apply to this fork's source is left out, and the phone shows it under "Left out".
