/// A queue contains references to saved entries, including intentional duplicates.
struct ClipboardStack {
    private(set) var ids: [String] = []
    private(set) var active = false
    mutating func start() { ids = []; active = true }
    mutating func stop() { ids = []; active = false }
    mutating func append(_ id: String) { if active { ids.append(id) } }
    mutating func consume() { if !ids.isEmpty { ids.removeFirst() } }
    mutating func reverse() { ids.reverse() }
    mutating func discardMissing(_ existing: Set<String>) { ids.removeAll { !existing.contains($0) } }
}
