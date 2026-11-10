# Third-party code in the iOS layer

The repository's own notices are in `../THIRD_PARTY_NOTICES.md`; this file covers only what the
iOS fork adds under `ios/`.

## winit

`ios/rust/winit` is [winit](https://github.com/rust-windowing/winit) 0.30.13 by the winit
contributors, with an embedded iOS mode added for the iOS app (`ios/App`): when the host app
already runs `UIApplicationMain`, `EventLoop::run` replays the launch and keeps the main run loop
turning instead of starting one, and windows attach to the app's first `UIWindowScene`
(`src/platform_impl/ios/event_loop.rs`, `window.rs`). It is licensed under Apache-2.0
(`LICENSE` in that folder).
