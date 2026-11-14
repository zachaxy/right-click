import Cocoa
import Carbon

/// Tracks only an estimated length; the composing text stays in the input method.
struct EnglishPunctuationFilter {
    private var pendingLetters = 0

    mutating func reset() { pendingLetters = 0 }

    mutating func replacement(for event: CGEvent, usesInputMethod: Bool) -> UniChar? {
        let flags = event.flags
        let shortcuts: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard flags.intersection(shortcuts).isEmpty else { return nil }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch key {
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Tab, kVK_Space:
            reset()
            return nil
        case kVK_Delete:
            if pendingLetters > 0 { pendingLetters -= 1 }
            return nil
        default: break
        }

        // Use the event's layout translation. The same physical key can be punctuation
        // on one layout and a letter or a dead key on another.
        guard let characters = NSEvent(cgEvent: event)?.characters,
              characters.utf16.count == 1, let character = characters.utf16.first else { return nil }
        switch character {
        case 65...90, 97...122:
            pendingLetters = usesInputMethod ? pendingLetters + 1 : 0
            return nil
        case 48...57:
            reset() // Number keys commonly commit a candidate.
            return nil
        default: break
        }
        // A separator, quote or punctuation key during composition can be a candidate
        // command. Let the input method finish interpreting the pending word.
        if pendingLetters > 0 {
            if character == 39 { pendingLetters += 1 } // A Pinyin syllable separator is editable.
            return nil
        }
        let ascii: UniChar
        switch character {
        case 0xFF01...0xFF5E: ascii = character - 0xFEE0
        case 0x3002: ascii = 46                   // 。
        case 0x2018, 0x2019: ascii = 39           // ‘ ’
        case 0x201C, 0x201D: ascii = 34           // “ ”
        case 0x3010: ascii = 91                   // 【
        case 0x3011: ascii = 93                   // 】
        case 0x300A: ascii = 60                   // 《
        case 0x300B: ascii = 62                   // 》
        case 0x3001: ascii = 92                   // 、
        default:
            guard usesInputMethod else { return nil }
            ascii = character
        }
        switch ascii {
        case 33...47, 58...64, 91...96, 123...126: return ascii
        default: return nil
        }
    }
}

/// Called on the main run loop. The tap rewrites only a matching application's event
/// in place, so the original delivery order, physical key pair and target are preserved.
final class EnglishPunctuationMonitor {
    private var bundleIDs = Set<String>()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var sourceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var usesInputMethod = false
    private var filter = EnglishPunctuationFilter()
    private(set) var status = ""
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func update(bundleIDs: Set<String>) {
        if self.bundleIDs != bundleIDs { filter.reset() }
        self.bundleIDs = bundleIDs
        guard !bundleIDs.isEmpty else { stop(); return }
        guard AXIsProcessTrusted() else {
            stop()
            status = "启用英文标点需要在系统设置中允许 RightClick 使用辅助功能。"
            return
        }
        if isRunning { return }
        removeTap()
        let events: [CGEventType] = [.keyDown, .leftMouseDown]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                             options: .defaultTap, eventsOfInterest: mask,
                                             callback: { _, type, event, context in
            if let context = context {
                let monitor = Unmanaged<EnglishPunctuationMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handle(type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            status = "无法启用英文标点，检查辅助功能权限后重新打开设置重试。"
            return
        }
        tap = newTap
        tapSource = source
        refreshInputSource()
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.refreshInputSource() }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.filter.reset() }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        status = ""
    }

    private func refreshInputSource() {
        filter.reset()
        usesInputMethod = false
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return }
        let name = Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String
        usesInputMethod = name == kTISTypeKeyboardInputMode as String || name == kTISTypeKeyboardInputMethodWithoutModes as String
    }

    private func handle(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            filter.reset()
            if let tap = tap, !bundleIDs.isEmpty, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if type == .leftMouseDown { filter.reset(); return }
        guard type == .keyDown, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, bundleIDs.contains(bundle) else { return }
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard target == 0 || target == Int64(app.processIdentifier) else { return }
        if var replacement = filter.replacement(for: event, usesInputMethod: usesInputMethod) {
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &replacement)
        }
    }

    func stop() {
        bundleIDs.removeAll()
        removeTap()
        status = ""
    }

    private func removeTap() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            tapSource = nil
        }
        if let observer = sourceObserver { DistributedNotificationCenter.default().removeObserver(observer); sourceObserver = nil }
        if let observer = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer); appObserver = nil }
        filter.reset()
    }

    deinit { removeTap() }
}
