import Foundation

/// Starts the Rust game: loads the instance's game framework (HorizonGame.framework, or the one
/// ios/native-build.sh built with its native mods) and calls its horizon_ios_run. The game's
/// window attaches to this app's scene (winit's embedded iOS mode) and covers the launcher; from
/// then on the game owns the main run loop. One process plays one framework: quitting the game
/// ends the app.
enum GameBridge {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The plain game, without native mods.
    static let baseGame = "HorizonGame"

    /// The game's controller entry points, once a framework is loaded.
    struct Pad {
        let connected: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
        let disconnected: @convention(c) () -> Void
        let state: @convention(c) (UInt32, Float, Float, Float, Float, Float, Float) -> Void
    }
    static private(set) var pad: Pad?

    /// Whether the app carries the game framework `name`.
    static func hasGame(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: frameworkBinary(name).path)
    }

    private static func frameworkBinary(_ name: String) -> URL {
        Bundle.main.privateFrameworksURL!.appendingPathComponent("\(name).framework/\(name)")
    }

    private typealias Run = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> Void

    /// Starts `game` (a framework's name) with `arguments`. Throws if it can't be loaded.
    static func run(arguments: [String], game: String = baseGame) throws {
        guard let handle = dlopen(frameworkBinary(game).path, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw AuthError.message("Couldn't load the game (\(game)): \(why)")
        }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let run = symbol("horizon_ios_run", as: Run.self) else {
            throw AuthError.message("\(game) has no horizon_ios_run.")
        }
        if let connected = symbol("horizon_ios_pad_connected", as: (@convention(c) (Int32, UnsafePointer<CChar>?) -> Void).self),
           let disconnected = symbol("horizon_ios_pad_disconnected", as: (@convention(c) () -> Void).self),
           let state = symbol("horizon_ios_pad_state", as: (@convention(c) (UInt32, Float, Float, Float, Float, Float, Float) -> Void).self)
        {
            pad = Pad(connected: connected, disconnected: disconnected, state: state)
        }
        // Relative --resources/--game-dir/--home resolve here.
        FileManager.default.changeCurrentDirectoryPath(documents.path)
        // Controllers reach the game through the GameController framework.
        Controllers.start()
        // Start outside the button's event callout and outside GCD's main queue: the game turns
        // the main run loop itself and never returns, and main-queue work must keep running.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            // Never freed: the game keeps running until the process ends.
            let pointers = arguments.map { UnsafePointer(strdup($0)) }
            pointers.withUnsafeBufferPointer { buffer in
                run(Int32(buffer.count), buffer.baseAddress)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
