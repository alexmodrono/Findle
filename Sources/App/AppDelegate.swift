import AppKit
import FileProvider
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.foodle.app", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Foodle launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Foodle terminating")
    }
}
