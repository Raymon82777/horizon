import Foundation

/// Starts the Rust game. The game's window attaches to this app's scene (winit's embedded iOS
/// mode) and covers the launcher; from then on the game owns the main run loop.
enum GameBridge {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func run(arguments: [String]) {
        // Relative --resources/--game-dir/--home resolve here.
        FileManager.default.changeCurrentDirectoryPath(documents.path)
        // Start outside the button's event callout and outside GCD's main queue: the game turns
        // the main run loop itself and never returns, and main-queue work must keep running.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            // Never freed: the game keeps running until the process ends.
            let pointers = arguments.map { UnsafePointer(strdup($0)) }
            pointers.withUnsafeBufferPointer { buffer in
                horizon_ios_run(Int32(buffer.count), buffer.baseAddress)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
