import SwiftUI

@main
struct HorizonApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
