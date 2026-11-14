import Cocoa
import Carbon

final class ClipboardCoordinator: NSObject {
    let store = ClipboardStore()
    lazy var panel = ClipboardPanelController(store: store)
    private(set) var stack = ClipboardStack()
    private var target: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pendingPastes = [NSRunningApplication]()
    private var suppressKeyUp = false
    private var stackGeneration = 0
    private let syntheticPasteTag: Int64 = 0x5243434C4950
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var advancing = false
    private var preparedChange: Int?
    private var capturedChange: Int?
    private(set) var shortcutError: String?
    private var registeredShortcuts: [String: ClipboardShortcut]?

    func start() {
        rememberTarget()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rememberTarget() }
        panel.onPaste = { [weak self] entries, plain in self?.paste(entries, plainText: plain) }
        panel.onStartStack = { [weak self] in self?.toggleStack() }
        panel.onPasteNext = { [weak self] in self?.pasteNext() }
        let previousChange = store.onChange
        store.onChange = { [weak self] in
            previousChange?()
            guard let self = self else { return }
            if self.stack.active && (!self.store.settings.enabled || self.store.settings.paused) { self.stopStack() }
            let old = self.stack.ids
            self.stack.discardMissing(Set(self.store.entries.map(\.id)))
            if old != self.stack.ids && !self.advancing { self.prepareNext() }
            self.registerShortcuts()
        }
        store.onCapture = { [weak self] entry in
            guard let self = self, self.stack.active else { return }
            self.stack.append(entry.id)
            self.capturedChange = NSPasteboard.general.changeCount
            if !self.advancing { self.prepareNext() }
        }
        store.startMonitoring()
        registerShortcuts()
    }

    func stop() {
        panel.hide()
        store.stopMonitoring()
        stopStack()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let handler = hotKeyHandler { RemoveEventHandler(handler) }
    }

    func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { target = app }
    }

    func show() { rememberTarget(); panel.show() }
    func showSettings() { rememberTarget(); panel.showSettings() }

    func status() -> [String: Any] {
        ["enabled": store.settings.enabled, "paused": store.settings.paused,
         "count": store.entries.count, "pinboards": store.pinboards.count,
         "stackActive": stack.active, "stackCount": stack.ids.count,
         "accessibility": AXIsProcessTrusted(), "error": store.lastError ?? shortcutError ?? ""]
    }

    func togglePaused() {
        var settings = store.settings
        settings.paused.toggle()
        settings.pausedUntil = nil
        do { try store.updateSettings(settings); if settings.paused { stopStack() } }
        catch { report(error.localizedDescription) }
    }

    func toggleStack() {
        if stack.active { stopStack(); return }
        guard store.settings.enabled && !store.settings.paused else {
            report("请先在剪贴板设置中开启记录并取消暂停，再开始顺序粘贴。"); return
        }
        guard AXIsProcessTrusted() else {
            requestAccessibility("顺序粘贴需要辅助功能权限，以检测其他应用中的 ⌘V。授权后再次开始即可。"); return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let coordinator = Unmanaged<ClipboardCoordinator>.fromOpaque(context).takeUnretainedValue()
            return coordinator.intercept(type: type, event: event)
        }, userInfo: context) else {
            requestAccessibility("无法启用顺序粘贴的键盘事件监听。请检查 RightClick 的辅助功能权限后重试。"); return
        }
        do { try store.flushPendingCapture() }
        catch {
            CFMachPortInvalidate(tap)
            report("开始队列前无法保存刚复制的内容：\(error.localizedDescription)"); return
        }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        stackGeneration += 1; stack.start(); preparedChange = nil
        panel.setStackStatus(active: stack.active, count: stack.ids.count)
        panel.hide()
        if let target = target { target.activate(options: []) }
    }

    func stopStack() {
        stackGeneration += 1; advancing = false; pendingPastes = []; suppressKeyUp = false
        stack.stop(); preparedChange = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap); eventTap = nil }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); tapSource = nil }
        panel.setStackStatus(active: stack.active, count: stack.ids.count)
    }

    func reverseStack() { guard !advancing else { return }; stack.reverse(); prepareNext() }

    private func prepareNext() {
        guard stack.active else { return }
        if !store.settings.enabled || store.settings.paused { stopStack(); return }
        stack.discardMissing(Set(store.entries.map(\.id)))
        panel.setStackStatus(active: stack.active, count: stack.ids.count)
        guard let id = stack.ids.first else { preparedChange = nil; return }
        guard canWriteStack() else { return }
        do { try store.write(id: id, plainText: store.settings.pasteAsPlainText ?? false); preparedChange = NSPasteboard.general.changeCount }
        catch { stopStack(); report(error.localizedDescription) }
    }

    private func canWriteStack() -> Bool {
        let current = NSPasteboard.general.changeCount
        guard preparedChange == current || capturedChange == current else {
            stopStack(); return false
        }
        return true
    }

    private func intercept(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.stopStack() }
            return Unmanaged.passUnretained(event)
        }
        guard stack.active, event.getIntegerValueField(.eventSourceUserData) != syntheticPasteTag,
              event.getIntegerValueField(.keyboardEventKeycode) == 9 else { return Unmanaged.passUnretained(event) }
        if type == .keyUp, suppressKeyUp { suppressKeyUp = false; return nil }
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard type == .keyDown, flags == .maskCommand, !stack.ids.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              store.settings.enabled, !store.settings.paused else { return Unmanaged.passUnretained(event) }
        // Never replace a newer clipboard that the collector has not inspected yet.
        guard preparedChange == NSPasteboard.general.changeCount else {
            DispatchQueue.main.async { [weak self] in self?.stopStack() }
            return Unmanaged.passUnretained(event)
        }
        suppressKeyUp = true
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            pendingPastes.append(app)
            DispatchQueue.main.async { [weak self] in self?.processPendingPaste() }
        }
        return nil
    }

    private func processPendingPaste() {
        guard stack.active, !advancing, !pendingPastes.isEmpty else { return }
        guard !stack.ids.isEmpty else { pendingPastes = []; return }
        let app = pendingPastes.removeFirst()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            pendingPastes = []; return
        }
        target = app
        pasteNext()
    }

    private func didPasteFromStack(generation: Int, change: Int, id: String) {
        // Serializing intercepted Cmd+V requests gives the receiving app time to read each item.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            guard generation == self.stackGeneration else { return }
            self.advancing = false
            guard self.stack.active, AXIsProcessTrusted(), self.stack.ids.first == id else { self.stopStack(); return }
            self.stack.consume()
            self.panel.setStackStatus(active: self.stack.active, count: self.stack.ids.count)
            // A copy during paste belongs to the user. Let the collector capture it before preparing another item.
            if NSPasteboard.general.changeCount != change {
                self.pendingPastes = []
                if self.capturedChange == NSPasteboard.general.changeCount { self.prepareNext(); return }
                self.panel.setStackStatus(active: self.stack.active, count: self.stack.ids.count)
                return
            }
            // Keep the item just delivered on the pasteboard until another paste is requested.
            self.processPendingPaste()
        }
    }

    func pasteNext() {
        guard !advancing else { return }
        guard stack.active, let id = stack.ids.first,
              let entry = store.entries.first(where: { $0.id == id }) else {
            stopStack()
            report("顺序粘贴队列为空。先按 ⌘⇧C 开始，再复制多条内容。"); return
        }
        guard canWriteStack() else {
            report("检测到尚未记录的新剪贴板内容，已结束顺序粘贴并保留新内容。请待内容入库后重新开始。"); return
        }
        paste([entry], plainText: store.settings.pasteAsPlainText ?? false, fromStack: true)
    }

    func paste(_ entries: [ClipboardEntry], plainText: Bool, fromStack: Bool = false) {
        guard !entries.isEmpty else { return }
        do { try store.write(ids: entries.map(\.id), plainText: plainText) }
        catch { if fromStack { stopStack() }; report(error.localizedDescription); return }
        if fromStack { preparedChange = NSPasteboard.general.changeCount; advancing = true }
        else { stopStack() }
        guard AXIsProcessTrusted() else {
            advancing = false
            requestAccessibility("内容已复制。可回到目标应用按 ⌘V；若要直接粘贴，请在系统设置中授予 RightClick 辅助功能权限。"); return
        }
        guard let app = target, !app.isTerminated, app.processIdentifier != getpid() else {
            advancing = false
            report("内容已复制。请切换到目标应用后按 ⌘V。"); return
        }
        panel.hide()
        app.activate(options: [])
        deliverPaste(to: app, fromStack: fromStack, change: NSPasteboard.general.changeCount, generation: stackGeneration, id: entries[0].id, attempts: 20)
    }

    private func deliverPaste(to app: NSRunningApplication, fromStack: Bool, change: Int, generation: Int, id: String, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            if fromStack && generation != self.stackGeneration { return }
            guard AXIsProcessTrusted() else { self.advancing = false; self.pendingPastes = []; return }
            guard NSPasteboard.general.changeCount == change else {
                self.advancing = false; self.pendingPastes = []
                self.report("剪贴板内容在等待期间发生变化，本次自动粘贴已取消。"); return
            }
            guard !app.isTerminated else { self.advancing = false; self.pendingPastes = []; self.report("目标应用已退出，内容仍在剪贴板中。"); return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                if attempts > 0 { self.deliverPaste(to: app, fromStack: fromStack, change: change, generation: generation, id: id, attempts: attempts - 1) }
                else { self.advancing = false; self.pendingPastes = []; self.report("无法激活目标应用。内容已复制，请手动粘贴。") }
                return
            }
            // Wait for shortcut keys to be released so Shift/Option never leak into the paste.
            let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift, .maskAlternate, .maskControl])
            if !held.isEmpty {
                if attempts > 0 { self.deliverPaste(to: app, fromStack: fromStack, change: change, generation: generation, id: id, attempts: attempts - 1) }
                else { self.advancing = false; self.pendingPastes = []; self.report("内容已复制，请松开快捷键后手动粘贴。") }
                return
            }
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { self.advancing = false; return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.setIntegerValueField(.eventSourceUserData, value: self.syntheticPasteTag)
            up.setIntegerValueField(.eventSourceUserData, value: self.syntheticPasteTag)
            down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
            if fromStack { self.didPasteFromStack(generation: generation, change: change, id: id) }
        }
    }

    private func requestAccessibility(_ message: String) {
        let alert = NSAlert(); alert.messageText = "粘贴到其他应用"; alert.informativeText = message
        alert.addButton(withTitle: "知道了"); alert.addButton(withTitle: "打开系统设置")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func report(_ text: String) {
        let alert = NSAlert(); alert.messageText = "RightClick 剪贴板"; alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    private func registerShortcuts() {
        let shortcuts = store.settings.shortcuts ?? [
            "panel": ClipboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘V"),
            "stack": ClipboardShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘C"),
            "next": ClipboardShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘B")
        ]
        guard registeredShortcuts != shortcuts else { return }
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys = []
        if let handler = hotKeyHandler { RemoveEventHandler(handler); hotKeyHandler = nil }
        registeredShortcuts = shortcuts; shortcutError = nil
        panel.shortcutWarning = nil
        guard !shortcuts.isEmpty else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            let coordinator = Unmanaged<ClipboardCoordinator>.fromOpaque(context).takeUnretainedValue()
            switch id.id {
            case 1: coordinator.rememberTarget(); coordinator.panel.toggle()
            case 2: coordinator.rememberTarget(); coordinator.toggleStack()
            case 3: coordinator.rememberTarget(); coordinator.pasteNext()
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        guard status == noErr else {
            shortcutError = "无法注册剪贴板快捷键，请从菜单栏打开。"
            panel.shortcutWarning = shortcutError; return
        }
        for (offset, name) in ["panel", "stack", "next"].enumerated() {
            guard let shortcut = shortcuts[name] else { continue }
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x52434C50, id: UInt32(offset + 1)),
                                            GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference = reference { hotKeys.append(reference) }
            else { shortcutError = "部分剪贴板快捷键被其他应用占用，可从菜单栏使用。" }
        }
        panel.shortcutWarning = shortcutError
    }
}
