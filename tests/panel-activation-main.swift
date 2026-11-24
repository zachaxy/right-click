import Cocoa

// Intercept application-wide activation while exercising the real show methods.
// The panels stay offscreen, capture uses a named pasteboard, and no translation
// text is submitted. This test never activates the user's installed RightClick.
final class RecordingApplication: NSApplication {
    var activationRequests = [Bool]()
    override func activate(ignoringOtherApps flag: Bool) {
        activationRequests.append(flag)
    }
}

// Direct AppKit's native text copy to the same isolated board as history copies.
final class TestFieldEditor: NSTextView, NSWindowDelegate {
    var copyBoard: NSPasteboard!
    override func copy(_ sender: Any?) {
        _ = writeSelection(to: copyBoard, types: [.string])
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        return client is NSSearchField ? self : nil
    }
}

guard let app = RecordingApplication.shared as? RecordingApplication else {
    fputs("FAIL: NSApplication.shared did not instantiate the recording subclass\n", stderr)
    exit(1)
}
app.setActivationPolicy(.prohibited)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-activation-tests-" + UUID().uuidString)
let board = NSPasteboard(name: .init("rightclick.activation.tests." + UUID().uuidString))
let store = ClipboardStore(directory: directory, monitorPasteboard: board)
let translation = TranslationPanelController()
let clipboard = ClipboardPanelController(store: store, copyPasteboard: board)
var checks = 0
var failures = [String]()
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures.append(message) }
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

let panels: [(String, NSPanel, () -> Void, () -> Void)] = [
    ("translation", translation.window, { translation.show() }, { translation.hide() }),
    ("clipboard", clipboard.window, { clipboard.show() }, { clipboard.hide() }),
]
for (name, window, show, hide) in panels {
    window.setFrameAutosaveName("")
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    let previousCount = app.activationRequests.count
    show()
    check(app.activationRequests.count == previousCount,
          "\(name) show must not activate the entire application and raise its main window")
    check(window.styleMask.contains(.nonactivatingPanel),
          "\(name) uses a nonactivating panel to preserve the current application's windows")
    check(window.level == .floating,
          "\(name) stays above the foreground application's normal windows without activating the app")
    check(window.canBecomeKey && !window.canBecomeMain,
          "\(name) can receive keyboard input without becoming the application's main window")
    check(!window.hidesOnDeactivate && !window.becomesKeyOnlyIfNeeded,
          "\(name) remains available while its application is inactive and can accept direct keyboard focus")
    if name == "clipboard" {
        if let search = descendants(window.contentView!).compactMap({ $0 as? NSSearchField }).first {
            let editor = search.currentEditor()
            check(window.firstResponder === search || (editor != nil && window.firstResponder === editor),
                  "clipboard show places keyboard focus in its native search field without activating the app")
        } else {
            check(false, "clipboard panel exposes its native search field")
        }
    }
    hide()
    check(!window.isVisible, "\(name) hides after use")
}
let previewTitle = "RightClick isolated preview fixture"
let fixtureText = "A local fixture for checking preview window ordering."
_ = try store.addText(fixtureText, title: previewTitle)

let clipboardViews = descendants(clipboard.window.contentView!)
let testEditor = TestFieldEditor(frame: .zero)
testEditor.isFieldEditor = true
testEditor.copyBoard = board
clipboard.window.makeFirstResponder(nil)
clipboard.window.delegate = testEditor
clipboard.show()
if let pin = clipboardViews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "保持窗口打开" }),
   let search = clipboardViews.compactMap({ $0 as? NSSearchField }).first,
   let editor = search.currentEditor() as? TestFieldEditor {
    search.stringValue = "fixture"
    clipboard.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    editor.setSelectedRange(NSRange(location: 0, length: 3))
    let copyKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: clipboard.window.windowNumber, context: nil,
        characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    app.sendEvent(copyKey)
    check(clipboard.window.isVisible && board.string(forType: .string) != fixtureText &&
          editor.selectedRange() == NSRange(location: 0, length: 3),
          "Cmd-C on selected search text leaves the panel open and preserves the field editor selection")
    editor.setSelectedRange(NSRange(location: 3, length: 0))
    app.sendAction(pin.action!, to: pin.target, from: pin)
    app.sendEvent(copyKey)
    let confirmsCopy = clipboardViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("已复制") }
    check(clipboard.window.isVisible && board.string(forType: .string) == fixtureText && confirmsCopy,
          "Cmd-C in a pinned panel copies the record and confirms success without dismissing the panel")
    app.sendAction(pin.action!, to: pin.target, from: pin)
    board.clearContents()
    app.sendEvent(copyKey)
    check(!clipboard.window.isVisible && board.string(forType: .string) == fixtureText,
          "Cmd-C on a history result consumes the key, copies the full record and dismisses the visible panel")
} else {
    check(false, "clipboard exposes the pin button and active search field editor for the visible copy checks")
}
clipboard.window.delegate = clipboard
// Quick Look is a separate tool window and must stay above the floating history panel.
let previewObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { notification in
    if let window = notification.object as? NSWindow, window.title == previewTitle {
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    }
}
let activationCountBeforePreview = app.activationRequests.count
clipboard.perform(NSSelectorFromString("showPreview"))
if let preview = app.windows.first(where: { $0.title == previewTitle }) {
    check(preview.level == .floating && preview.styleMask.contains(.nonactivatingPanel),
          "clipboard preview floats above normal windows while preserving nonactivating behavior")
    check(app.activationRequests.count == activationCountBeforePreview,
          "opening clipboard preview does not activate the entire application")
} else {
    check(false, "the local fixture opens an actual clipboard preview window")
}
clipboard.hide()
NotificationCenter.default.removeObserver(previewObserver)
// The foreground application can still be external while a nonactivating panel
// owns keyboard focus. Its editor must receive Cmd-V instead of advancing the
// clipboard queue, without suppressing normal stack paste into an external app.
check(!ClipboardCoordinator.shouldInterceptPaste(type: .keyDown, flags: .maskCommand, hasLocalKeyWindow: true),
      "Cmd-V inside a local tool panel is not intercepted by the global paste queue")
check(ClipboardCoordinator.shouldInterceptPaste(type: .keyDown, flags: .maskCommand, hasLocalKeyWindow: false),
      "Cmd-V in an external application remains eligible for sequential paste")
for flags: CGEventFlags in [[], [.maskCommand, .maskShift], [.maskCommand, .maskAlternate], [.maskCommand, .maskControl]] {
    check(!ClipboardCoordinator.shouldInterceptPaste(type: .keyDown, flags: flags, hasLocalKeyWindow: false),
          "plain typing and modified paste shortcuts do not advance the queue (flags \(flags.rawValue))")
}
check(!ClipboardCoordinator.shouldInterceptPaste(type: .keyUp, flags: .maskCommand, hasLocalKeyWindow: false),
      "releasing Cmd-V never starts another paste operation")
check(app.activationPolicy() == .prohibited && !store.settings.enabled,
      "isolated activation checks keep application activation and clipboard capture disabled")
translation.hide()
clipboard.hide()
board.releaseGlobally()
try? FileManager.default.removeItem(at: directory)
if !failures.isEmpty {
    for failure in failures { fputs("FAIL: " + failure + "\n", stderr) }
    exit(1)
}
print("Panel activation: \(checks) isolated checks passed")
