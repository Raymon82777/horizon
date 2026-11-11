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
  build-server.py      builds the phone's native mods on the Mac when the phone asks, over Tailscale
  package-game.sh      wraps a built game as HorizonGame*.framework
  ROADMAP.md           milestones toward a self-contained launcher
  signing.env.example  your Apple team and bundle ID: copy to signing.env (never committed)
  signing.sh           reads signing.env for every script; generate.sh makes the Xcode project with it
  SIGN_IN_SETUP.md     the Azure app and Mojang approval Microsoft sign-in needs
  IOS_SPIKE.md         the original feasibility spike and measurements
  THIRD_PARTY_NOTICES.md
```

Outside this folder the fork changes:

- **Root `Cargo.toml`**: two workspace members (`ios/rust/horizon-ios`, `ios/rust/horizon-facts`) and the `winit` patch line.
- **Platform fixes in upstream crates**: small `cfg` gates (Metal-only backends, no Vulkan or arboard on iOS, `task_info` memory, no fixed window size). These are being sent upstream (horizon-rust/horizon#14779, `pr-drafts/`). Each one that merges drops out of this fork's diff.
- **Hooks with no upstream use yet**: `entry::set_args`/`args` (the host passes the command line) and logging the loading-screen error before exiting.
- **`.github/workflows/ios-upstream-check.yml`**: a nightly merge-and-build check. It runs only in a repository that turns it on: `gh variable set IOS_UPSTREAM_CHECK --body true`.

## Updating to the newest Horizon

```sh
git switch ios-main
ios/sync-upstream.sh        # fetch, merge upstream/main, check the iOS build
git push fork ios-main
```

Then run `ios/install.sh`: the game is compiled into the app.

Always merge, never rebase: ios-main is shared history. If a merge conflicts, it's in one of the files listed above. Keep upstream's change and re-apply the iOS `cfg` gate.

## Set up signing

Nothing in the repository is tied to one person's Apple account: every build signs with the settings in `ios/signing.env`, a file of your own that git ignores. Set it up once after cloning:

```sh
cp ios/signing.env.example ios/signing.env
```

Then fill in:

| Setting | What to put | Where to find it |
|---|---|---|
| `HORIZON_IOS_TEAM` | Your Team ID, 10 letters and digits | Xcode → Settings → Accounts → your Apple ID → the team. Or developer.apple.com → Account → Membership details. A free account has a "Personal Team"; its ID is in the same place |
| `HORIZON_IOS_BUNDLE_ID` | A bundle ID of your own, like `com.yourname.horizon` | You choose it. It must be unique to you: a bundle ID belongs to one team, so you can't reuse someone else's |
| `HORIZON_IOS_PAID` | `1` with a paid Apple Developer Program membership, `0` with a free Apple account | |
| `HORIZON_IOS_DEVICE` | Optional: the UDID of the iPhone or iPad to install on by default | `xcrun devicectl list devices` |
| `HORIZON_IOS_IDENTITY` | Only for the old `ios/package.sh` spike path | `security find-identity -v -p codesigning` |

Also sign in to Xcode with that Apple ID (Xcode → Settings → Accounts) and turn on Developer Mode on the phone (Settings → Privacy & Security → Developer Mode). The install scripts read `signing.env` themselves. To open the project in Xcode, generate it with your settings first:

```sh
ios/generate.sh && open ios/App/Horizon.xcodeproj
```

Run `ios/generate.sh` again after changing `signing.env`. A setting exported in the shell wins over the file, for a one-off build: `HORIZON_IOS_PAID=0 ios/install.sh`.

### Free Apple account

With `HORIZON_IOS_PAID=0` the app is signed without the two memory entitlements, Increased Memory Limit and Extended Virtual Addressing, which only paid memberships can have. It builds and runs the same, but iOS gives it less memory: keep the render distance low, or iOS closes the game. Settings → Diagnostics shows whether the app has them. Apple's other limits for free accounts apply too:

- The app stops opening after 7 days: install it again (worlds and settings are kept).
- The first time, trust your Apple ID on the phone: Settings → General → VPN & Device Management.
- At most 3 apps from free accounts on a device at once, and 10 new bundle IDs a week.
- Installing over the air (`remote-install.sh`, Remote build) hasn't been tried with a free account. Install by cable or Wi-Fi with `install.sh` if it doesn't work.

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

Away from the Mac, over Tailscale: leave this running on the Mac (awake, on power)

```sh
ios/build-server.py --trust-native-code
```

and on the phone, Native mods → Remote build → Build on my Mac. The Mac builds every instance's set into a new app and serves it as `remote-install.sh` does; the phone shows the progress, then "Install the new build" opens the Install page in Safari. Only devices signed in to Tailscale as the Mac's own user can ask. The phone learns the Mac's address when the app is built on a Mac running Tailscale (`install.sh` or `remote-install.sh`), so install once that way first.

Native mods aren't sandboxed, so building them is the player's decision (`--trust-native-code`). A mod that doesn't apply to this fork's source is left out, and the phone shows it under "Left out".
