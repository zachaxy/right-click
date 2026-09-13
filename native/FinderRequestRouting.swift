import Cocoa

enum FinderRequestRouting {
    static func route(_ request: [String: Any],
                      execute: ([String: Any]) -> Void,
                      present: ([String: Any]) -> Void) {
        switch request["cmd"] as? String {
        case "workbench": present(request)
        default: execute(request)
        }
    }

    static func showsWindowOnLaunch(_ notification: Notification) -> Bool {
        // AppKit identifies URL/service launches. Command-line launch arguments
        // cannot carry this signal because Finder extensions are sandboxed.
        notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
    }

    static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        // Interactive requests activate the app only once their UI is ready.
        configuration.activates = false
        return configuration
    }
}
