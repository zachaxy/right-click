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
    static func includes(name: String, flags: Int32, physicalNames: Set<String>) -> Bool {
        let excluded = ["lo", "utun", "tun", "tap", "ipsec", "ppp", "gif", "stf", "wg",
                        "awdl", "llw", "bridge", "bond", "vlan", "vmenet", "vmnet", "ap", "anpi"]
        return physicalNames.contains(name)
            && !excluded.contains(where: name.hasPrefix)
            && flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
            && flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0
    }

    private static func physicalInterfaces() -> Set<String> {
        let types = [kSCNetworkInterfaceTypeEthernet, kSCNetworkInterfaceTypeIEEE80211,
                     kSCNetworkInterfaceTypeFireWire, kSCNetworkInterfaceTypeWWAN]
        var names = Set<String>()
        for interface in SCNetworkInterfaceCopyAll() as! [SCNetworkInterface] {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface), types.contains(type),
                  let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            // A Wi-Fi/Ethernet device may stay RUNNING after its cable/link goes down.
            let key = "State:/Network/Interface/\(name)/Link" as CFString
            let link = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
            if link?[kSCPropNetLinkActive as String] as? Bool == false { continue }
            names.insert(name)
        }
        return names
    }

    static func read() -> [NetworkInterfaceCounters]? {
        let physicalNames = physicalInterfaces()
        var result = [NetworkInterfaceCounters]()
        for name in physicalNames.sorted() {
            let index = if_nametoindex(name)
            guard index > 0 else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA,
                                Int32(index), IFDATA_GENERAL]
            var data = ifmibdata()
            var length = MemoryLayout<ifmibdata>.size
            // The route-list API rounds non-platform callers to 1 KB and casts to
            // UInt32, even for if_data64. IFDATA_GENERAL preserves the full counters.
            // https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/rtsock.c#L158
            // https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/if_mib.c#L120
            guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0,
                  length == MemoryLayout<ifmibdata>.size,
                  if_nametoindex(name) == index else { return nil }
            if let counter = counter(from: data, length: length, name: name, index: index) {
                result.append(counter)
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

/// Configure/start/stop on the main thread; all callbacks also arrive on the main thread.
/// Only local link counters are read: no traffic, addresses, SSIDs or remote requests.
final class NetworkSpeedMonitor {
    var onUpdate: ((NetworkSpeedSample) -> Void)?
    private let read: () -> [NetworkInterfaceCounters]?
    private let clock: () -> TimeInterval
    private let center: NotificationCenter
    private let queue = DispatchQueue(label: "dev.rustclick.network-speed", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observers = [NSObjectProtocol]()
    private var running = false
    private var generation = 0

    init(read: @escaping () -> [NetworkInterfaceCounters]? = NetworkSpeedReader.read,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.read = read
        self.clock = clock
        center = notificationCenter
    }

    deinit {
        timer?.cancel()
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
    }

    private func beginSampling() {
        cancelTimer()
        let token = generation
        let read = self.read
        let clock = self.clock
        // Each session owns its accumulator: an old in-flight read cannot alter a new baseline.
        let session = SamplingSession()
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

    private final class SamplingSession {
        var accumulator = NetworkSpeedAccumulator()
    }
}
