import Cocoa
import Carbon

final class TranslationCoordinator: NSObject {
    private var panelInstance: TranslationPanelController?
    private var pendingShortcutWarning: String?
    var hasLoadedPanel: Bool { panelInstance != nil }
    var panel: TranslationPanelController {
        if let existing = panelInstance { return existing }
        let created = TranslationPanelController()
        created.shortcutWarning = pendingShortcutWarning
        panelInstance = created
        return created
    }
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private func setShortcutWarning(_ warning: String?) {
        pendingShortcutWarning = warning
        panelInstance?.shortcutWarning = warning
    }

    func start() {
        guard hotKeyHandler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x52435452, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<TranslationCoordinator>.fromOpaque(context).takeUnretainedValue().show()
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        guard status == noErr else {
            setShortcutWarning("无法注册翻译快捷键，请从菜单栏打开翻译窗口。")
            return
        }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | shiftKey),
                                         EventHotKeyID(signature: 0x52435452, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            setShortcutWarning("⇧⌘T 已被其他应用占用，请从菜单栏打开翻译窗口。")
        } else {
            setShortcutWarning(nil)
        }
    }

    func stop() {
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let hotKeyHandler = hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
        panelInstance?.hide()
    }

    func show(text: String? = nil) { panel.show(text: text) }
}
