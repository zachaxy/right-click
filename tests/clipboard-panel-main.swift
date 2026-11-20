import Cocoa

// Exercise AppKit views in-process: no visible windows, global key events or general pasteboard.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-panel-tests-" + UUID().uuidString)
let board = NSPasteboard(name: .init("rightclick.panel.tests." + UUID().uuidString))
defer { try? FileManager.default.removeItem(at: directory); board.releaseGlobally() }
let store = ClipboardStore(directory: directory, monitorPasteboard: board)
let favorite = try store.addPinboard(name: "Panel test favorites")
for index in 1...18 { _ = try store.addText("Panel fixture \(index): enough rows to require scrolling.") }
let meeting = try store.addText("Meeting checklist\nConfirm the plan\nReview the design", title: "Meeting")
_ = try store.addText("https://example.invalid/panel-fixture", title: "Link fixture")
let image = CGContext(data: nil, width: 240, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
image.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.7, alpha: 1))
image.fill(CGRect(x: 0, y: 0, width: 240, height: 80))
let png = NSBitmapImageRep(cgImage: image.makeImage()!).representation(using: .png, properties: [:])!
board.clearContents(); board.setData(png, forType: .png)
_ = try store.importContent(from: board)
let pinned = try store.addText("Pinned panel fixture", pinboardID: favorite.id)
let newest = try store.addText("Newest panel fixture")

let panel = ClipboardPanelController(store: store, copyPasteboard: board)
panel.window.setFrameAutosaveName("")
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: " + message + "\n", stderr); exit(1) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func settle() {
    panel.window.contentView!.layoutSubtreeIfNeeded()
    panel.window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
func hasSize(_ width: CGFloat, _ height: CGFloat) -> Bool {
    abs(panel.window.frame.width - width) < 0.5 && abs(panel.window.frame.height - height) < 0.5
}
panel.window.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
settle()
let content = panel.window.contentView!
let views = descendants(content)
let table = views.compactMap { $0 as? NSTableView }.first!
let search = views.compactMap { $0 as? NSSearchField }.first!
let recording = views.compactMap { $0 as? NSButton }.first { $0.title == "记录" }!
let footer = recording.superview!
let scroll = table.enclosingScrollView!
func footerTouchesBottom() -> Bool {
    let frame = footer.convert(footer.bounds, to: content)
    return abs(frame.minY - content.bounds.minY) < 0.5 && frame.height <= 40
}
func selectTab(_ title: String) {
    let button = views.compactMap { $0 as? NSButton }.first { $0.title == title || $0.title.hasPrefix(title + " (") }!
    NSApp.sendAction(button.action!, to: button.target, from: button)
    settle()
}
func searchFor(_ text: String) {
    search.stringValue = text
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    settle()
}
var pasted = [ClipboardEntry]()
var pastedPlain = false
panel.onPaste = { pasted = $0; pastedPlain = $1 }
func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: panel.window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    table.keyDown(with: event)
}

check(!panel.window.isVisible && app.activationPolicy() == .prohibited && !store.settings.enabled,
      "panel tests stay hidden and recording remains disabled")
check(table.numberOfRows == 23 && table.selectedRowIndexes.isEmpty, "initial records appear without implicitly checking one")
check(hasSize(800, 600) && scroll.bounds.width > 700, "layout keeps the requested 800x600 window and full-width history")
check(footerTouchesBottom(), "footer remains at the bottom at 800x600")
let visibleRows = table.rows(in: table.visibleRect)
check(visibleRows.length > 3 && visibleRows.length < table.numberOfRows, "mixed text and image history has a usable scrolling viewport")

key(36, "\r")
check(pasted.map { $0.id } == [newest.id] && !pastedPlain, "Return pastes the initial current item without a checked selection")
key(125, "\u{F701}"); key(36, "\r", modifiers: .shift)
check(pasted.map { $0.id } == [pinned.id] && pastedPlain, "arrow navigation and Shift Return use the current item as plain text")
table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
key(36, "\r")
check(pasted.map { $0.id } == [newest.id, pinned.id] && !pastedPlain, "batch paste follows displayed row order")
panel.perform(NSSelectorFromString("clearSelection")); key(36, "\r")
check(table.selectedRowIndexes.isEmpty && pasted.count == 1, "clearing checked rows retains a usable keyboard item")

selectTab("图像")
check(table.numberOfRows == 1 && hasSize(800, 600), "image filtering cannot shrink the window")
selectTab("收藏"); key(36, "\r")
check(table.numberOfRows == 1 && pasted.map { $0.id } == [pinned.id] && hasSize(800, 600), "favorites tab filters and pastes its saved item")
selectTab("全部"); searchFor("Meeting checklist"); key(36, "\r")
let matchingSearch = table.numberOfRows == 1 && pasted.map { $0.id } == [meeting.id]
searchFor("absent-panel-fixture")
let emptySearch = table.numberOfRows == 0 && hasSize(800, 600)
searchFor(""); _ = try store.addText("New capture refresh fixture"); settle()
check(matchingSearch && emptySearch && table.numberOfRows == 24 && hasSize(800, 600),
      "matching, empty and refreshed history preserve the requested window size")

panel.window.setFrame(NSRect(x: 0, y: 0, width: 680, height: 440), display: false)
settle()
check(hasSize(680, 440) && panel.window.minSize == NSSize(width: 680, height: 440)
      && scroll.bounds.width >= 610 && scroll.bounds.height >= 300, "minimum 680x440 window keeps a usable history viewport")
check(footerTouchesBottom(), "footer stays at the bottom after shrinking the window")
table.scrollRowToVisible(table.numberOfRows - 1); settle()
check(NSMaxRange(table.rows(in: table.visibleRect)) == table.numberOfRows && !panel.window.isVisible,
      "last record remains reachable by scrolling without showing a window")

// Inspect the actual shared field editor, including both keyboard-focus and
// mouse-editing entry points. Its text must stay inside the native icon margins.
let searchCell = search.cell as! NSSearchFieldCell
func focusSearch() -> NSTextView {
    panel.window.makeFirstResponder(search)
    settle()
    guard let editor = search.currentEditor() as? NSTextView else {
        fputs("FAIL: search field editor unavailable\n", stderr); exit(1)
    }
    return editor
}
func editorUsesSearchTextRect(_ editor: NSTextView) -> Bool {
    let actual = editor.convert(editor.bounds, to: search)
    let expected = searchCell.searchTextRect(forBounds: search.bounds)
    return expected.width > 0 && abs(actual.minX - expected.minX) < 0.5
        && abs(actual.maxX - expected.maxX) < 0.5
}
searchFor("")
for size in [NSSize(width: 800, height: 600), NSSize(width: 680, height: 440)] {
    panel.window.makeFirstResponder(nil)
    panel.window.setFrame(NSRect(origin: .zero, size: size), display: false)
    settle()
    let editor = focusSearch()
    check(editorUsesSearchTextRect(editor), "focused search editor reserves icon space at \(Int(size.width))px")
    panel.window.makeFirstResponder(nil)
    searchCell.edit(withFrame: search.bounds, in: search, editor: editor, delegate: search, event: nil)
    settle()
    check(editorUsesSearchTextRect(editor), "mouse-editing entry reserves search and clear-button space at \(Int(size.width))px")
    searchCell.endEditing(editor)
}

// Send events through NSApplication and the panel's local monitor, rather than
// calling table.keyDown directly. setMarkedText uses the native field editor's
// composition contract without changing the user's selected input method.
let compositionMatch = try store.addText("zhong input-method fixture")
func dispatchKey(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: panel.window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    NSApp.sendEvent(event)
}
func beginComposition() -> NSTextView {
    panel.window.makeFirstResponder(nil)
    searchFor("")
    let editor = focusSearch()
    editor.setMarkedText("zhong", selectedRange: NSRange(location: 0, length: 5),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
    check(editor.hasMarkedText(), "search editor represents an active input-method composition")
    return editor
}
var editor = beginComposition()
pasted = []
dispatchKey(36, "\r")
check(pasted.isEmpty, "Return during composition never pastes a clipboard record")
editor.unmarkText()
searchFor("zhong")
_ = focusSearch()
dispatchKey(36, "\r")
check(pasted.map { $0.id } == [compositionMatch.id] && !pastedPlain,
      "a separate Return after composition pastes the matching result")

editor = beginComposition()
pasted = []
dispatchKey(36, "\r", modifiers: .shift)
check(pasted.isEmpty, "Shift Return during composition cannot trigger plain-text paste")
editor.unmarkText()
searchFor("zhong")
_ = focusSearch()
dispatchKey(36, "\r", modifiers: .shift)
check(pasted.map { $0.id } == [compositionMatch.id] && pastedPlain,
      "a separate Shift Return after composition still pastes plain text")
panel.window.makeFirstResponder(nil)
check(!panel.window.isVisible && !store.settings.enabled, "input-method checks never show a window or enable recording")

// Opening the panel focuses the search editor. Hardware arrow events include
// function/numeric-pad flags even though no shortcut modifiers are held.
func activeTabTitle() -> String? {
    views.compactMap { $0 as? NSButton }
        .first { $0.action == NSSelectorFromString("selectTab:") && $0.state == .on }?
        .title.components(separatedBy: " (").first
}
let hardwareArrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
selectTab("全部"); searchFor(""); _ = focusSearch()
dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags); settle()
check(activeTabTitle() == "文本", "Right switches from All to Text while the empty search editor has focus")
for (title, count) in [("图像", 1), ("文件", 0), ("收藏", 1), ("全部", 25)] {
    dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags); settle()
    check(activeTabTitle() == title && table.numberOfRows == count,
          "Right cycles to \(title) and applies its content filter, including empty tabs")
}
for title in ["收藏", "文件", "图像", "文本", "全部"] {
    dispatchKey(123, "\u{F702}", modifiers: hardwareArrowFlags); settle()
    check(activeTabTitle() == title, "Left cycles back to \(title), including the first-tab boundary")
}
check(search.currentEditor() === panel.window.firstResponder && search.stringValue.isEmpty,
      "tab cycling retains the empty search editor so typing can continue")

dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags.union(.capsLock)); settle()
check(activeTabTitle() == "文本", "Caps Lock does not turn ordinary arrow navigation into a different shortcut")
selectTab("全部")
for modifier: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
    dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags.union(modifier)); settle()
    check(activeTabTitle() == "全部", "modified Right does not switch tabs (flags \(modifier.rawValue))")
}

searchFor("abcde"); editor = focusSearch()
editor.setSelectedRange(NSRange(location: 2, length: 0))
// A hidden, prohibited application runs the local monitor but does not deliver
// unhandled keys to its editor. Check the guard here; actual caret movement is
// verified in the installed application's live keyboard test.
dispatchKey(123, "\u{F702}", modifiers: hardwareArrowFlags); settle()
check(activeTabTitle() == "全部" && search.stringValue == "abcde",
      "Left during nonempty search does not change category or query")
dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags); settle()
check(activeTabTitle() == "全部" && search.stringValue == "abcde",
      "Right during nonempty search does not change category or query")

for (code, characters): (UInt16, String) in [(123, "\u{F702}"), (124, "\u{F703}")] {
    editor = beginComposition()
    dispatchKey(code, characters, modifiers: hardwareArrowFlags); settle()
    check(activeTabTitle() == "全部", "arrow key \(code) during input-method composition does not switch category")
    editor.unmarkText()
}

panel.window.makeFirstResponder(nil)
searchFor("Meeting checklist"); panel.window.makeFirstResponder(table)
dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags); settle()
check(activeTabTitle() == "文本" && table.numberOfRows == 1 && search.stringValue == "Meeting checklist",
      "Right from the results list changes category and retains the current query")
dispatchKey(124, "\u{F703}", modifiers: hardwareArrowFlags); settle()
check(activeTabTitle() == "图像" && table.numberOfRows == 0 && search.stringValue == "Meeting checklist",
      "query remains applied when keyboard navigation reaches a category with no matches")
dispatchKey(123, "\u{F702}", modifiers: hardwareArrowFlags); settle()
check(activeTabTitle() == "文本" && table.numberOfRows == 1 && panel.window.firstResponder === table,
      "Left can leave an empty category and preserves results-list focus")
check(!panel.window.isVisible && app.activationPolicy() == .prohibited && !store.settings.enabled,
      "tab-key tests never show a window, enable recording or require accessibility permission")

// Row navigation intentionally leaves typing in the search editor. Cmd-C must
// still copy the current result, using the real payload writer on a named board.
let copyRich = try store.editRichText(attributedText: NSAttributedString(
    string: "keyboard-copy rich history fixture", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]),
    title: "Keyboard copy rich fixture")
let copyNewest = try store.addText("keyboard-copy newest history fixture")
func resetCopyBoard() {
    board.clearContents()
    board.setString("copy-test sentinel", forType: .string)
}
selectTab("全部"); searchFor("keyboard-copy"); editor = focusSearch()
editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
dispatchKey(125, "\u{F701}", modifiers: hardwareArrowFlags)
check(panel.window.firstResponder === editor && editor.selectedRange().length == 0 && table.selectedRowIndexes.isEmpty,
      "Down highlights a history row while the unselected search editor retains keyboard focus")
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == copyRich.text && board.data(forType: .rtf) != nil,
      "Cmd-C after Down copies the highlighted record with its rich-text payload")
dispatchKey(126, "\u{F700}", modifiers: hardwareArrowFlags)
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == copyNewest.text,
      "Cmd-C after Up copies the newly highlighted record without clicking the toolbar")

searchFor("keyboard-copy"); editor = focusSearch()
editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
dispatchKey(125, "\u{F701}", modifiers: hardwareArrowFlags)
check(panel.window.firstResponder === editor && editor.selectedRange().length == 0 && search.stringValue == "keyboard-copy",
      "Down collapses an old query selection without clearing the query or moving typing out of search")
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == copyRich.text,
      "an initially selected query does not defeat copying the row chosen with Down")

// An explicit text selection made after navigation belongs to the editor. The
// hidden application does not deliver unhandled keys, so test non-interception
// first, then ask the native editor to write its actual selection to our board.
editor.setSelectedRange(NSRange(location: 0, length: 8))
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == "copy-test sentinel" && editor.selectedRange() == NSRange(location: 0, length: 8),
      "Cmd-C preserves an explicit search-text selection instead of copying a history record")
let queryCopyType = editor.writablePasteboardTypes.first!
check(editor.writeSelection(to: board, types: [queryCopyType]) && board.string(forType: queryCopyType) == "keyboard",
      "the search editor's ordinary copy selection remains the selected query text")
editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
resetCopyBoard(); dispatchKey(8, "C", modifiers: [.command, .shift])
check(board.string(forType: .string) == copyRich.text && board.data(forType: .rtf) == nil,
      "Cmd-Shift-C from the search caret copies the current rich record as plain text")
resetCopyBoard(); dispatchKey(8, "C", modifiers: [.command, .capsLock])
check(board.string(forType: .string) == copyRich.text && board.data(forType: .rtf) != nil,
      "Caps Lock does not change Cmd-C history copying")

panel.window.makeFirstResponder(table)
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == copyRich.text,
      "Cmd-C still copies the current record when the result table has focus")
table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == copyNewest.text + "\n" + copyRich.text,
      "Cmd-C preserves multi-row copying in displayed order")
table.deselectAll(nil); editor = focusSearch()
editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
for modifiers: NSEvent.ModifierFlags in [[.command, .option], [.command, .control], [.command, .shift, .option]] {
    resetCopyBoard(); dispatchKey(8, "c", modifiers: modifiers)
    check(board.string(forType: .string) == "copy-test sentinel",
          "other modified C shortcuts do not overwrite the clipboard with history (flags \(modifiers.rawValue))")
}
editor = beginComposition()
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(board.string(forType: .string) == "copy-test sentinel" && editor.hasMarkedText(),
      "Cmd-C during input-method composition is left to the editor")
editor.unmarkText(); panel.window.makeFirstResponder(nil)
check(!panel.window.isVisible && !store.settings.enabled,
      "copy shortcut checks never show a window, access the general pasteboard or enable recording")

// A list click leaves the table as first responder. The first printable event
// must enter the native search editor exactly once, then normal editing resumes.
selectTab("全部"); searchFor(""); panel.window.makeFirstResponder(table)
dispatchKey(40, "k"); settle()
check(search.currentEditor() === panel.window.firstResponder && search.stringValue == "k",
      "typing from the result table focuses search and preserves the first character exactly once")
guard let typingEditor = search.currentEditor() as? NSTextView else { fatalError("typing search editor unavailable") }
// The hidden application does not route unhandled events into its field editor;
// deliver later ordinary typing directly to the native editor that now owns it.
let continuedTyping = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: panel.window.windowNumber, context: nil, characters: "e", charactersIgnoringModifiers: "e",
    isARepeat: false, keyCode: 14)!
typingEditor.keyDown(with: continuedTyping); settle()
check(search.stringValue == "ke" && panel.window.firstResponder === typingEditor,
      "continued typing appends normally after the initial table-to-search handoff")

searchFor(""); panel.window.makeFirstResponder(table)
dispatchKey(0, "A", modifiers: .shift); settle()
check(search.stringValue == "A" && search.currentEditor() === panel.window.firstResponder,
      "uppercase typing from the table preserves the original shifted character")
searchFor(""); panel.window.makeFirstResponder(table)
dispatchKey(43, ","); settle()
check(search.stringValue == "," && search.currentEditor() === panel.window.firstResponder,
      "printable punctuation from the table becomes search text")
searchFor("keyboard-"); panel.window.makeFirstResponder(table)
dispatchKey(8, "c"); settle()
check(search.stringValue == "keyboard-c" && table.numberOfRows == 2,
      "typing from the table appends to an existing query and refreshes filtered results")
panel.window.makeFirstResponder(table)
dispatchKey(31, "o"); settle()
check(search.stringValue == "keyboard-co",
      "repeated table-to-search handoffs append once without replacing or duplicating the query")

for (code, characters, modifiers): (UInt16, String, NSEvent.ModifierFlags) in [
    (51, "\u{7f}", []), (122, "\u{F704}", [.function]), (0, "a", .command), (0, "a", .control)
] {
    searchFor("keyboard-copy"); panel.window.makeFirstResponder(table)
    dispatchKey(code, characters, modifiers: modifiers); settle()
    check(panel.window.firstResponder === table && search.stringValue == "keyboard-copy",
          "nontext or command/control input does not redirect from the table (key \(code), flags \(modifiers.rawValue))")
}
searchFor("keyboard-copy"); panel.window.makeFirstResponder(table)
dispatchKey(125, "\u{F701}", modifiers: hardwareArrowFlags)
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(panel.window.firstResponder === table && board.string(forType: .string) == copyRich.text,
      "Down and Cmd-C still select and copy history instead of starting a search")
dispatchKey(126, "\u{F700}", modifiers: hardwareArrowFlags)
resetCopyBoard(); dispatchKey(8, "c", modifiers: .command)
check(panel.window.firstResponder === table && board.string(forType: .string) == copyNewest.text,
      "Up navigation and history copying remain intact after typing handoffs")

editor = beginComposition()
let markedBeforeTyping = editor.markedRange()
dispatchKey(0, "a")
check(panel.window.firstResponder === editor && editor.hasMarkedText() && editor.markedRange() == markedBeforeTyping,
      "typing while the native editor is composing is not redirected or manually appended")
editor.unmarkText(); panel.window.makeFirstResponder(nil)
check(!panel.window.isVisible && app.activationPolicy() == .prohibited && !store.settings.enabled,
      "type-to-search checks remain isolated from visible windows and clipboard monitoring")
print("Clipboard panel: \(checks) isolated UI checks passed")
