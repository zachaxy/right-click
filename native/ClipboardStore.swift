import Cocoa
import CryptoKit
import Vision

struct ClipboardRepresentation: Codable {
    var type: String
    var data: Data
}

struct ClipboardEntry: Codable, Identifiable {
    var id: String
    var title: String
    var text: String
    var kind: String
    var sourceApp: String
    var sourceBundleID: String
    var createdAt: Date
    var updatedAt: Date
    var pinboardIDs: [String]
    var ocrText: String
    var fingerprint: String
}

struct ClipboardPinboard: Codable, Identifiable {
    var id: String
    var name: String
    var color: String? = nil
    var itemOrder: [String]? = nil
}

struct ClipboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
}

struct ClipboardSettings: Codable {
    var enabled = false
    var paused = false
    var retentionDays = 30
    var ignoredBundleIDs = ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords", "com.lastpass.LastPass"]
    var ignoredPatterns = [String]()
    var hideInScreenCapture = true
    var mcpEnabled = false
    var mcpIncludeHistory = false
    var shortcuts: [String: ClipboardShortcut]? = nil
    var pasteAsPlainText: Bool? = nil
    var pausedUntil: Date? = nil
}

private struct ClipboardState: Codable {
    var version = 1
    var entries = [ClipboardEntry]()
    var pinboards = [ClipboardPinboard]()
    var settings = ClipboardSettings()
}

/// All mutations and callbacks run on the main thread. OCR works off-thread and returns to it.
final class ClipboardStore {
    let directory: URL
    static let maximumCaptureBytes = 32 * 1024 * 1024
    private var state = ClipboardState()
    private var readable = true
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activeAppName = "未知应用"
    private var activeBundleID = ""
    private let monitorPasteboard: NSPasteboard
    private var changeCount: Int
    private var failedCaptureCount: Int?
    private let ocrQueue = DispatchQueue(label: "dev.rustclick.clipboard.ocr", qos: .utility)
    private var pendingOCR = Set<String>()
    private var lastExpirationCheck = Date.distantPast
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    var onCapture: ((ClipboardEntry) -> Void)?
    var entries: [ClipboardEntry] {
        guard settings.retentionDays > 0 else { return state.entries }
        let oldest = Date().addingTimeInterval(-Double(settings.retentionDays) * 86400)
        return state.entries.filter { !$0.pinboardIDs.isEmpty || $0.updatedAt >= oldest }
    }
    var pinboards: [ClipboardPinboard] { state.pinboards }
    var settings: ClipboardSettings { state.settings }

    init(directory: URL? = nil, monitorPasteboard: NSPasteboard = .general) {
        self.monitorPasteboard = monitorPasteboard
        self.changeCount = monitorPasteboard.changeCount
        let root = ProcessInfo.processInfo.environment["RUSTCLICK_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RustClick")
        self.directory = directory ?? root.appendingPathComponent("clipboard", isDirectory: true)
        let index = self.directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        do {
            state = try JSONDecoder().decode(ClipboardState.self, from: Data(contentsOf: index))
            guard state.version == 1 else { throw error("剪贴板资料版本不兼容，请保留资料并升级 RightClick。") }
            guard state.entries.allSatisfy({ UUID(uuidString: $0.id) != nil }),
                  Set(state.entries.map { $0.id }).count == state.entries.count,
                  Set(state.pinboards.map { $0.id }).count == state.pinboards.count else {
                throw error("剪贴板索引包含无效或重复的标识。")
            }
            try validate(state.settings)
            state.entries.sort { $0.updatedAt > $1.updatedAt }
        } catch {
            readable = false
            state = ClipboardState()
            lastError = "剪贴板资料无法读取，原文件已保留，未覆盖：\(error.localizedDescription)"
        }
    }

    deinit {
        timer?.invalidate()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "RightClick.Clipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func payloadURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw error("无效的剪贴板条目标识。") }
        return directory.appendingPathComponent("payloads", isDirectory: true).appendingPathComponent(id + ".plist")
    }

    private func prepareStorage() throws {
        guard readable else { throw error(lastError ?? "剪贴板资料不可写入。") }
        let fm = FileManager.default
        for url in [directory, directory.appendingPathComponent("payloads", isDirectory: true)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try prepareStorage()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func commit(_ next: ClipboardState) throws {
        try writeData(JSONEncoder().encode(next), to: directory.appendingPathComponent("state.json"))
        state = next
        lastError = nil
        onChange?()
    }

    private func savePayload(_ payload: [[ClipboardRepresentation]], id: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try writeData(encoder.encode(payload), to: payloadURL(id))
    }

    func loadPayload(id: String) throws -> [[ClipboardRepresentation]] {
        guard entries.contains(where: { $0.id == id }) else { throw error("此剪贴板条目已不存在。") }
        return try PropertyListDecoder().decode([[ClipboardRepresentation]].self, from: Data(contentsOf: payloadURL(id)))
    }

    func startMonitoring() {
        guard timer == nil else { return }
        // Existing clipboard contents predate consent; only subsequent changes are collected.
        changeCount = monitorPasteboard.changeCount
        let app = NSWorkspace.shared.frontmostApplication
        activeAppName = app?.localizedName ?? "未知应用"
        activeBundleID = app?.bundleIdentifier ?? ""
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            // Flush a pending copy from the previous application before changing attribution.
            self.poll()
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.activeAppName = app?.localizedName ?? "未知应用"
            self.activeBundleID = app?.bundleIdentifier ?? ""
        }
        expireHistoryIfNeeded()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func stopMonitoring() {
        timer?.invalidate(); timer = nil
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer); activationObserver = nil }
    }

    private func expireHistoryIfNeeded() {
        guard readable, Date().timeIntervalSince(lastExpirationCheck) >= 60 else { return }
        lastExpirationCheck = Date()
        var next = state
        let removed = prune(&next)
        guard !removed.isEmpty else { return }
        do { try commit(next); deletePayloads(removed) }
        catch { lastError = error.localizedDescription; onChange?() }
    }

    private func poll() {
        if settings.paused, let until = settings.pausedUntil, until <= Date() {
            var resumed = settings; resumed.paused = false; resumed.pausedUntil = nil
            do { try updateSettings(resumed) }
            catch { lastError = error.localizedDescription; onChange?() }
        }
        expireHistoryIfNeeded()
        // Do not repeatedly decode an oversized or otherwise failing unchanged clipboard.
        // An explicit queue-start flush can still retry it after the failure is resolved.
        guard failedCaptureCount != monitorPasteboard.changeCount else { return }
        do { try flushPendingCapture() }
        catch { lastError = error.localizedDescription; onChange?() }
    }

    /// Commit a copy that happened between polls using its already tracked source application.
    /// Call before activating a new paste queue so that pre-existing copies remain ordinary history.
    func flushPendingCapture() throws {
        let board = monitorPasteboard
        guard board.changeCount != changeCount else { return }
        let previousCount = changeCount
        changeCount = board.changeCount
        guard settings.enabled, !settings.paused else { return }
        do {
            _ = try capture(from: board, sourceApp: activeAppName, sourceBundleID: activeBundleID)
            failedCaptureCount = nil
        }
        catch {
            // Keep failed copies eligible for retry, and let the caller avoid starting a queue.
            failedCaptureCount = board.changeCount
            changeCount = previousCount
            throw error
        }
    }

    func ignoreCurrentPasteboardChange() { changeCount = monitorPasteboard.changeCount; failedCaptureCount = nil }

    private func validate(_ value: ClipboardSettings) throws {
        guard value.retentionDays >= 0, value.retentionDays <= 36500 else { throw error("保留天数必须为 0～36500，0 表示永久保留。") }
        if let shortcuts = value.shortcuts {
            let allowed: UInt32 = 256 | 512 | 2048 | 4096
            var used = Set<UInt64>()
            for (action, shortcut) in shortcuts {
                guard ["panel", "stack", "next"].contains(action), shortcut.keyCode <= 127,
                      shortcut.modifiers & ~allowed == 0, shortcut.modifiers & (256 | 2048 | 4096) != 0 else {
                    throw error("快捷键必须包含 Command、Control 或 Option，且使用有效按键。")
                }
                let key = UInt64(shortcut.modifiers) << 8 | UInt64(shortcut.keyCode)
                guard used.insert(key).inserted else { throw error("剪贴板快捷键不能重复。") }
            }
        }
        for pattern in value.ignoredPatterns {
            guard !pattern.isEmpty else { throw error("忽略规则不能是空的正则表达式。") }
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { throw self.error("无效的忽略规则：\(pattern)") }
        }
    }

    func updateSettings(_ value: ClipboardSettings) throws {
        try validate(value)
        var next = state
        next.settings = value
        if !next.settings.paused { next.settings.pausedUntil = nil }
        let removed = prune(&next)
        try commit(next)
        deletePayloads(removed)
        ignoreCurrentPasteboardChange()
    }

    private func shouldIgnore(_ text: String, sourceBundleID: String) -> Bool {
        if settings.ignoredBundleIDs.contains(sourceBundleID) { return true }
        let range = NSRange(text.startIndex..., in: text)
        return settings.ignoredPatterns.contains {
            (try? NSRegularExpression(pattern: $0).firstMatch(in: text, range: range)) != nil
        }
    }

    @discardableResult
    func capture(from board: NSPasteboard = .general, sourceApp: String = "", sourceBundleID: String = "") throws -> ClipboardEntry? {
        guard settings.enabled, !settings.paused else { return nil }
        return try collect(from: board, sourceApp: sourceApp, sourceBundleID: sourceBundleID, notifyCapture: true)
    }

    @discardableResult
    func importContent(from board: NSPasteboard, sourceApp: String = "拖入内容", sourceBundleID: String = "dev.rustclick.app") throws -> ClipboardEntry? {
        return try collect(from: board, sourceApp: sourceApp, sourceBundleID: sourceBundleID, notifyCapture: false)
    }

    private func collect(from board: NSPasteboard, sourceApp: String, sourceBundleID: String, notifyCapture: Bool) throws -> ClipboardEntry? {
        guard readable else { throw error(lastError ?? "剪贴板资料不可读取。") }
        let blocked = Set(["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "com.typeit4me.clipping"])
        let items = board.pasteboardItems ?? []
        guard !items.isEmpty,
              !items.contains(where: { item in item.types.contains { blocked.contains($0.rawValue) } }),
              !settings.ignoredBundleIDs.contains(sourceBundleID) else { return nil }
        let supported: Set<String> = Set([NSPasteboard.PasteboardType.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL, .pdf].map { $0.rawValue })
        var size = 0
        var payload = [[ClipboardRepresentation]]()
        for item in items {
            var representations = [ClipboardRepresentation]()
            for type in item.types where supported.contains(type.rawValue) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                size += data.count
                guard size <= Self.maximumCaptureBytes else { throw error("此条剪贴板内容超过 32 MB，已跳过记录。") }
                representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            }
            if !representations.isEmpty { payload.append(representations) }
        }
        guard !payload.isEmpty else { return nil }
        let text = plainText(payload)
        guard !shouldIgnore(text, sourceBundleID: sourceBundleID) else { return nil }
        let fingerprint = digest(payload)
        let now = Date()
        var next = state
        let entry: ClipboardEntry
        if let position = next.entries.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var previous = next.entries.remove(at: position)
            previous.updatedAt = now
            previous.sourceApp = sourceApp
            previous.sourceBundleID = sourceBundleID
            entry = previous
        } else {
            let kind = contentKind(payload, text: text)
            entry = ClipboardEntry(id: UUID().uuidString, title: titleFor(text: text, kind: kind), text: text,
                                   kind: kind, sourceApp: sourceApp, sourceBundleID: sourceBundleID,
                                   createdAt: now, updatedAt: now, pinboardIDs: [], ocrText: "", fingerprint: fingerprint)
            try savePayload(payload, id: entry.id)
        }
        next.entries.insert(entry, at: 0)
        let removed = prune(&next)
        try commit(next)
        deletePayloads(removed)
        if entry.kind == "image", entry.ocrText.isEmpty { recognizeText(entry: entry, payload: payload) }
        if notifyCapture { onCapture?(entry) }
        return entry
    }

    private func digest(_ payload: [[ClipboardRepresentation]]) -> String {
        var hash = SHA256()
        for item in payload {
            hash.update(data: Data("item\n".utf8))
            for representation in item.sorted(by: { $0.type < $1.type }) {
                hash.update(data: Data("\(representation.type):\(representation.data.count)\n".utf8))
                hash.update(data: representation.data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func plainText(_ payload: [[ClipboardRepresentation]]) -> String {
        payload.compactMap { representations -> String? in
            if let value = representations.first(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }),
               let string = String(data: value.data, encoding: .utf8), let url = URL(string: string) { return url.path }
            for type in [NSPasteboard.PasteboardType.string, .URL] {
                if let value = representations.first(where: { $0.type == type.rawValue }),
                   let string = String(data: value.data, encoding: .utf8) { return string }
            }
            if let value = representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtfd.rawValue }),
               let attributed = NSAttributedString(rtfd: value.data, documentAttributes: nil) { return attributed.string }
            if let value = representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }),
               let attributed = NSAttributedString(rtf: value.data, documentAttributes: nil) { return attributed.string }
            if let value = representations.first(where: { $0.type == NSPasteboard.PasteboardType.html.rawValue }),
               let html = String(data: value.data, encoding: .utf8) {
                // Do not load HTML through WebKit or an importer that might fetch remote resources.
                return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }.joined(separator: "\n")
    }

    private func contentKind(_ payload: [[ClipboardRepresentation]], text: String) -> String {
        let types = Set(payload.flatMap { $0.map { $0.type } })
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return "files" }
        if types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) || types.contains(NSPasteboard.PasteboardType.pdf.rawValue) { return "image" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil { return "color" }
        if let url = URL(string: trimmed), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""), !trimmed.contains("\n") { return "link" }
        return "text"
    }

    private func titleFor(text: String, kind: String) -> String {
        let first = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        if !first.isEmpty { return String(first.prefix(100)) }
        return kind == "image" ? "图片" : kind == "files" ? "文件" : "剪贴板内容"
    }

    func query(text: String = "", kind: String? = nil, sourceBundleID: String? = nil, since: Date? = nil, pinboardID: String? = nil) -> [ClipboardEntry] {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matches = entries.filter { entry in
            if let kind = kind, !kind.isEmpty, entry.kind != kind { return false }
            if let sourceBundleID = sourceBundleID, !sourceBundleID.isEmpty, entry.sourceBundleID != sourceBundleID { return false }
            if let since = since, entry.updatedAt < since { return false }
            if let pinboardID = pinboardID, !pinboardID.isEmpty, !entry.pinboardIDs.contains(pinboardID) { return false }
            let haystack = [entry.title, entry.text, entry.ocrText, entry.sourceApp, entry.sourceBundleID].joined(separator: "\n")
            return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
        guard let pinboardID = pinboardID, let order = pinboards.first(where: { $0.id == pinboardID })?.itemOrder else { return matches }
        var rank = [String: Int]()
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return matches.sorted {
            let left = rank[$0.id] ?? Int.max, right = rank[$1.id] ?? Int.max
            return left == right ? $0.updatedAt > $1.updatedAt : left < right
        }
    }

    func write(id: String, to board: NSPasteboard = .general, plainText: Bool = false) throws {
        try write(ids: [id], to: board, plainText: plainText)
    }

    func write(ids: [String], to board: NSPasteboard = .general, plainText: Bool = false) throws {
        guard !ids.isEmpty else { throw error("请先选择剪贴板条目。") }
        let selected = try ids.map { id -> ClipboardEntry in
            guard let entry = entries.first(where: { $0.id == id }) else { throw error("此剪贴板条目已不存在。") }
            return entry
        }
        if !plainText {
            for entry in selected where entry.kind == "files" {
                for url in fileURLs(id: entry.id) where !FileManager.default.fileExists(atPath: url.path) {
                    throw error("原文件已不存在：\(url.lastPathComponent)。文件历史保存的是位置，请先恢复原文件。")
                }
            }
        }
        var objects = [NSPasteboardItem]()
        if plainText {
            let text = selected.map { $0.text.isEmpty ? $0.ocrText : $0.text }.joined(separator: "\n")
            guard !text.isEmpty else { throw error("所选条目没有可粘贴的文字。") }
            let item = NSPasteboardItem(); item.setString(text, forType: .string); objects = [item]
        } else {
            // A single text representation makes combining text snippets work in ordinary editors.
            if selected.count > 1, selected.allSatisfy({ ["text", "link", "color"].contains($0.kind) }) {
                let joined = NSMutableAttributedString(string: "")
                for (index, entry) in selected.enumerated() {
                    if index > 0 { joined.append(NSAttributedString(string: "\n")) }
                    joined.append(try attributedText(id: entry.id))
                }
                let item = NSPasteboardItem()
                for representation in try richPayload(joined)[0] {
                    item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                objects = [item]
            } else {
                for id in ids {
                    for representations in try loadPayload(id: id) {
                        let item = NSPasteboardItem()
                        for representation in representations { item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) }
                        objects.append(item)
                    }
                }
            }
        }
        board.clearContents()
        guard board.writeObjects(objects) else { throw error("系统剪贴板写入失败。") }
        if board.name == monitorPasteboard.name { ignoreCurrentPasteboardChange() }
    }

    func attributedText(id: String) throws -> NSAttributedString {
        guard let entry = entries.first(where: { $0.id == id }) else { throw error("此剪贴板条目已不存在。") }
        let representations = try loadPayload(id: id).flatMap { $0 }
        if let value = representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtfd.rawValue }),
           let text = NSAttributedString(rtfd: value.data, documentAttributes: nil) { return text }
        if let value = representations.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }),
           let text = NSAttributedString(rtf: value.data, documentAttributes: nil) { return text }
        return NSAttributedString(string: entry.text)
    }

    private func richPayload(_ text: NSAttributedString) throws -> [[ClipboardRepresentation]] {
        let range = NSRange(location: 0, length: text.length)
        var result = [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.string.utf8))]
        var attachments = false
        text.enumerateAttribute(.attachment, in: range) { value, _, _ in if value != nil { attachments = true } }
        let type: NSAttributedString.DocumentType = attachments ? .rtfd : .rtf
        let data = try text.data(from: range, documentAttributes: [.documentType: type])
        result.append(ClipboardRepresentation(type: attachments ? NSPasteboard.PasteboardType.rtfd.rawValue : NSPasteboard.PasteboardType.rtf.rawValue, data: data))
        guard result.reduce(0, { $0 + $1.data.count }) <= Self.maximumCaptureBytes else { throw error("富文本内容超过 32 MB。") }
        return [result]
    }

    @discardableResult
    func editRichText(id: String? = nil, attributedText: NSAttributedString, title: String, pinboardID: String? = nil) throws -> ClipboardEntry {
        guard attributedText.length > 0 else { throw error("请输入文字。") }
        if let pinboardID = pinboardID, !pinboards.contains(where: { $0.id == pinboardID }) { throw error("收藏夹不存在。") }
        let payload = try richPayload(attributedText)
        var next = state
        let entry: ClipboardEntry
        if let id = id {
            guard let index = next.entries.firstIndex(where: { $0.id == id }), ["text", "link", "color"].contains(next.entries[index].kind) else { throw error("只支持编辑文字、链接或颜色条目。") }
            let previous = try loadPayload(id: id)
            next.entries[index].text = attributedText.string
            next.entries[index].title = title.isEmpty ? titleFor(text: attributedText.string, kind: "text") : title
            next.entries[index].kind = contentKind(payload, text: attributedText.string)
            next.entries[index].fingerprint = digest(payload)
            next.entries[index].ocrText = ""
            entry = next.entries[index]
            try savePayload(payload, id: id)
            do { try commit(next) }
            catch { try? savePayload(previous, id: id); throw error }
        } else {
            let now = Date()
            entry = ClipboardEntry(id: UUID().uuidString, title: title.isEmpty ? titleFor(text: attributedText.string, kind: "text") : title,
                                   text: attributedText.string, kind: contentKind(payload, text: attributedText.string), sourceApp: "RightClick", sourceBundleID: "dev.rustclick.app",
                                   createdAt: now, updatedAt: now, pinboardIDs: pinboardID.map { [$0] } ?? [], ocrText: "", fingerprint: digest(payload))
            try savePayload(payload, id: entry.id)
            next.entries.insert(entry, at: 0)
            appendPinOrder(entry, to: &next)
            try commit(next)
        }
        return entry
    }

    func rotateImage(id: String, clockwise: Bool = true) throws {
        guard let index = state.entries.firstIndex(where: { $0.id == id }), state.entries[index].kind == "image" else { throw error("请选择位图条目。") }
        let representations = try loadPayload(id: id).flatMap { $0 }
        guard let bitmap = representations.first(where: { [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue].contains($0.type) }),
              let original = NSBitmapImageRep(data: bitmap.data)?.cgImage else { throw error("仅支持 PNG/TIFF 位图旋转；PDF 不会被转换或覆盖。") }
        guard let context = CGContext(data: nil, width: original.height, height: original.width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw error("图片无法旋转。") }
        if clockwise { context.translateBy(x: 0, y: CGFloat(original.width)); context.rotate(by: -.pi / 2) }
        else { context.translateBy(x: CGFloat(original.height), y: 0); context.rotate(by: .pi / 2) }
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        guard let rotated = context.makeImage(), let png = NSBitmapImageRep(cgImage: rotated).representation(using: .png, properties: [:]), png.count <= Self.maximumCaptureBytes else { throw error("旋转后的图片无法保存或超过 32 MB。") }
        let payload = [[ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]]
        let previous = try loadPayload(id: id)
        var next = state
        next.entries[index].fingerprint = digest(payload)
        next.entries[index].ocrText = ""
        try savePayload(payload, id: id)
        do { try commit(next) }
        catch { try? savePayload(previous, id: id); throw error }
        pendingOCR.remove(id)
        recognizeText(entry: next.entries[index], payload: payload)
    }

    func image(id: String) -> NSImage? {
        guard let payload = try? loadPayload(id: id) else { return nil }
        for representation in payload.flatMap({ $0 }) where [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue, NSPasteboard.PasteboardType.pdf.rawValue].contains(representation.type) {
            if let image = NSImage(data: representation.data) { return image }
        }
        return nil
    }

    func fileURLs(id: String) -> [URL] {
        guard let payload = try? loadPayload(id: id) else { return [] }
        return payload.flatMap { $0 }.filter { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }.compactMap {
            guard let string = String(data: $0.data, encoding: .utf8), let url = URL(string: string), url.isFileURL else { return nil }
            return url
        }
    }

    @discardableResult
    func addText(_ text: String, title: String = "", pinboardID: String? = nil) throws -> ClipboardEntry {
        guard !text.isEmpty else { throw error("请输入文字。") }
        guard text.utf8.count <= Self.maximumCaptureBytes else { throw error("文字超过 32 MB。") }
        if let id = pinboardID, !pinboards.contains(where: { $0.id == id }) { throw error("收藏夹不存在。") }
        let payload = [[ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]]
        let now = Date()
        let entry = ClipboardEntry(id: UUID().uuidString, title: title.isEmpty ? titleFor(text: text, kind: "text") : title,
                                   text: text, kind: contentKind(payload, text: text), sourceApp: "RightClick", sourceBundleID: "dev.rustclick.app",
                                   createdAt: now, updatedAt: now, pinboardIDs: pinboardID.map { [$0] } ?? [], ocrText: "", fingerprint: digest(payload))
        try savePayload(payload, id: entry.id)
        var next = state; next.entries.insert(entry, at: 0)
        appendPinOrder(entry, to: &next)
        try commit(next)
        return entry
    }

    func edit(id: String, text: String, title: String) throws {
        guard let index = state.entries.firstIndex(where: { $0.id == id }), ["text", "link", "color"].contains(state.entries[index].kind) else { throw error("只支持编辑文字、链接或颜色条目。") }
        guard !text.isEmpty, text.utf8.count <= Self.maximumCaptureBytes else { throw error("文字不能为空或超过 32 MB。") }
        let payload = [[ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))]]
        let oldPayload = try loadPayload(id: id)
        var next = state
        next.entries[index].text = text
        next.entries[index].title = title.isEmpty ? titleFor(text: text, kind: "text") : title
        next.entries[index].kind = contentKind(payload, text: text)
        next.entries[index].fingerprint = digest(payload)
        next.entries[index].ocrText = ""
        try savePayload(payload, id: id)
        do { try commit(next) }
        catch { try? savePayload(oldPayload, id: id); throw error }
    }

    func rename(id: String, title: String) throws {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = state.entries.firstIndex(where: { $0.id == id }) else { throw error("条目不存在或标题为空。") }
        var next = state; next.entries[index].title = cleaned; try commit(next)
    }

    @discardableResult
    func addPinboard(name: String) throws -> ClipboardPinboard {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw error("请输入收藏夹名称。") }
        let board = ClipboardPinboard(id: UUID().uuidString, name: cleaned)
        var next = state; next.pinboards.append(board); try commit(next)
        return board
    }

    func renamePinboard(id: String, name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = pinboards.firstIndex(where: { $0.id == id }) else { throw error("收藏夹不存在或名称为空。") }
        var next = state; next.pinboards[index].name = cleaned; try commit(next)
    }

    func setPinboardColor(id: String, color: String) throws {
        let cleaned = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard cleaned.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw error("收藏夹颜色必须为六位十六进制色值，例如 5B8DEF。") }
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { throw error("收藏夹不存在。") }
        var next = state; next.pinboards[index].color = cleaned.uppercased(); try commit(next)
    }

    func movePinboard(id: String, offset: Int) throws {
        guard let index = pinboards.firstIndex(where: { $0.id == id }) else { throw error("收藏夹不存在。") }
        let destination = index + max(-index, min(offset, pinboards.count - 1 - index))
        guard destination != index else { return }
        var next = state
        let board = next.pinboards.remove(at: index); next.pinboards.insert(board, at: destination)
        try commit(next)
    }

    func movePinnedItem(id: String, pinboardID: String, offset: Int) throws {
        guard let boardIndex = pinboards.firstIndex(where: { $0.id == pinboardID }) else { throw error("收藏夹不存在。") }
        var order = query(pinboardID: pinboardID).map { $0.id }
        guard let index = order.firstIndex(of: id) else { throw error("该条目不在所选收藏夹中。") }
        let destination = index + max(-index, min(offset, order.count - 1 - index))
        guard destination != index else { return }
        order.insert(order.remove(at: index), at: destination)
        var next = state; next.pinboards[boardIndex].itemOrder = order
        try commit(next)
    }

    private func appendPinOrder(_ entry: ClipboardEntry, to value: inout ClipboardState) {
        for boardIndex in value.pinboards.indices where entry.pinboardIDs.contains(value.pinboards[boardIndex].id) {
            let boardID = value.pinboards[boardIndex].id
            var order = value.pinboards[boardIndex].itemOrder ?? value.entries.filter { $0.id != entry.id && $0.pinboardIDs.contains(boardID) }.map { $0.id }
            if !order.contains(entry.id) { order.append(entry.id) }
            value.pinboards[boardIndex].itemOrder = order
        }
    }

    func removePinboard(id: String) throws {
        guard pinboards.contains(where: { $0.id == id }) else { throw error("收藏夹不存在。") }
        var next = state; next.pinboards.removeAll { $0.id == id }
        for index in next.entries.indices { next.entries[index].pinboardIDs.removeAll { $0 == id } }
        let removed = prune(&next)
        try commit(next); deletePayloads(removed)
    }

    func setPinned(id: String, pinboardID: String, pinned: Bool) throws {
        guard let index = state.entries.firstIndex(where: { $0.id == id }), pinboards.contains(where: { $0.id == pinboardID }) else { throw error("条目或收藏夹不存在。") }
        guard state.entries[index].pinboardIDs.contains(pinboardID) != pinned else { return }
        var next = state
        next.entries[index].pinboardIDs.removeAll { $0 == pinboardID }
        if pinned {
            next.entries[index].pinboardIDs.append(pinboardID)
            appendPinOrder(next.entries[index], to: &next)
        } else if let boardIndex = next.pinboards.firstIndex(where: { $0.id == pinboardID }) {
            next.pinboards[boardIndex].itemOrder?.removeAll { $0 == id }
        }
        try commit(next)
    }

    func remove(ids: [String]) throws {
        let removed = Set(ids)
        var next = state; next.entries.removeAll { removed.contains($0.id) }
        for index in next.pinboards.indices { next.pinboards[index].itemOrder?.removeAll { removed.contains($0) } }
        try commit(next); deletePayloads(ids)
    }

    func clear(includePinned: Bool = false) throws {
        try remove(ids: entries.filter { includePinned || $0.pinboardIDs.isEmpty }.map { $0.id })
    }

    private func prune(_ value: inout ClipboardState) -> [String] {
        guard value.settings.retentionDays > 0 else { return [] }
        let oldest = Date().addingTimeInterval(-Double(value.settings.retentionDays) * 86400)
        let removed = value.entries.filter { $0.updatedAt < oldest && $0.pinboardIDs.isEmpty }.map { $0.id }
        let ids = Set(removed); value.entries.removeAll { ids.contains($0.id) }
        return removed
    }

    private func deletePayloads(_ ids: [String]) {
        for id in ids { if let url = try? payloadURL(id) { try? FileManager.default.removeItem(at: url) } }
    }

    private func recognizeText(entry: ClipboardEntry, payload: [[ClipboardRepresentation]]) {
        guard !pendingOCR.contains(entry.id),
              let representation = payload.flatMap({ $0 }).first(where: { [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue].contains($0.type) }) else { return }
        pendingOCR.insert(entry.id)
        let data = representation.data
        ocrQueue.async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(data: data).perform([request]) }
            catch { DispatchQueue.main.async { self?.pendingOCR.remove(entry.id) }; return }
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingOCR.remove(entry.id)
                guard !text.isEmpty, let index = self.state.entries.firstIndex(where: { $0.id == entry.id && $0.fingerprint == entry.fingerprint }) else { return }
                var next = self.state
                if self.shouldIgnore(text, sourceBundleID: entry.sourceBundleID) {
                    next.entries.remove(at: index)
                    do { try self.commit(next); self.deletePayloads([entry.id]) }
                    catch { self.lastError = error.localizedDescription; self.onChange?() }
                    return
                }
                next.entries[index].ocrText = text
                do { try self.commit(next) }
                catch { self.lastError = error.localizedDescription; self.onChange?() }
            }
        }
    }
}
