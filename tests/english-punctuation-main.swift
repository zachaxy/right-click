import Cocoa
import Carbon

// Synthetic events stay inside the process. No global tap or event posting is needed.
_ = NSApplication.shared
func key(_ code: Int, _ characters: String, _ flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    event.flags = flags
    let units = Array(characters.utf16)
    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    return event
}
func converted(_ event: CGEvent, ime: Bool = true) -> String? {
    var filter = EnglishPunctuationFilter()
    guard var unit = filter.replacement(for: event, usesInputMethod: ime) else { return nil }
    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
    return NSEvent(cgEvent: event)?.characters
}
precondition(converted(key(kVK_ANSI_Comma, "，")) == ",")
precondition(converted(key(kVK_ANSI_Period, "。")) == ".")
precondition(converted(key(kVK_ANSI_Quote, "“", .maskShift)) == "\"")
precondition(converted(key(kVK_ANSI_LeftBracket, "【")) == "[")
precondition(converted(key(kVK_ANSI_1, "!", .maskShift)) == "!")
precondition(converted(key(kVK_ANSI_1, "1")) == nil)
precondition(converted(key(kVK_ANSI_A, "a")) == nil)
precondition(converted(key(kVK_ANSI_Comma, "，汉")) == nil)
precondition(converted(key(kVK_ANSI_Comma, "～", .maskAlternate)) == nil)
for flags: CGEventFlags in [.maskCommand, .maskControl, .maskSecondaryFn] {
    precondition(converted(key(kVK_ANSI_Period, ".", flags)) == nil)
}
precondition(converted(key(kVK_ANSI_Semicolon, ";"), ime: false) == nil)

var filter = EnglishPunctuationFilter()
func rewrite(_ event: CGEvent) -> UniChar? { filter.replacement(for: event, usesInputMethod: true) }
precondition(rewrite(key(kVK_ANSI_N, "n")) == nil)
precondition(rewrite(key(kVK_ANSI_I, "i")) == nil)
precondition(rewrite(key(kVK_ANSI_Quote, "'")) == nil) // Pinyin syllable separator
precondition(rewrite(key(kVK_ANSI_Period, ".")) == nil) // Candidate page command
precondition(rewrite(key(kVK_Space, " ")) == nil)
precondition(rewrite(key(kVK_ANSI_Period, ".")) == 46)
precondition(rewrite(key(kVK_ANSI_N, "n")) == nil)
precondition(rewrite(key(kVK_ANSI_2, "2")) == nil) // Choose candidate #2
precondition(rewrite(key(kVK_ANSI_Comma, ",")) == 44)
precondition(rewrite(key(kVK_ANSI_N, "n")) == nil)
precondition(rewrite(key(kVK_ANSI_I, "i")) == nil)
precondition(rewrite(key(kVK_Delete, "\u{7F}")) == nil)
precondition(rewrite(key(kVK_ANSI_Quote, "'")) == nil) // A letter still remains.
precondition(rewrite(key(kVK_Delete, "\u{7F}")) == nil) // Delete the syllable separator.
precondition(rewrite(key(kVK_ANSI_Period, ".")) == nil)
precondition(rewrite(key(kVK_Delete, "\u{7F}")) == nil) // Delete the last letter.
precondition(rewrite(key(kVK_ANSI_Comma, ",")) == 44)
precondition(rewrite(key(kVK_ANSI_N, "n")) == nil)
precondition(rewrite(key(kVK_Delete, "\u{7F}")) == nil)
precondition(rewrite(key(kVK_ANSI_Comma, ",")) == 44)
let monitor = EnglishPunctuationMonitor()
monitor.update(bundleIDs: [])
precondition(!monitor.isRunning && monitor.status.isEmpty)
print("PASS: English punctuation, modifiers, composition, and disabled monitor")
