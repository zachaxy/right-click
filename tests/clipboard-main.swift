import Cocoa
import CoreText

let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-clipboard-tests-" + UUID().uuidString)
let board = NSPasteboard(name: NSPasteboard.Name("rightclick.tests." + UUID().uuidString))
defer { try? FileManager.default.removeItem(at: root); board.releaseGlobally() }
var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError("FAIL: " + message) }
}
func expectFailure(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL expected error: " + message) } catch { checks += 1 }
}
func setText(_ text: String) {
    board.clearContents(); board.setString(text, forType: .string)
}
func setItems(_ items: [NSPasteboardItem]) {
    board.clearContents(); check(board.writeObjects(items), "write named pasteboard fixture")
}

let store = ClipboardStore(directory: root)
check(!store.settings.enabled, "recording is opt-in")
check(store.settings.retentionDays == 30, "history defaults to thirty days")
check(!store.settings.mcpEnabled && !store.settings.mcpIncludeHistory, "MCP is opt-in and excludes history")
check(!FileManager.default.fileExists(atPath: root.path), "opening empty store does not create files")
setText("existing content")
check(try store.capture(from: board) == nil, "disabled recording ignores capture")
var settings = store.settings; settings.enabled = true
try store.updateSettings(settings)
var captureCount = 0
store.onCapture = { _ in captureCount += 1 }
let first = try store.capture(from: board, sourceApp: "Editor", sourceBundleID: "test.editor")!
check(first.text == "existing content" && first.kind == "text", "captures text and metadata")
check(first.sourceApp == "Editor", "captures source app")
let again = try store.capture(from: board, sourceApp: "Editor", sourceBundleID: "test.editor")!
check(again.id == first.id && store.entries.count == 1 && captureCount == 2, "dedup preserves identity and notifies stack on recopy")

let pin = try store.addPinboard(name: "工作")
try store.setPinned(id: first.id, pinboardID: pin.id, pinned: true)
try store.renamePinboard(id: pin.id, name: "常用")
setText("https://example.com/docs")
let link = try store.capture(from: board, sourceApp: "Browser", sourceBundleID: "test.browser")!
check(link.kind == "link", "recognizes links")
setText("123456")
check(try store.capture(from: board)!.kind == "text", "OTP is not a color")
setText("#12aBcF")
check(try store.capture(from: board)!.kind == "color", "recognizes explicit hex color")
check(store.query(text: "EXISTING", pinboardID: pin.id).map { $0.id } == [first.id], "case-insensitive search combines pinboard filter")
check(store.query(kind: "link", sourceBundleID: "test.browser").map { $0.id } == [link.id], "type and app filters compose")
check(store.query(since: Date().addingTimeInterval(10)).isEmpty, "date filter")

let beforePrivate = store.entries.count
setText("password")
check(try store.capture(from: board, sourceBundleID: "com.1password.1password") == nil, "default password manager ignored")
let concealed = NSPasteboardItem(); concealed.setString("secret", forType: .string)
concealed.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
setItems([concealed])
check(try store.capture(from: board) == nil, "concealed clipboard skipped")
let transient = NSPasteboardItem(); transient.setString("transient", forType: .string)
transient.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
setItems([transient])
check(try store.capture(from: board) == nil, "transient clipboard skipped")
settings.ignoredPatterns = ["token=[A-Za-z0-9]+"]
try store.updateSettings(settings)
setText("token=abcdef")
check(try store.capture(from: board) == nil && store.entries.count == beforePrivate, "privacy regex excludes matching content")
var invalid = settings; invalid.ignoredPatterns = ["["]
expectFailure("invalid regex rejected") { try store.updateSettings(invalid) }
check(store.settings.ignoredPatterns == settings.ignoredPatterns, "invalid settings do not replace previous config")
settings.paused = true; try store.updateSettings(settings)
setText("while paused")
check(try store.capture(from: board) == nil, "paused recording ignores copies")
settings.paused = false; try store.updateSettings(settings)

let rich = NSPasteboardItem()
rich.setString("Rich hello", forType: .string)
let rtf = Data("{\\rtf1\\ansi Rich \\b hello}".utf8)
rich.setData(rtf, forType: .rtf)
setItems([rich])
let richEntry = try store.capture(from: board)!
try store.write(id: richEntry.id, to: board)
check(board.data(forType: .rtf) == rtf, "rich text round-trips original RTF bytes")
try store.write(id: richEntry.id, to: board, plainText: true)
check(board.string(forType: .string) == "Rich hello" && board.data(forType: .rtf) == nil, "plain text removes formatting")

let path1 = root.appendingPathComponent("one.txt"), path2 = root.appendingPathComponent("two.txt")
try Data("one".utf8).write(to: path1)
try Data("two".utf8).write(to: path2)
let files = [path1, path2].map { url -> NSPasteboardItem in let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item }
setItems(files)
let filesEntry = try store.capture(from: board)!
check(filesEntry.kind == "files" && store.fileURLs(id: filesEntry.id) == [path1, path2], "multiple file URLs retained without copying original files")
try store.write(id: filesEntry.id, to: board)
check(board.pasteboardItems?.count == 2, "restoring files preserves both pasteboard items")
check(store.query(text: "two.txt").contains { $0.id == filesEntry.id }, "file paths searchable")
try store.rename(id: filesEntry.id, title: "文件组")
check(store.fileURLs(id: filesEntry.id) == [path1, path2], "renaming files preserves payload")
try FileManager.default.removeItem(at: path2)
expectFailure("missing source file surfaced before writing") { try store.write(id: filesEntry.id, to: board) }
check(board.pasteboardItems?.count == 2, "missing file does not clear clipboard")
try Data("two".utf8).write(to: path2)

let snippet = try store.addText("Template body", title: "模板", pinboardID: pin.id)
try store.edit(id: snippet.id, text: "Edited template", title: "新模板")
check(store.query(text: "Edited 新模板").count == 1, "editing updates content and search metadata")
try store.write(ids: [first.id, snippet.id], to: board, plainText: true)
check(board.string(forType: .string) == "existing content\nEdited template", "multi-select combines text in requested order")
expectFailure("missing entry cannot clobber clipboard") { try store.write(id: UUID().uuidString, to: board) }
check(board.string(forType: .string) == "existing content\nEdited template", "failed write leaves clipboard unchanged")

let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlS8AAAAASUVORK5CYII=")!
let imageItem = NSPasteboardItem(); imageItem.setData(png, forType: .png)
setItems([imageItem])
let imageEntry = try store.capture(from: board)!
check(imageEntry.kind == "image", "PNG classified as image")
try store.write(id: imageEntry.id, to: board)
check(board.data(forType: .png) == png, "PNG payload restored byte-for-byte")
expectFailure("cannot edit image as text") { try store.edit(id: imageEntry.id, text: "replace", title: "") }

let oversized = NSPasteboardItem(); oversized.setData(Data(repeating: 65, count: ClipboardStore.maximumCaptureBytes + 1), forType: .string)
setItems([oversized])
let beforeOversize = store.entries.count
expectFailure("oversized capture rejected") { _ = try store.capture(from: board) }
check(store.entries.count == beforeOversize, "oversized capture does not mutate history")

var pausedSettings = store.settings; pausedSettings.paused = true; try store.updateSettings(pausedSettings)
setText("Dragged while paused")
let imported = try store.importContent(from: board)!
check(imported.text == "Dragged while paused", "manual drag import works while capture paused")
let concealedImport = NSPasteboardItem(); concealedImport.setString("secret", forType: .string)
concealedImport.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
setItems([concealedImport])
check(try store.importContent(from: board) == nil, "manual import respects sensitive pasteboard marker")
pausedSettings.paused = false; try store.updateSettings(pausedSettings)
let missingPayload = try store.addText("payload will be missing")
try FileManager.default.removeItem(at: root.appendingPathComponent("payloads/" + missingPayload.id + ".plist"))
setText("keep clipboard")
expectFailure("missing payload raises error") { try store.write(id: missingPayload.id, to: board) }
check(board.string(forType: .string) == "keep clipboard", "missing payload does not clear clipboard")
try store.remove(ids: [missingPayload.id])

let reopened = ClipboardStore(directory: root)
check(reopened.entries.count == store.entries.count && reopened.lastError == nil, "history reopens from disk")
check(reopened.pinboards.first?.name == "常用", "pinboard rename persisted")
try reopened.write(id: richEntry.id, to: board)
check(board.data(forType: .rtf) == rtf, "payload survives process-style reopen")
let metadata = try Data(contentsOf: root.appendingPathComponent("state.json"))
check(!String(data: metadata, encoding: .utf8)!.contains(png.base64EncodedString()), "binary images are not embedded in metadata JSON")
let mode = (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber).intValue
let fileMode = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state.json").path)[.posixPermissions] as! NSNumber).intValue
check(mode == 0o700 && fileMode == 0o600, "private storage permissions")
try reopened.clear()
check(Set(reopened.entries.map { $0.id }) == Set([first.id, snippet.id]), "clear history preserves pinned items")
try reopened.removePinboard(id: pin.id)
check(reopened.entries.allSatisfy { $0.pinboardIDs.isEmpty }, "deleting pinboard returns entries to history")
try reopened.clear(includePinned: true)
check(reopened.entries.isEmpty, "explicit all-clear deletes entries")

let retentionRoot = root.appendingPathComponent("retention")
let retention = ClipboardStore(directory: retentionRoot)
let old = try retention.addText("old")
let pinnedOld = try retention.addText("pinned old")
let retentionPin = try retention.addPinboard(name: "Keep")
try retention.setPinned(id: pinnedOld.id, pinboardID: retentionPin.id, pinned: true)
let retentionIndex = retentionRoot.appendingPathComponent("state.json")
var fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: retentionIndex)) as! [String: Any]
var fixtureEntries = fixture["entries"] as! [[String: Any]]
for index in fixtureEntries.indices { fixtureEntries[index]["updatedAt"] = Date().addingTimeInterval(-40 * 86400).timeIntervalSinceReferenceDate }
fixture["entries"] = fixtureEntries
try JSONSerialization.data(withJSONObject: fixture).write(to: retentionIndex)
let retentionReloaded = ClipboardStore(directory: retentionRoot)
check(retentionReloaded.entries.map { $0.id } == [pinnedOld.id], "read-only reopen hides expired history immediately")
var retentionSettings = retentionReloaded.settings; retentionSettings.retentionDays = 30
try retentionReloaded.updateSettings(retentionSettings)
check(retentionReloaded.entries.map { $0.id } == [pinnedOld.id], "retention expires old history but preserves pinboard items")
check(!FileManager.default.fileExists(atPath: retentionRoot.appendingPathComponent("payloads/" + old.id + ".plist").path), "retention deletes expired binary payload")

let corruptRoot = root.appendingPathComponent("corrupt")
try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
let corrupted = Data("not JSON; preserve me".utf8)
try corrupted.write(to: corruptRoot.appendingPathComponent("state.json"))
let corrupt = ClipboardStore(directory: corruptRoot)
check(corrupt.lastError != nil, "corruption is surfaced")
expectFailure("corrupt store refuses writes") { _ = try corrupt.addText("overwrite") }
check(try Data(contentsOf: corruptRoot.appendingPathComponent("state.json")) == corrupted, "corruption does not overwrite original index")
expectFailure("path traversal rejected") { _ = try store.loadPayload(id: "../../config") }
// Real Vision OCR fixture: draw local text without using the user's clipboard or screen.
let context = CGContext(data: nil, width: 700, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 700, height: 140))
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "RightClick OCR 2026", attributes: [
    .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black
]))
context.textPosition = CGPoint(x: 25, y: 50); CTLineDraw(line, context)
let ocrPNG = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
let ocrItem = NSPasteboardItem(); ocrItem.setData(ocrPNG, forType: .png); setItems([ocrItem])
let ocrEntry = try store.capture(from: board)!
let deadline = Date().addingTimeInterval(45)
while store.query(text: "RightClick OCR").isEmpty && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
check(store.query(text: "RightClick OCR").contains { $0.id == ocrEntry.id }, "local Vision OCR makes image text searchable")
let advanced = ClipboardStore(directory: root.appendingPathComponent("advanced"))
var advancedSettings = advanced.settings; advancedSettings.enabled = true
advancedSettings.shortcuts = ["panel": ClipboardShortcut(keyCode: 9, modifiers: 256 | 2048, label: "⌥⌘V")]
try advanced.updateSettings(advancedSettings)
var duplicated = advancedSettings
duplicated.shortcuts?["stack"] = ClipboardShortcut(keyCode: 9, modifiers: 256 | 2048, label: "duplicate")
expectFailure("duplicate shortcuts rejected") { try advanced.updateSettings(duplicated) }
var noModifier = advancedSettings
noModifier.shortcuts = ["panel": ClipboardShortcut(keyCode: 9, modifiers: 512, label: "⇧V")]
expectFailure("shift-only global shortcut rejected") { try advanced.updateSettings(noModifier) }
var unsupported = advancedSettings
unsupported.shortcuts = ["panel": ClipboardShortcut(keyCode: 999, modifiers: 256, label: "bad")]
expectFailure("invalid key code rejected") { try advanced.updateSettings(unsupported) }
check(ClipboardStore(directory: root).settings.shortcuts == nil, "older JSON without shortcut property loads defaults")

let bold = NSAttributedString(string: "Bold template", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.red])
let richTemplate = try advanced.editRichText(attributedText: bold, title: "Rich template")
let restored = try advanced.attributedText(id: richTemplate.id)
let restoredFont = restored.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
check(NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask), "rich text editing preserves bold attributes")
let other = try advanced.addText("next")
try advanced.write(ids: [richTemplate.id, other.id], to: board)
check(board.string(forType: .string) == "Bold template\nnext", "formatted multi-copy includes combined plain fallback")
let combined = NSAttributedString(rtf: board.data(forType: .rtf)!, documentAttributes: nil)!
let combinedFont = combined.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
check(NSFontManager.shared.traits(of: combinedFont).contains(.boldFontMask), "multi-copy retains original rich text attributes")
let changed = try advanced.editRichText(id: richTemplate.id, attributedText: NSAttributedString(string: "changed", attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 16), toHaveTrait: .italicFontMask)]), title: "Edited")
check(changed.id == richTemplate.id && changed.text == "changed", "rich edit preserves identity")
let rtfdOnly = NSPasteboardItem()
rtfdOnly.setData(try bold.data(from: NSRange(location: 0, length: bold.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]), forType: .rtfd)
setItems([rtfdOnly])
let rtfdEntry = try advanced.capture(from: board)!
check(rtfdEntry.text == "Bold template", "RTFD-only content has searchable plain fallback")
try advanced.write(id: rtfdEntry.id, to: board, plainText: true)
check(board.string(forType: .string) == "Bold template", "RTFD-only content supports plain text paste")

let rotationItem = NSPasteboardItem(); rotationItem.setData(ocrPNG, forType: .png); setItems([rotationItem])
let rotationEntry = try advanced.capture(from: board)!
let rotationPin = try advanced.addPinboard(name: "Images")
try advanced.setPinned(id: rotationEntry.id, pinboardID: rotationPin.id, pinned: true)
try advanced.rename(id: rotationEntry.id, title: "Keep image title")
try advanced.rotateImage(id: rotationEntry.id)
let rotated = advanced.image(id: rotationEntry.id)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
check(rotated.width == 140 && rotated.height == 700, "image rotation swaps pixel dimensions")
check(advanced.entries.first { $0.id == rotationEntry.id }?.pinboardIDs == [rotationPin.id], "rotation preserves pinboard membership")
check(advanced.entries.first { $0.id == rotationEntry.id }?.title == "Keep image title", "rotation preserves custom title")
try advanced.rotateImage(id: rotationEntry.id, clockwise: false)
let unrotated = advanced.image(id: rotationEntry.id)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
check(unrotated.width == 700 && unrotated.height == 140, "counterclockwise rotation restores dimensions")

var scheduled = advanced.settings; scheduled.paused = true; scheduled.pausedUntil = Date().addingTimeInterval(0.1); scheduled.enabled = false
try advanced.updateSettings(scheduled)
advanced.startMonitoring()
let resumeDeadline = Date().addingTimeInterval(2)
while advanced.settings.paused && Date() < resumeDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
advanced.stopMonitoring()
check(!advanced.settings.paused && advanced.settings.pausedUntil == nil, "timed pause resumes automatically")
check(!advanced.settings.enabled, "scheduled resume does not enable disabled recording")
let orderedBoard = try advanced.addPinboard(name: "Ordered")
let secondBoard = try advanced.addPinboard(name: "Second")
try advanced.setPinboardColor(id: orderedBoard.id, color: "#a1B2c3")
check(advanced.pinboards.first { $0.id == orderedBoard.id }?.color == "A1B2C3", "pinboard hex color normalized")
expectFailure("invalid pinboard color rejected") { try advanced.setPinboardColor(id: orderedBoard.id, color: "xyz") }
try advanced.movePinboard(id: secondBoard.id, offset: -1)
check(advanced.pinboards.suffix(2).map { $0.id } == [secondBoard.id, orderedBoard.id], "pinboard order can move backward")
try advanced.movePinboard(id: secondBoard.id, offset: Int.max)
check(advanced.pinboards.last?.id == secondBoard.id, "pinboard movement clamps safely to end")
let orderedA = try advanced.addText("shared A", pinboardID: orderedBoard.id)
let orderedB = try advanced.addText("shared B", pinboardID: orderedBoard.id)
let orderedC = try advanced.editRichText(attributedText: NSAttributedString(string: "shared C"), title: "C", pinboardID: orderedBoard.id)
check(advanced.query(pinboardID: orderedBoard.id).map { $0.id } == [orderedA.id, orderedB.id, orderedC.id], "new pinned text and rich text append to board order")
try advanced.movePinnedItem(id: orderedC.id, pinboardID: orderedBoard.id, offset: -2)
check(advanced.query(text: "shared", pinboardID: orderedBoard.id).map { $0.id } == [orderedC.id, orderedA.id, orderedB.id], "search in pinboard preserves explicit order")
check(advanced.query(text: "shared").map { $0.id } == [orderedC.id, orderedB.id, orderedA.id], "history still sorts by copy time")
try advanced.setPinned(id: orderedC.id, pinboardID: orderedBoard.id, pinned: true)
check(advanced.query(pinboardID: orderedBoard.id).first?.id == orderedC.id, "idempotent pin does not reorder")
try advanced.setPinned(id: orderedC.id, pinboardID: orderedBoard.id, pinned: false)
check(advanced.pinboards.first { $0.id == orderedBoard.id }?.itemOrder?.contains(orderedC.id) == false, "unpin removes explicit order reference")
try advanced.setPinned(id: orderedC.id, pinboardID: orderedBoard.id, pinned: true)
check(advanced.query(pinboardID: orderedBoard.id).last?.id == orderedC.id, "repin appends at end")
try advanced.remove(ids: [orderedB.id])
check(advanced.pinboards.first { $0.id == orderedBoard.id }?.itemOrder?.contains(orderedB.id) == false, "deletion removes explicit order references")
let orderedReloaded = ClipboardStore(directory: advanced.directory)
check(orderedReloaded.pinboards.first { $0.id == orderedBoard.id }?.color == "A1B2C3", "pinboard color persists")
check(orderedReloaded.query(pinboardID: orderedBoard.id).map { $0.id } == [orderedA.id, orderedC.id], "pinboard item order persists")

let pdfData = NSMutableData()
let consumer = CGDataConsumer(data: pdfData as CFMutableData)!
var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
for _ in 0..<2 { pdfContext.beginPDFPage(nil); pdfContext.fill(CGRect(x: 20, y: 20, width: 100, height: 100)); pdfContext.endPDFPage() }
pdfContext.closePDF()
let pdfItem = NSPasteboardItem(); pdfItem.setData(pdfData as Data, forType: .pdf); setItems([pdfItem])
let pdfEntry = try advanced.importContent(from: board)!
check(pdfEntry.kind == "image", "PDF is retained as previewable content")
expectFailure("PDF rotation cannot flatten pages") { try advanced.rotateImage(id: pdfEntry.id) }
check(try advanced.loadPayload(id: pdfEntry.id).flatMap { $0 }.first { $0.type == NSPasteboard.PasteboardType.pdf.rawValue }?.data == pdfData as Data, "rejected PDF rotation preserves original bytes")

// Reproduce a copy immediately before starting a queue, without waiting for the 0.5s timer.
// The injected named board ensures the monitor never reads or changes the user's clipboard.
let pendingBoard = NSPasteboard(name: NSPasteboard.Name("rightclick.pending-tests." + UUID().uuidString))
defer { pendingBoard.releaseGlobally() }
let pending = ClipboardStore(directory: root.appendingPathComponent("pending"), monitorPasteboard: pendingBoard)
var pendingSettings = pending.settings; pendingSettings.enabled = true
try pending.updateSettings(pendingSettings)
var queueActive = false
var queuedTexts = [String]()
var observedCopies = [ClipboardEntry]()
pending.onCapture = { entry in
    observedCopies.append(entry)
    if queueActive { queuedTexts.append(entry.text) }
}
pendingBoard.clearContents(); pendingBoard.setString("before queue X", forType: .string)
try pending.flushPendingCapture()
queueActive = true
check(pending.entries.map { $0.text } == ["before queue X"], "pre-queue copy is saved to ordinary history immediately")
check(queuedTexts.isEmpty, "pre-queue copy is not delivered to the new queue")
check(pendingBoard.string(forType: .string) == "before queue X", "flushing preserves the current clipboard content")
check(observedCopies.first?.sourceApp == "未知应用" && observedCopies.first?.sourceBundleID == "", "flush uses the store's tracked source instead of querying a new frontmost app")
try pending.flushPendingCapture()
check(observedCopies.count == 1 && queuedTexts.isEmpty, "next poll cannot add the already flushed copy to the queue")
pendingBoard.clearContents(); pendingBoard.setString("after queue A", forType: .string)
try pending.flushPendingCapture()
check(queuedTexts == ["after queue A"], "only copies after queue activation enter the new queue")
let savedX = pending.entries.first { $0.text == "before queue X" }!
try pending.write(id: savedX.id, to: pendingBoard)
try pending.flushPendingCapture()
check(observedCopies.count == 2 && queuedTexts == ["after queue A"], "writing a saved item back to the monitored board is not recaptured")
pendingBoard.clearContents(); pendingBoard.setString("after queue A", forType: .string)
try pending.flushPendingCapture()
check(queuedTexts == ["after queue A", "after queue A"], "intentional repeated copies remain separate queue events")

let retryBoard = NSPasteboard(name: NSPasteboard.Name("rightclick.retry-tests." + UUID().uuidString))
defer { retryBoard.releaseGlobally() }
let retryRoot = root.appendingPathComponent("pending-retry")
let retryStore = ClipboardStore(directory: retryRoot, monitorPasteboard: retryBoard)
var retrySettings = retryStore.settings; retrySettings.enabled = true
try retryStore.updateSettings(retrySettings)
retryStore.startMonitoring()
defer { retryStore.stopMonitoring() }
var retryNotifications = 0
retryStore.onChange = { retryNotifications += 1 }
let payloadDirectory = retryRoot.appendingPathComponent("payloads")
try FileManager.default.removeItem(at: payloadDirectory)
try Data("temporary storage failure".utf8).write(to: payloadDirectory)
retryBoard.clearContents(); retryBoard.setString("retry the pending copy", forType: .string)
expectFailure("pre-queue flush reports storage failure to its caller") { try retryStore.flushPendingCapture() }
check(retryBoard.string(forType: .string) == "retry the pending copy" && retryStore.entries.isEmpty, "failed flush preserves the unsaved clipboard instead of starting a queue")
RunLoop.current.run(until: Date().addingTimeInterval(0.65))
check(retryNotifications == 0, "timer does not repeatedly retry an unchanged failing clipboard")
try FileManager.default.removeItem(at: payloadDirectory)
try retryStore.flushPendingCapture()
check(retryStore.entries.map { $0.text } == ["retry the pending copy"], "failed pending copy remains eligible for retry without another copy action")
print("Clipboard core: \(checks) checks passed")
