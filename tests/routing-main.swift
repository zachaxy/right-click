import Cocoa

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); failures += 1 }
}

for command in ["copy_path", "copy_name", "cut", "paste", "copy", "move", "create", "create_custom", "favorite", "open_app", "info", "convert", "compress", "compress7z", "encrypt", "extract", "icons", "rename", "repair_name", "hidden", "unhidden", "finder_show", "finder_hide", "extension_hide", "extension_show", "writable", "airdrop", "wallpaper", "preview", "pin", "screenshot", "scan", "trash", "delete", "shortcut", "folder_from_name", "dissolve", "text", "unknown"] {
    let request: [String: Any] = ["cmd": command,
        "paths": ["/tmp/中文 空格.txt", "/tmp/second.txt"], "dir": "/tmp"]
    var executed: [[String: Any]] = []
    var presented: [[String: Any]] = []
    FinderRequestRouting.route(request, execute: { executed.append($0) },
                               present: { presented.append($0) })
    check(executed.count == 1, "\(command) must run without waiting for the web console")
    check(presented.isEmpty, "\(command) must neither show the window nor navigate the console")
    check(NSDictionary(dictionary: executed.first ?? [:]).isEqual(to: request),
          "\(command) must preserve the command, directory and all selected paths")
}

for command in ["workbench"] {
    var presented: [String: Any] = [:]
    FinderRequestRouting.route(["cmd": command], execute: { _ in
        check(false, "\(command) must keep its existing interactive/confirmation flow")
    }, present: { presented = $0 })
    check(presented["cmd"] as? String == command, "\(command) must reach the console")
}

let configuration = FinderRequestRouting.openConfiguration()
check(!configuration.activates, "Finder dispatch must not activate RightClick")
let externalLaunch = Notification(name: NSApplication.didFinishLaunchingNotification,
    userInfo: [NSApplication.launchIsDefaultUserInfoKey: false])
let ordinaryLaunch = Notification(name: NSApplication.didFinishLaunchingNotification,
    userInfo: [NSApplication.launchIsDefaultUserInfoKey: true])
check(!FinderRequestRouting.showsWindowOnLaunch(externalLaunch),
      "A Finder request must not show the console during cold start")
check(FinderRequestRouting.showsWindowOnLaunch(ordinaryLaunch),
      "An ordinary app launch must still show the console")
if failures > 0 { exit(1) }
print("PASS: all Finder actions bypass the console; explicit workbench and ordinary launch retain their UI")
