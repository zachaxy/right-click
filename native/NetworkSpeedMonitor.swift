import Cocoa
import Darwin
import SystemConfiguration

// Reference: Stats Modules/Net/readers.swift, UsageReader (MIT, Serhiy Mytrovtsiy).
// https://github.com/exelban/stats/blob/3e97046d7032c514fe631812b2a3ed36122a706b/Modules/Net/readers.swift
// Reviewed blob 3cfb104f4dc9390a29ade3464444e7cfbdbf37ea. This independent reader
// follows its cumulative-byte sampling approach; it sums physical interfaces and
// divides each delta by measured elapsed time instead of assuming exactly 1 second.

enum NetworkSpeedStatus {
    case warmingUp, available, unavailable
}

struct NetworkSpeedSample {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let interfaces: [String]
    let status: NetworkSpeedStatus
}

struct NetworkInterfaceCounters {
    let name: String
    let index: UInt32
    let receivedBytes: UInt64
    let sentBytes: UInt64
    var changeTime: UInt64 = 0
}

/// Pure rate calculation, separate from system reads and scheduling.
struct NetworkSpeedAccumulator {
    private var previous = [String: NetworkInterfaceCounters]()
    private var previousTime: TimeInterval?

    mutating func sample(_ counters: [NetworkInterfaceCounters]?, at time: TimeInterval) -> NetworkSpeedSample {
        guard let counters, !counters.isEmpty, time.isFinite else {
            previous.removeAll()
            previousTime = nil
            return NetworkSpeedSample(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                      interfaces: [], status: .unavailable)
        }
        var current = [String: NetworkInterfaceCounters]()
        for counter in counters { current[counter.name] = counter }
        let names = current.keys.sorted()
        let warmingUp = NetworkSpeedSample(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                           interfaces: names, status: .warmingUp)
        defer { previous = current; previousTime = time }
        guard let previousTime, previous.keys.sorted() == names else { return warmingUp }
        let elapsed = time - previousTime
        // A stalled timer/sleep must not present a long-period average as live speed.
        guard elapsed > 0, elapsed <= 5 else { return warmingUp }
        var received = 0.0
        var sent = 0.0
        for name in names {
            guard let old = previous[name], let new = current[name],
                  old.index == new.index, old.changeTime == new.changeTime,
                  new.receivedBytes >= old.receivedBytes, new.sentBytes >= old.sentBytes else { return warmingUp }
            // Subtract UInt64 first so small deltas remain exact even above 2^53.
            received += Double(new.receivedBytes - old.receivedBytes)
            sent += Double(new.sentBytes - old.sentBytes)
        }
        return NetworkSpeedSample(downloadBytesPerSecond: received / elapsed,
                                  uploadBytesPerSecond: sent / elapsed,
                                  interfaces: names, status: .available)
    }
}

enum NetworkSpeedReader {
    enum TargetReadResult {
        case active(NetworkInterfaceCounters)
        case inactive
        case stale
    }

    static func includes(name: String, flags: Int32, physicalNames: Set<String>) -> Bool {
        let excluded = ["lo", "utun", "tun", "tap", "ipsec", "ppp", "gif", "stf", "wg",
                        "awdl", "llw", "bridge", "bond", "vlan", "vmenet", "vmnet", "ap", "anpi"]
        return physicalNames.contains(name)
            && !excluded.contains(where: name.hasPrefix)
            && flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
            && flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0
    }

    static func physicalInterfaces(using store: SCDynamicStore? = nil) -> Set<String> {
        let types = [kSCNetworkInterfaceTypeEthernet, kSCNetworkInterfaceTypeIEEE80211,
                     kSCNetworkInterfaceTypeFireWire, kSCNetworkInterfaceTypeWWAN]
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var names = Set<String>()
        for interface in interfaces {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface), types.contains(type),
                  let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            // A Wi-Fi/Ethernet device may stay RUNNING after its cable/link goes down.
            let key = "State:/Network/Interface/\(name)/Link" as CFString
            let link = SCDynamicStoreCopyValue(store, key) as? [String: Any]
            if link?[kSCPropNetLinkActive as String] as? Bool == false { continue }
            names.insert(name)
        }
        return names
    }

    static func enumerateTargets(using store: SCDynamicStore? = nil) -> [(name: String, index: UInt32)] {
        physicalInterfaces(using: store).sorted().compactMap { name in
            let index = if_nametoindex(name)
            return index > 0 ? (name: name, index: index) : nil
        }
    }

    static func readTarget(name: String, index: UInt32) -> TargetReadResult {
        guard index > 0 else { return .stale }
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA,
                            Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var length = MemoryLayout<ifmibdata>.size
        // The route-list API rounds non-platform callers to 1 KB and casts to
        // UInt32, even for if_data64. IFDATA_GENERAL preserves the full counters.
        // https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/rtsock.c#L158
        // https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/if_mib.c#L120
        guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0,
              length == MemoryLayout<ifmibdata>.size else { return .stale }
        let returnedName = withUnsafeBytes(of: data.ifmd_name) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard returnedName == name else { return .stale }
        if let counter = counter(from: data, length: length, name: name, index: index) {
            return .active(counter)
        }
        return .inactive
    }

    static func read() -> [NetworkInterfaceCounters]? {
        let targets = enumerateTargets()
        var result = [NetworkInterfaceCounters]()
        for target in targets {
            switch readTarget(name: target.name, index: target.index) {
            case .active(let counter):
                result.append(counter)
            case .inactive:
                continue
            case .stale:
                return nil
            }
        }
        return result
    }

    /// Convert one response only after its identity and active flags are checked.
    static func counter(from data: ifmibdata, length: Int, name: String,
                        index: UInt32) -> NetworkInterfaceCounters? {
        guard length == MemoryLayout<ifmibdata>.size, index > 0 else { return nil }
        let returnedName = withUnsafeBytes(of: data.ifmd_name) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes.prefix(end), encoding: .utf8)
        }
        guard returnedName == name,
              includes(name: name, flags: Int32(bitPattern: data.ifmd_flags), physicalNames: [name]) else { return nil }
        let stats = data.ifmd_data
        let changeTime = UInt64(max(stats.ifi_lastchange.tv_sec, 0)) * 1_000_000
            + UInt64(max(stats.ifi_lastchange.tv_usec, 0))
        return NetworkInterfaceCounters(name: name, index: index,
            receivedBytes: stats.ifi_ibytes, sentBytes: stats.ifi_obytes, changeTime: changeTime)
    }
}

/// Caches physical BSD interface indices so steady-state ticks only run sysctl(),
/// re-enumerating IOKit/SystemConfiguration only when network state changes.
final class CachedNetworkSpeedReader {
    private let enumerate: () -> [(name: String, index: UInt32)]
    private let readTarget: (String, UInt32) -> NetworkSpeedReader.TargetReadResult
    private var cachedTargets: [(name: String, index: UInt32)]?

    init(enumerate: @escaping () -> [(name: String, index: UInt32)],
         readTarget: @escaping (String, UInt32) -> NetworkSpeedReader.TargetReadResult = NetworkSpeedReader.readTarget) {
        self.enumerate = enumerate
        self.readTarget = readTarget
    }

    func invalidate() {
        cachedTargets = nil
    }

    func read() -> [NetworkInterfaceCounters]? {
        if let targets = cachedTargets, let counters = readAll(targets) {
            return counters
        }
        let refreshed = enumerate()
        cachedTargets = refreshed
        if let counters = readAll(refreshed) {
            return counters
        }
        cachedTargets = nil
        return nil
    }

    private func readAll(_ targets: [(name: String, index: UInt32)]) -> [NetworkInterfaceCounters]? {
        var result = [NetworkInterfaceCounters]()
        result.reserveCapacity(targets.count)
        for target in targets {
            switch readTarget(target.name, target.index) {
            case .active(let counter):
                result.append(counter)
            case .inactive:
                continue
            case .stale:
                return nil
            }
        }
        return result
    }
}

/// Configure/start/stop on the main thread; all callbacks also arrive on the main thread.
/// Only local link counters are read: no traffic, addresses, SSIDs or remote requests.
final class NetworkSpeedMonitor {
    var onUpdate: ((NetworkSpeedSample) -> Void)?
    private let customRead: (() -> [NetworkInterfaceCounters]?)?
    private let clock: () -> TimeInterval
    private let center: NotificationCenter
    private let queue = DispatchQueue(label: "dev.rustclick.network-speed", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var dynamicStore: SCDynamicStore?
    private var observers = [NSObjectProtocol]()
    private var running = false
    private var generation = 0

    init(read: (() -> [NetworkInterfaceCounters]?)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.customRead = read
        self.clock = clock
        center = notificationCenter
    }

    deinit {
        timer?.cancel()
        if let store = dynamicStore { SCDynamicStoreSetDispatchQueue(store, nil) }
        for observer in observers { center.removeObserver(observer) }
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelTimer()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.beginSampling()
        })
        beginSampling()
    }

    func stop() {
        precondition(Thread.isMainThread)
        running = false
        cancelTimer()
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func cancelTimer() {
        generation += 1 // Discard an already queued callback after disable/sleep/restart.
        timer?.cancel()
        timer = nil
        if let store = dynamicStore {
            SCDynamicStoreSetDispatchQueue(store, nil)
            dynamicStore = nil
        }
    }

    private func beginSampling() {
        cancelTimer()
        let token = generation
        let clock = self.clock
        // Each session owns its accumulator and interface cache: an old in-flight read cannot alter a new baseline.
        let session = SamplingSession()
        let read: () -> [NetworkInterfaceCounters]?
        if let customRead {
            read = customRead
        } else {
            let flag = InvalidationFlag()
            let watcher = Self.makeDynamicStore(flag: flag, queue: queue)
            dynamicStore = watcher.store
            let store = watcher.store
            let watchesChanges = watcher.watching
            let cachedReader = CachedNetworkSpeedReader(enumerate: {
                NetworkSpeedReader.enumerateTargets(using: store)
            })
            read = {
                if flag.dirty || !watchesChanges {
                    flag.dirty = false
                    cachedReader.invalidate()
                }
                return cachedReader.read()
            }
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            let counters = read()
            let sample = session.accumulator.sample(counters, at: clock())
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.onUpdate?(sample)
            }
        }
        timer = source
        source.resume()
    }

    private static func makeDynamicStore(flag: InvalidationFlag, queue: DispatchQueue) -> (store: SCDynamicStore?, watching: Bool) {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passRetained(flag).toOpaque(),
            retain: nil,
            release: { info in
                Unmanaged<InvalidationFlag>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(nil, "dev.rustclick.network-speed" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<InvalidationFlag>.fromOpaque(info).takeUnretainedValue().dirty = true
        }, &context) else {
            return (nil, false)
        }
        let keys = ["State:/Network/Interface" as CFString] as CFArray
        let patterns = [
            "State:/Network/Interface/.*/Link" as CFString,
            "State:/Network/Global/.*" as CFString
        ] as CFArray
        let watching = SCDynamicStoreSetNotificationKeys(store, keys, patterns)
            && SCDynamicStoreSetDispatchQueue(store, queue)
        return (store, watching)
    }

    private final class InvalidationFlag {
        var dirty = true
    }

    private final class SamplingSession {
        var accumulator = NetworkSpeedAccumulator()
    }
}
