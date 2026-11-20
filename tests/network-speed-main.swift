import Cocoa
import Darwin

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
}
func counter(_ name: String = "en0", index: UInt32 = 1, download: UInt64, upload: UInt64,
             changeTime: UInt64 = 0) -> NetworkInterfaceCounters {
    NetworkInterfaceCounters(name: name, index: index, receivedBytes: download, sentBytes: upload, changeTime: changeTime)
}

var rates = NetworkSpeedAccumulator()
let large = UInt64(1) << 54
var sample = rates.sample([counter(download: large, upload: large)], at: 10)
check(sample.status == .warmingUp && sample.downloadBytesPerSecond == 0, "first sample must not show counters since boot as a rate")
sample = rates.sample([counter(download: large + 500, upload: large + 250)], at: 12.5)
check(sample.status == .available && sample.downloadBytesPerSecond == 200 && sample.uploadBytesPerSecond == 100,
      "use actual elapsed time and subtract UInt64 before converting to floating point")
sample = rates.sample([counter(download: large + 500, upload: large + 250)], at: 13.5)
check(sample.status == .available && sample.downloadBytesPerSecond == 0, "connected but idle is a valid zero rate")
sample = rates.sample([counter(download: 10, upload: 20)], at: 14.5)
check(sample.status == .warmingUp && sample.uploadBytesPerSecond == 0, "counter rollback resets both directions")
sample = rates.sample([counter(download: 110, upload: 70)], at: 15.5)
check(sample.downloadBytesPerSecond == 100 && sample.uploadBytesPerSecond == 50, "the reset establishes the next baseline")
sample = rates.sample([counter(index: 2, download: 210, upload: 120)], at: 16.5)
check(sample.status == .warmingUp, "recreated device with the same name resets its baseline")
sample = rates.sample([counter(index: 2, download: 310, upload: 170, changeTime: 8)], at: 17.5)
check(sample.status == .warmingUp, "administrative interface changes reset even when counters only increase")
sample = rates.sample([counter("en1", download: 500, upload: 500)], at: 18.5)
check(sample.status == .warmingUp && sample.interfaces == ["en1"], "switching physical interfaces resets the baseline")
sample = rates.sample([counter("en1", download: 600, upload: 600)], at: 30)
check(sample.status == .warmingUp, "long pauses do not present stale averages as current speed")
sample = rates.sample([counter("en1", download: 700, upload: 700)], at: 30)
check(sample.status == .warmingUp, "zero elapsed time cannot divide by zero")
sample = rates.sample([counter("en1", download: 800, upload: 800)], at: 29)
check(sample.status == .warmingUp, "a backward clock resets safely")
sample = rates.sample(nil, at: 31)
check(sample.status == .unavailable && sample.interfaces.isEmpty, "read failure clears stale state")
sample = rates.sample([], at: 32)
check(sample.status == .unavailable, "no active physical interface is unavailable, not a false live zero")
sample = rates.sample([counter(download: 100, upload: 50), counter("en1", index: 2, download: 200, upload: 100)], at: 33)
check(sample.status == .warmingUp, "recovery after a failed read establishes a baseline")
sample = rates.sample([counter("en1", index: 2, download: 800, upload: 300), counter(download: 500, upload: 250)], at: 35)
check(sample.status == .available && sample.downloadBytesPerSecond == 500 && sample.uploadBytesPerSecond == 200,
      "sum physical interface deltas independent of enumeration order")

let flags = IFF_UP | IFF_RUNNING
let hardware: Set<String> = ["en0", "en7", "utun0", "lo0", "awdl0", "llw0", "bridge0", "vmenet0", "tap0"]
check(NetworkSpeedReader.includes(name: "en7", flags: flags, physicalNames: hardware), "USB/Ethernet is not restricted to en0")
check(!NetworkSpeedReader.includes(name: "en99", flags: flags, physicalNames: hardware), "an en prefix alone does not prove physical hardware")
for name in ["utun0", "lo0", "awdl0", "llw0", "bridge0", "vmenet0", "tap0"] {
    check(!NetworkSpeedReader.includes(name: name, flags: flags, physicalNames: hardware), "exclude duplicated virtual traffic on \(name)")
}
for mask in [IFF_UP, IFF_RUNNING, flags | IFF_LOOPBACK, flags | IFF_POINTOPOINT] {
    check(!NetworkSpeedReader.includes(name: "en0", flags: mask, physicalNames: hardware), "require active non-loopback, non-tunnel flags")
}

func mibResponse(name: String, incoming: UInt64, outgoing: UInt64) -> ifmibdata {
    var data = ifmibdata()
    withUnsafeMutableBytes(of: &data.ifmd_name) { bytes in
        for (index, byte) in name.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = byte }
    }
    data.ifmd_flags = UInt32(flags)
    data.ifmd_data.ifi_ibytes = incoming
    data.ifmd_data.ifi_obytes = outgoing
    data.ifmd_data.ifi_lastchange.tv_sec = 42
    data.ifmd_data.ifi_lastchange.tv_usec = 123
    return data
}
let responseSize = MemoryLayout<ifmibdata>.size
var response = mibResponse(name: "en0", incoming: large + 7, outgoing: large + 9)
let converted = NetworkSpeedReader.counter(from: response, length: responseSize, name: "en0", index: 1)
check(converted?.receivedBytes == large + 7 && converted?.sentBytes == large + 9,
      "IFDATA_GENERAL preserves counts above 2^32 and non-1024-aligned bytes exactly")
check(converted?.name == "en0" && converted?.index == 1 && converted?.changeTime == 42_000_123,
      "preserve interface identity and if_data64 last-change time")
check(NetworkSpeedReader.counter(from: response, length: responseSize - 1, name: "en0", index: 1) == nil,
      "a short response is unavailable, never a fabricated zero counter")
check(NetworkSpeedReader.counter(from: response, length: responseSize, name: "en1", index: 1) == nil,
      "an index recycled for a differently named interface cannot contaminate its rate")
check(NetworkSpeedReader.counter(from: response, length: responseSize, name: "en0", index: 0) == nil,
      "a disappeared interface without an index cannot produce counters")
response.ifmd_flags = UInt32(IFF_UP)
check(NetworkSpeedReader.counter(from: response, length: responseSize, name: "en0", index: 1) == nil,
      "an interface that went down after enumeration is excluded")
response = mibResponse(name: "utun0", incoming: large, outgoing: large)
check(NetworkSpeedReader.counter(from: response, length: responseSize, name: "utun0", index: 2) == nil,
      "MIB conversion retains the virtual-interface exclusion")
response = mibResponse(name: "en0", incoming: 0, outgoing: 0)
_ = withUnsafeMutableBytes(of: &response.ifmd_name) { $0.initializeMemory(as: UInt8.self, repeating: 65) }
check(NetworkSpeedReader.counter(from: response, length: responseSize, name: "en0", index: 1) == nil,
      "an unterminated interface name cannot be read past its fixed-size field")

final class ReadCount {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
}
func wait(_ duration: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
let calls = ReadCount()
let center = NotificationCenter()
let monitor = NetworkSpeedMonitor(read: {
    let count = calls.next()
    return [counter(download: UInt64(count * 100), upload: UInt64(count * 50))]
}, notificationCenter: center)
var updates = [NetworkSpeedSample]()
monitor.onUpdate = {
    check(Thread.isMainThread, "monitor callbacks must reach the UI on the main thread")
    updates.append($0)
}
wait(0.05)
check(calls.value == 0, "a disabled monitor does not read system counters")
monitor.start()
monitor.start()
waitUntil { updates.count >= 2 }
check(updates.count == 2 && calls.value == 2 && updates[0].status == .warmingUp && updates[1].status == .available,
      "start is idempotent and the 1-second timer publishes baseline then rate")
center.post(name: NSWorkspace.willSleepNotification, object: nil)
let asleepReads = calls.value
wait(1.15)
check(calls.value == asleepReads, "sleep cancels polling")
center.post(name: NSWorkspace.didWakeNotification, object: nil)
waitUntil { updates.count == 3 }
check(updates.last?.status == .warmingUp, "wake starts a fresh sampling session")
monitor.stop()
let stoppedReads = calls.value
let stoppedUpdates = updates.count
center.post(name: NSWorkspace.didWakeNotification, object: nil)
wait(1.15)
check(calls.value == stoppedReads && updates.count == stoppedUpdates, "stop removes polling and sleep/wake observers")
monitor.start()
waitUntil { updates.count > stoppedUpdates }
check(updates.last?.status == .warmingUp, "re-enabling never includes the disabled period")
monitor.stop()

// A slow read may finish after disable. It must neither update the UI nor seed a later session.
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let slowReads = ReadCount()
let slow = NetworkSpeedMonitor(read: {
    let count = slowReads.next()
    if count == 1 { entered.signal(); release.wait() }
    return [counter(download: UInt64(count * 100), upload: UInt64(count * 100))]
}, notificationCenter: center)
var lateUpdates = [NetworkSpeedSample]()
slow.onUpdate = { lateUpdates.append($0) }
slow.start()
check(entered.wait(timeout: .now() + 1) == .success, "the sample starts off the main thread")
slow.stop()
slow.start()
release.signal()
waitUntil { !lateUpdates.isEmpty }
check(lateUpdates.count == 1 && lateUpdates[0].status == .warmingUp,
      "a queued old sample cannot update the UI or seed a new session after rapid disable/re-enable")
slow.stop()

// Cross the real OS boundary: a synthetic ifmibdata cannot expose counters that
// macOS truncates or rounds for third-party processes. Only parse link identity
// and byte counts from netstat; do not retain addresses or generate traffic.
func systemCounters() -> [String: (index: UInt32, received: UInt64, sent: UInt64)] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-ibn"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "netstat counter comparison must complete")
    var result = [String: (index: UInt32, received: UInt64, sent: UInt64)]()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 10, fields[2].hasPrefix("<Link#"), fields[2].hasSuffix(">"),
              let index = UInt32(fields[2].dropFirst(6).dropLast()) else { continue }
        let statistics = Array(fields.suffix(7))
        guard let received = UInt64(statistics[2]), let sent = UInt64(statistics[5]) else { continue }
        let name = String(fields[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        result[name] = (index, received, sent)
    }
    precondition(!result.isEmpty, "netstat must provide parseable link counters, including loopback")
    return result
}

let before = systemCounters()
let live = NetworkSpeedReader.read()
let after = systemCounters()
check(live != nil, "the actual macOS sysctl reader completes without network requests")
var systemComparisons = 0
var changedInterfaces = 0
for current in live ?? [] {
    guard let first = before[current.name], let last = after[current.name],
          first.index == current.index, last.index == current.index,
          last.received >= first.received, last.sent >= first.sent else {
        changedInterfaces += 1
        continue
    }
    check(first.received <= current.receivedBytes && current.receivedBytes <= last.received,
          "\(current.name): live receive bytes must fall between independent system snapshots")
    check(first.sent <= current.sentBytes && current.sentBytes <= last.sent,
          "\(current.name): live send bytes must fall between independent system snapshots")
    systemComparisons += 2
}
print("PASS: \(checks) network speed checks; live physical interfaces: \((live ?? []).map(\.name).joined(separator: ", ")); "
    + "real OS counter comparisons: \(systemComparisons); skipped changed interfaces: \(changedInterfaces)")
