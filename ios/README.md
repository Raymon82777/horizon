# Horizon for iOS (fork layer)

Everything iOS lives in this folder, so pulling the newest upstream Horizon is a plain merge.

```
ios/
  App/                 SwiftUI launcher (xcodegen project.yml); owns UIApplicationMain + UIScene
  rust/horizon-ios/    the game as a static library: horizon_ios_run, horizon_ios_assemble
  rust/horizon-facts/  resources without Java: pack-facts (computer) / assemble (device)
  rust/winit/          winit 0.30.13 + embedded iOS mode (patched in via the root Cargo.toml)
  sync-upstream.sh     fetch + merge upstream/main + check the iOS build
  install.sh           build the app and install it on the iPhone
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
