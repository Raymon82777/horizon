# Horizon on iOS: feasibility spike

Date: 2026-11-10. Horizon `1453e0e61` (main, horizon-rust/horizon) plus local branch `ios-spike` (commit `357c8b40c` and this report, **not pushed**). Rust 1.99.1, Xcode 27.2. Device: iPhone 17 Pro (A19 Pro, 6 cores, 2622×1206 @ 3×, 120 Hz), iOS 27.0.1.

## Result in one paragraph

**Yes: Horizon builds for `aarch64-apple-ios`, runs on the iPhone, and renders vanilla 26.3 worlds through Metal with no JIT.** It took about 15 small `cfg` and platform fixes (no gameplay code touched) plus a signed `.app` wrapper. Horizon's own `--benchmark standard` (the same seed-1234 village/forest/ocean/mountain flight as the desktop figures in the README) **holds a locked 60 FPS at render distance 8**. At 12 and 16 it averages 59–60 FPS with 1% lows of 35–53, limited by the GPU at native resolution with HDR10 output. The memory footprint at RD 16 is about 1.4 GiB, peaking at 1.6 GiB. There are no touch controls yet: the run needs no input because the benchmark flies the camera itself.

## 1. Upstream state (what already existed)

- ROADMAP: "Android, iOS and the browser" is a **Later** long-term goal. Maintainer line: "desktop game comes first", and any port keeps the Microsoft sign-in and ownership gate.
- iOS: only [horizon-rust/horizon#1813](https://github.com/horizon-rust/horizon/issues/1813) (merged): `horizon-dualsense` compiles on iOS. No one had built or run the client on iOS. [#7188](https://github.com/horizon-rust/horizon/issues/7188) asks for keyboard and mouse on iOS.
- Android is far ahead, and iOS can reuse most of it. The Android touch stack is landing on main in small PRs (#12299 layout model, #12880 aim, #13553 touch state machine, #13659 input runtime, #13679 touch input; #13681 touch drawing in review; layout editor and custom buttons stacked as drafts) in `crates/horizon-client-render/src/touch/`. Forks: Starling (Vasysik/horizon-android) and d3xc0's android-latest.
- [#1750](https://github.com/horizon-rust/horizon/issues/1750) (open): "prepare without Java". `horizon-prepare` runs Mojang's code on JDK 25, which a phone can't do. The maintainer still has to settle the legal question.

## 2. What blocked the iOS build, and the fixes (all on `ios-spike`)

| # | Blocker (symptom) | Fix in the spike | Upstreamable as is? |
| --- | --- | --- | --- |
| 1 | `horizon-hdr`: `wgpu::hal::api::Vulkan` missing (gated `not(macos)`, so iOS took the Vulkan path) | Gates changed to `not(target_vendor = "apple")`; wgpu `vulkan` feature only off Apple | Yes |
| 2 | `horizon-client-render/gfx/surface_setup.rs`: calls `open_vulkan_device` | Same gate | Yes |
| 3 | `horizon-threads`: `proc_pidinfo` / `proc_taskinfo` not in libc for iOS | iOS path through Mach `task_info(MACH_TASK_BASIC_INFO)` | Yes |
| 4 | `arboard` (clipboard) has no iOS backend and falls through to its Linux/Wayland code (`wayland-backend` fails) | `arboard` only `cfg(not(ios))`; an in-game clipboard stub on iOS | Yes, but `UIPasteboard` is better |
| 5 | `winit::platform::modifier_supplement` missing on iOS (keybinds) | iOS uses `logical_key` | Yes |
| 6 | Link: `___chkstk_darwin` undefined (rustc defaults to iOS 10.0, cc objects at 27.2) | `IPHONEOS_DEPLOYMENT_TARGET=17.0` (`ios/build.sh`) | Build setting |
| 7 | **iOS 27 kills apps that don't adopt the UIScene lifecycle** (`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`, SIGTRAP); winit 0.30's UIKit backend uses the app-delegate lifecycle | **Stopgap:** `vtool` stamps the binary as built with the iOS 26 SDK (`ios/package.sh`) | **No**. Needs UIScene support in winit (or an own UIKit shell). This is the biggest platform risk. |
| 8 | Renderer tries only Vulkan and GL ("No Vulkan or OpenGL graphics driver found"); `backend_order` special-cases `os == "macos"` | `os == "ios"` uses wgpu's default (Metal); API choices and the error text by `target_vendor = "apple"` | Yes |
| 9 | Main-thread stack overflow on starting the renderer (iOS main thread 1 MiB; macOS 8 MiB; winit has to run the game there) | `-Wl,-stack_size,0x4000000` on the final link (LC_MAIN 64 MiB) | Build setting |
| 10 | Silent exit 0: errors stored for after `run_app` are never logged, because `run_app` never returns on iOS | Log the loading error before `exit()` on iOS | Yes, plus save on `suspended` / `exiting` |
| 11 | Only the top-left corner shows: the window asks for 1156×700 points, larger than the 874×402-point screen | No `with_inner_size` on iOS (the window is the screen) | Yes |
| 12 | Paths: `~/.local/share/horizon` unwritable, iOS cwd is `/` | `main` changes into `$HOME/Documents`; the app passes `--resources resources --home . --game-dir .` | Partly. iOS defaults should go into `logging::game_home` |
| — | Narrator: "Unsupported platform ios" | Harmless (no-op) | `AVSpeechSynthesizer` later |
| — | `gilrs`: dummy backend on iOS | Compiles, sees no pads | `GCController` backend later |
| — | `cpal` audio | **Works** ("audio output Default Device 48000 Hz") | — |
| — | `std::process::Command` (dedicated server, open folder, telemetry) | Not hit in this spike | Stub on iOS |

Default features (`audio`, `controllers`, `horizon-extras`) build. The wasm mods runtime stays off (a Wasm JIT would need W^X, which iOS doesn't allow).

## 3. Host app and assets

- `ios/build.sh`: `cargo rustc --target aarch64-apple-ios -p horizon-client --profile release` with the deployment target and stack size. A full release build takes about 25 min from clean, about 4 min to relink. The binary is 84 MB.
- `ios/package.sh`: wraps the binary as `Horizon.app` (`ios/Info.plist`: landscape, `UIFileSharingEnabled`, `CADisableMinimumFrameDurationOnPhone`), embeds the profile, signs with the team in `ios/signing.env` and installs through `devicectl`. Bundle ID from `ios/signing.env`. Its App ID has **Increased Memory Limit + Extended Virtual Addressing**; the profile came from the xcodegen stub in `ios/stub`. No Xcode project is needed for the game itself: winit's `run_app` starts `UIApplicationMain`, and wgpu gets the `CAMetalLayer` from winit's `UIView`.
- Assets: there is no desktop install on this Mac, so the 26.3 client jar, version JSON, asset indexes and libraries came from **the owner's own Amethyst install on the iPhone** (`devicectl` copy from its data container). The only additions were the 26.3 server jar (from the URL in that version JSON, SHA-1 checked) and the stock LWJGL 3.4.3 jars that Amethyst replaces with its iOS build (SHA-1 checked). `horizon-prepare` ran on the Mac with Homebrew `openjdk@25` in 23 s and produced 221 MB of resources, copied to the app's Documents in about 70 s. No sounds were prepared, so the game is silent.
- All Mojang files and prepared resources sit in the git-excluded `.mc/` folder and are not committed.

## 4. Measurements (iPhone 17 Pro, release build, `--benchmark standard`)

Native 2622×1206, HDR10 (PQ) output, Fifo present (capped at 60, see below), 6 CPU threads, Metal on Apple A19 Pro GPU, multi-draw and occlusion culling on.

| Render distance | Scene | Avg FPS | 1% low | p99 ms | CPU p50 ms | GPU p50 ms | Chunks loaded in |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 8 | village | 59.99 | 59.3 | 16.8 | 3.3 | 6.3 | 15.4 s |
| 8 | forest | 59.99 | 59.4 | 16.8 | 2.9 | 6.6 | 13.9 s |
| 8 | ocean | 59.99 | 59.3 | 16.8 | 2.9 | 9.4 | 17.8 s |
| 8 | mountain | 59.99 | 59.3 | 16.9 | 2.5 | 7.7 | 23.6 s |
| 12 | village | 59.99 | 59.2 | 16.9 | 2.5 | 10.1 | 21.2 s |
| 12 | forest | 59.82 | 45.0 | 18.8 | 1.5 | 14.5 | 28.1 s |
| 12 | ocean | 59.89 | 46.6 | 19.6 | 1.7 | 13.8 | 30.3 s |
| 12 | mountain | 59.99 | 59.3 | 16.8 | 1.1 | 13.2 | 32.0 s |
| 16 | village | 59.99 | 49.7 | 19.5 | 1.8 | 13.5 | 27.5 s |
| 16 | forest | 58.95 | 34.7 | 23.4 | 1.5 | 14.2 | 44.5 s |
| 16 | ocean | 59.82 | 44.3 | 19.2 | 1.7 | 13.9 | 25.0 s |
| 16 | mountain | 59.98 | 53.3 | 18.1 | 2.3 | 14.3 | 34.3 s |

- **Startup:** title screen 5.8–6.9 s, in the world 24 s (RD 8) to 44 s (RD 16) from a fresh world.
- **Memory** (Instruments Activity Monitor, RD 16): physical footprint **median 1.39 GiB, peak 1.57 GiB**, with 30–32 threads. This is well inside the increased-memory-limit budget, and close to Horizon's desktop working set (1.1–1.7 GB).
- **CPU:** 25–160% of 600% during the flight. The CPU is nowhere near the limit (p50 1–3 ms a frame).
- **Thermals:** the device's thermal state was **"Serious" for the whole 3.5-minute RD 16 run under Instruments**. That came after about 25 minutes of back-to-back benchmark runs, with the phone tethered by USB. No run showed FPS falling over time, but a Serious state means iOS is already limiting clocks. A cold-device run would differ.
- **Not measured:** Java Minecraft through Amethyst at the same settings (no matched run here). 120 Hz: the cap is 60. wgpu's Fifo plus a CAMetalLayer without a `preferredFrameRateRange` / CADisplayLink at 120 likely explains it, so it's worth a look before any comparison.

**Reading:** at RD 8 the GPU has about 2.5× headroom over 60 FPS and the CPU about 5×. From RD 12 up, the frame is GPU-bound (13–14.5 ms of a 16.7 ms budget) at the full 3× resolution with HDR output. Horizon already has `resolutionScale`, upscaling and `batteryMode` settings, so 0.67× resolution and SDR are the obvious first levers for higher render distances and for heat.

## 5. Effort estimate to a playable port

| Work | Estimate | Notes |
| --- | --- | --- |
| Upstream the compile and run fixes (rows 1–5, 8, 10–12) | 2–4 days | Small `cfg` PRs, desktop-neutral, the shape upstream accepts |
| **UIScene lifecycle** (row 7) | 1–2 weeks | Patch winit's iOS backend (UIScene delegate, scene-attached UIWindow), or a small Swift/ObjC UIKit shell that hosts the `CAMetalLayer` and feeds events into the game. Blocks any non-hack build on iOS 27. |
| Lifecycle and persistence | 3–5 days | Save on `suspended` / `exiting` / memory warnings; no code after `run_app`; pause rendering in the background (iOS kills GPU work in the background) |
| Touch controls and UI | 2–4 weeks | Reuse the Android touch stack now on main (layout, aim, state machine, input runtime). iOS work: winit `Touch` events into it, safe areas and notch, GUI scale defaults, on-screen keyboard for chat and signs. Bluetooth keyboard and mouse (#7188) need pointer lock through `UIPointerInteraction` / `GCMouse`. |
| Controllers | 3–5 days | `GCController` backend for gilrs or Horizon's input layer |
| Microsoft sign-in | 1 week | `ASWebAuthenticationSession` for the OAuth device or code flow, Keychain for tokens, then the existing session and online-mode code. Must keep upstream's owner gate. |
| Assets without a desktop | 1–3 weeks, plus legal | After sign-in: download 26.3 client and assets from Mojang for an owning account (the launcher already does this on desktop). Preparation needs #1750 (published tables plus a local `assemble`) or another route, because the phone has no JDK. Copy-in through the Files app works as a dev path today. |
| Packaging and polish | 1 week | Xcode project or `xcodegen` for the app shell, icons, launch screen, 120 Hz frame pacing, resolution and HDR defaults for phones, thermal-aware presets |

**Total: about 2–3 months of one person to a playable port** that signs in, downloads and prepares, and has touch controls. That range assumes the Android touch work keeps landing upstream, and that #1750 or an equivalent gets settled; without it, "assets" is the long pole.

## 6. Native Horizon versus Java Minecraft on iPhone

- **No JIT, no debugger.** This is AOT native code: no JIT26, no debugger-attached launch, and no W^X tricks. It can be sideloaded or distributed like a normal app. That alone removes Amethyst's largest fragility.
- **Metal directly** through wgpu, with no MoltenVK or GL translation layer.
- **Resources:** a working set of about 1.4 GiB at RD 16, and a 60 FPS cap reached with CPU p50 under 3.5 ms.
- **What a native port doesn't get:** Java mods (Fabric and friends). Horizon has its own mod formats, and its Wasm mods need a runtime without a JIT on iOS.

## 7. Recommendation: upstream first, with a thin fork for the app shell

- **Upstream** the platform `cfg` fixes as small, separate PRs. They are desktop-neutral and match how #1813, #1751 and the Android input series were accepted. They also keep iOS compiling as main moves fast (the merge numbers are around #14000). Note that upstream is heavily agent-driven and gates contributions; PRs need `tools/pr_ready.py` output.
- **Keep in a fork or a separate repo for now:** the app shell (Info.plist, signing, packaging), the `vtool` SDK stamp, and anything iOS-only that upstream hasn't asked for. Upstream explicitly isn't taking official mobile packaging yet ("desktop game comes first"), and d3xc0's Android client went the same way: fork first, then small PRs.
- **UIScene support** belongs in winit itself (an upstream winit PR), which benefits everyone and keeps Horizon free of UIKit code.
- Before contributing anything upstream, confirm with the fork's owner. Nothing has been pushed, and no issues or PRs have been opened.

## How to reproduce

```sh
cd ~/Coding\ Projects/horizon-ios            # branch ios-spike
ios/build.sh release                          # aarch64-apple-ios horizon-client
ios/package.sh release --install              # Horizon.app on the iPhone
# resources: horizon-prepare on the Mac (JDK 25), then
xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer \
  --domain-identifier "$HORIZON_IOS_BUNDLE_ID" --source .mc/resources --destination Documents/resources
ios/bench.sh 8                                # --benchmark standard at RD 8; report in .mc/dev-out/bench/
```

Raw data: `.mc/dev-out/bench/rd{8,12,16}.json` (Horizon benchmark reports), `rd16.trace` (Instruments: Activity Monitor and Thermal State), console logs beside them.
