import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }
}
