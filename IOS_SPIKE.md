# Horizon on iOS: feasibility spike (interim)

Date: 2026-11-10. Horizon checkout: `1453e0e61` (main, shallow clone of horizon-rust/horizon). Toolchain: Rust 1.99.1 stable (Homebrew rustup) with `aarch64-apple-ios`, Xcode 27.2.

**Status: interim.** Steps 1 and the static half of step 2 are done. No compile has been run yet: the `cargo check --target aarch64-apple-ios` call was refused by Claude Code's auto-mode permission check, because building this repo runs third-party build scripts (ring, mimalloc, libsqlite3-sys, opus, objc2 and so on). Everything below about build blockers comes from reading `cargo tree --target aarch64-apple-ios`, the manifests and the crate sources, not from compiler output. Steps 3–4 (device run, FPS, memory, thermals) are not started.

## 1. Existing upstream work

- ROADMAP lists "Android, iOS and the browser" as a **Later** long-term goal. Maintainer line on every mobile issue: "the desktop game comes first", and any port must keep the Microsoft sign-in and ownership gate.
- **iOS:** only [horizon-rust/horizon#1813](https://github.com/horizon-rust/horizon/issues/1813) (merged): `horizon-dualsense` gates `hidapi` and `cpal` off on iOS. Nobody ran an iOS build, by the PR's own account. The manifest comments still mention a `horizon-gamecontroller` crate that already compiled empty on iOS, but that crate is no longer in the tree. [#7188](https://github.com/horizon-rust/horizon/issues/7188) asks for keyboard and mouse on iOS. It was closed in a cleanup, then someone asked for it to be reopened.
- **Android is far ahead, and iOS can reuse most of it.** Starling (Vasysik/horizon-android, MIT) and d3xc0's branch run on phones. Upstream main has already merged the Android touch stack in small PRs (#12299 touch layout model, #12880 touch aim, #13553 touch state machine, #13659 input runtime, #13679 touch input). Touch drawing (#13681) is in review, and a layout editor and custom buttons are stacked drafts. The code is in `crates/horizon-client-render/src/touch/`. `horizon-threads` has Android gates for worker priority and process memory (#1751).
- [#1750](https://github.com/horizon-rust/horizon/issues/1750) (open): "prepare without Java" (publish the computed tables, then assemble from the player's own jar and assets). An iOS port would need this, because `horizon-prepare` runs Mojang's code on JDK 25. The maintainer has not yet settled the legal question.

## 2. What blocks `aarch64-apple-ios` (static analysis)

The dependency tree resolves for the iOS target: 670 crates, every source fetched. Blockers and likely problems:

| Item | Where | Problem on iOS | Fix |
| --- | --- | --- | --- |
| `arboard` 3.7 (clipboard) | `horizon-client-input` (unconditional, with `wayland-data-control`) | Has no iOS backend. `cfg(unix, not macos/android)` falls through to its **Linux X11/Wayland** module, so at best you get a useless X11 client and at worst a compile failure. | Gate it with `cfg(not(target_os = "ios"))` and add a `UIPasteboard` clipboard through `objc2-ui-kit`. Small. |
| `wgpu` `gles` feature | `horizon-client`, `horizon-client-lib`: `cfg(not(target_os = "macos"))` | iOS matches "not macOS", so it asks for the GL backend. wgpu has no GLES on Apple without ANGLE. It is probably ignored, but it may pull in EGL or fail. | Change the gate to `cfg(not(target_vendor = "apple"))`. One line ×2. |
| `wgpu` `vulkan` feature | same | Unused on iOS. Metal is the path, through vendored `third_party/wgpu-hal` and `objc2-metal`, both present. | None needed. |
| Narrator (TTS) | `horizon-narrator` | Only Windows, Linux (speech-dispatcher through libloading) and macOS (`NSSpeechSynthesizer`, AppKit) backends. iOS gets none, so it should compile as a no-op. | Optional: `AVSpeechSynthesizer`. |
| macOS-only code paths | 10 files in `horizon-client/src` gate on `target_os = "macos"` (window handler, pointer capture, clipboard, split windows, entry, startup menu…) | iOS gets the "other" branch, which usually means Linux or Windows assumptions. | Check each one once a compile runs. Medium. |
| `std::process::Command` | telemetry, mod API, world management (open folder), native/dedicated server, pack folder | iOS can't spawn processes (no fork or exec in the sandbox). The dedicated-server and "open folder" paths would fail at runtime. The integrated server runs in-process. | Stub these on iOS, or use `UIApplication.open` for links. Small to medium. |
| winit event loop | `game/resource_loader.rs:301`, `loading_screen.rs:32`, `no_resources.rs:35`: `EventLoop::new()?.run_app(..)`, then code that runs **after** the loop returns (saves settings, writes the report, leaves fullscreen) | On iOS, `run_app` calls `UIApplicationMain` and **never returns**, and a process can create only one event loop. Today's main path uses a single loop (Loading → Ready), so it can start, but the code after the loop never runs. | Move saving to the suspend and terminate events (`suspended`, `exiting`, `memory_warning`). Medium. |
| Paths | `HOME`, `.minecraft`, `.local/` resources, `--minecraft-dir` / `HORIZON_MINECRAFT_DIR` | The app sandbox has no `~/.minecraft`. | Point `HORIZON_MINECRAFT_DIR` and the resources directory at the app's Documents folder, and enable Files-app sharing (`UIFileSharingEnabled`). Small. |
| Controllers | `gilrs` 0.11 → `gilrs-core` 0.6.8 | No iOS backend. It falls back to the dummy platform, so it compiles but sees no pads. | Feature off for the first build, or a `GCController` backend later. |
| Audio | `cpal` 0.16 (feature `audio`) | Has an iOS CoreAudio backend. Needs an `AVAudioSession` category. | Probably works. Turn it off for the first build to cut risk. |
| `horizon-dualsense` | already iOS-gated (#1813) | none | — |
| Mods runtime (wasm) | `horizon-mods` built without the `mods` feature | A Wasm JIT (wasmtime/cranelift) would need W^X memory iOS doesn't give. It isn't compiled by default. | Keep it off, or use a Wasm interpreter later. |
| C build scripts | `ring`, `libmimalloc-sys`, `libsqlite3-sys`, `rusty-opus` | All of these cross-compile to iOS normally with Xcode's clang. | Unverified until a build runs. |
| `horizon-prepare` | separate crate | Needs JDK 25 and Mojang's server jar. It won't run on the phone. | Prepare on the Mac and copy `.local/` to the device. For players: #1750. |

**Rough estimate:** a compile-clean `horizon-client` for `aarch64-apple-ios` is about 1–3 days of `cfg` gating (arboard, the wgpu gate, process spawning, macOS-only branches), with no gameplay changes. `#![forbid(unsafe_code)]` in the client is not an obstacle, because winit already wraps UIKit.

## 3. Planned host-app approach (not yet run)

winit 0.30 supports iOS directly: a Rust `bin` built for `aarch64-apple-ios` goes inside a `.app` (Info.plist, `UILaunchScreen`, `UIFileSharingEnabled`, the memory entitlements from Amethyst) and is signed with team BFH3MLCK9L. winit's `run_app` starts `UIApplicationMain`, and wgpu's Metal surface comes from winit's `UIView`/`CAMetalLayer`. An xcodegen project is only needed for convenience. Assets: run `horizon-prepare` on the Mac against Ray's desktop 26.3 install, then copy `.local/` and the client jar and asset index into the app's Documents folder.

## 4. Measurements

None yet.

## 5. Early read on the question

- **No JIT is a real structural win.** Horizon is AOT native code, so it needs neither JIT26 nor the debugger-attach dance. It is also sideloadable without a debugger, which Java Minecraft on iOS is not.
- On desktop it already uses less memory than vanilla (1.1–1.7 GB working set against 1.9–2.9 GB) and draws more frames, and the Metal path skips the MoltenVK translation layer.
- The hard parts for a *playable* port are not rendering: touch UI (mostly done upstream for Android and portable), Microsoft sign-in in an app (ASWebAuthenticationSession), and getting assets without Java (#1750).
- **Upstream versus fork:** the upstream culture accepts small, `cfg`-gated, desktop-neutral PRs (see #1813, #1751 and the Android input series), and the touch stack is landing on main. Small upstream PRs for compile gates and the iOS platform layer are the better route. Keep the app wrapper, signing and packaging in a separate repo (or a fork branch) until upstream wants official iOS packaging. Confirm after the device run.

## Next steps (blocked on permission)

1. Allow `cargo check` / `cargo build` for this repo (it runs crate build scripts). Then fix the compile blockers locally (no push).
2. Wrap `horizon-client` in a signed `.app`, install on the iPhone 17 Pro, and render a world from prepared 26.3 resources.
3. Measure FPS, memory and thermals at render distance 6, 12 and 16.
