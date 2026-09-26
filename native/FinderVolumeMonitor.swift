import Cocoa

/// Keeps Finder's watched roots separate from the process-bound Finder Sync API.
final class FinderVolumeMonitor: NSObject {
    private let center: NotificationCenter
    private let mountedVolumes: () -> [URL]?
    private let apply: (Set<URL>) -> Void
    private var registeredRoots: Set<URL>?

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         mountedVolumes: @escaping () -> [URL]? = {
             FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                   options: [.skipHiddenVolumes])
         },
         apply: @escaping (Set<URL>) -> Void) {
        center = notificationCenter
        self.mountedVolumes = mountedVolumes
        self.apply = apply
        super.init()
        // Register before enumerating so a disk arriving during startup is not missed.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
        refresh()
    }

    deinit { center.removeObserver(self) }

    @objc private func volumesChanged(_ notification: Notification) { refresh() }

    private func refresh() {
        let volumes = mountedVolumes()
        // Keep a working registration if an enumeration temporarily fails.
        guard volumes != nil || registeredRoots == nil else { return }
        var roots: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        roots.formUnion((volumes ?? []).filter { $0.isFileURL }.map { $0.standardizedFileURL })
        guard roots != registeredRoots else { return }
        apply(roots)
        registeredRoots = roots
    }
}
