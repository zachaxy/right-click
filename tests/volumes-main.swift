import Cocoa

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); failures += 1 }
}

let root = URL(fileURLWithPath: "/", isDirectory: true)
let external = URL(fileURLWithPath: "/Volumes/External Disk", isDirectory: true)
let inserted = URL(fileURLWithPath: "/Volumes/新硬盘", isDirectory: true)
let renamed = URL(fileURLWithPath: "/Volumes/Renamed Disk", isDirectory: true)
let center = NotificationCenter()
var volumes: [URL]? = [root, external]
var watched = Set<URL>()
var writes = 0
var reads = 0
var monitor: FinderVolumeMonitor? = FinderVolumeMonitor(notificationCenter: center,
    mountedVolumes: { reads += 1; return volumes }, apply: { watched = $0; writes += 1 })
check(watched.contains(root), "Keep the startup disk registered")
check(watched.contains(external), "Register an external disk already mounted when Finder starts")

volumes = [root, external, inserted, inserted]
center.post(name: NSWorkspace.didMountNotification, object: nil)
check(watched == Set([root, external, inserted]), "Register newly mounted disks without duplicates")
let unchangedWrites = writes
center.post(name: NSWorkspace.didMountNotification, object: nil)
check(writes == unchangedWrites, "Unchanged volume lists must not reset Finder's registration")

volumes = [root, inserted]
center.post(name: NSWorkspace.didUnmountNotification, object: nil)
check(watched == Set([root, inserted]), "Remove an unmounted disk while keeping the other roots")
volumes = [root, renamed]
center.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)
check(watched == Set([root, renamed]), "Replace the old mount path after a volume rename")

volumes = nil
center.post(name: NSWorkspace.didMountNotification, object: nil)
check(watched == Set([root, renamed]), "A failed volume enumeration must preserve known roots")
volumes = []
center.post(name: NSWorkspace.didUnmountNotification, object: nil)
check(watched == Set([root]), "Keep the startup root when no other volumes are mounted")

weak var releasedMonitor = monitor
monitor = nil
check(releasedMonitor == nil, "Notification observers must not retain the monitor")
let readsAtShutdown = reads
center.post(name: NSWorkspace.didMountNotification, object: nil)
check(reads == readsAtShutdown, "Stop observing volume changes when the monitor is released")

var fallbackRoots = Set<URL>()
let fallback = FinderVolumeMonitor(notificationCenter: center, mountedVolumes: { nil },
                                  apply: { fallbackRoots = $0 })
check(fallbackRoots == Set([root]), "Register the startup root even when initial enumeration fails")
withExtendedLifetime(fallback) {}
if failures > 0 { exit(1) }
print("PASS: startup disks, mount/unmount/rename, enumeration failure, and observer cleanup")
