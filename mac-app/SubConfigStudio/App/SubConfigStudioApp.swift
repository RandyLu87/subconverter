import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

@main
struct SubConfigStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1240, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}
