import GameController

/// Game controllers (Xbox, PlayStation, Switch Pro, MFi…) for the game: the GameController
/// framework's current controller, its whole state sent to the game on every change
/// (horizon_ios_pad_*, looked up in the loaded game framework by GameBridge; Rust:
/// horizon_client::gamepad::platform). gilrs has no iOS backend, so
/// this is the game's only way to a pad here; from there it plays as on desktop, with the same
/// bindings, menus and glyphs.
enum Controllers {
    private static var started = false
    private static var current: GCController?

    /// Starts following controllers; call once, before the game starts.
    static func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { note in
            attach(note.object as? GCController)
        }
        center.addObserver(forName: .GCControllerDidStopBeingCurrent, object: nil, queue: .main) { note in
            guard let gone = note.object as? GCController, gone === current else { return }
            detach()
            // Another one still connected takes over.
            attach(GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil })
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
            guard let gone = note.object as? GCController, gone === current else { return }
            detach()
        }
        attach(GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil })
    }

    private static func attach(_ controller: GCController?) {
        guard let controller, controller !== current, let pad = controller.extendedGamepad else { return }
        detach()
        current = controller
        let name = controller.vendorName ?? controller.productCategory
        name.withCString { GameBridge.pad?.connected(family(of: controller), $0) }
        pad.valueChangedHandler = { pad, _ in send(pad) }
        send(pad)
    }

    private static func detach() {
        guard let old = current else { return }
        old.extendedGamepad?.valueChangedHandler = nil
        current = nil
        GameBridge.pad?.disconnected()
    }

    /// The glyph family: 0 Xbox, 1 PlayStation, 2 Nintendo, 3 unknown.
    private static func family(of controller: GCController) -> Int32 {
        switch controller.extendedGamepad {
        case is GCDualSenseGamepad, is GCDualShockGamepad: return 1
        case is GCXboxGamepad: return 0
        default:
            let name = "\(controller.productCategory) \(controller.vendorName ?? "")".lowercased()
            if name.contains("switch") || name.contains("joy-con") || name.contains("nintendo") { return 2 }
            if name.contains("dualsense") || name.contains("dualshock") || name.contains("playstation") { return 1 }
            if name.contains("xbox") { return 0 }
            return 3
        }
    }

    /// Buttons by position, in gamepad::Button's bit order: A is the bottom face button (south).
    private static func send(_ pad: GCExtendedGamepad) {
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.leftShoulder, pad.rightShoulder, pad.leftTrigger, pad.rightTrigger,
            pad.buttonOptions, pad.buttonMenu, pad.leftThumbstickButton, pad.rightThumbstickButton,
            pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right,
        ]
        var bits: UInt32 = 0
        for (i, button) in buttons.enumerated() where button?.isPressed == true {
            bits |= 1 << UInt32(i)
        }
        GameBridge.pad?.state(bits,
                               pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                               pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value,
                               pad.leftTrigger.value, pad.rightTrigger.value)
    }
}
