import Cocoa
import Quartz
import WebKit

private final class ClipboardSearchFieldCell: NSSearchFieldCell {
    // AppKit's borderless field editor otherwise covers the search icon as well.
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate anObject: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: isBordered ? rect : searchTextRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: anObject, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate anObject: Any?, event: NSEvent?) {
        super.edit(withFrame: isBordered ? rect : searchTextRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: anObject, event: event)
    }
}

private final class ClipboardSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { ClipboardSearchFieldCell.self }
        set { }
    }
}

private final class ClipboardQuickLookWindow: ToolPanel {
    var dismiss: (() -> Void)?
    var closeOnSpace = true
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 49 && closeOnSpace) || event.keyCode == 53 { dismiss?(); return }
        super.keyDown(with: event)
    }
}

private final class ClipboardTableView: NSTableView {
    var command: ((NSEvent) -> Bool)?
    var didPointAtRow: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if command?(event) == true { return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 { didPointAtRow?(index) }
        // Each click checks/unchecks a record, while AppKit still handles dragging.
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let checkingEvent = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: event.modifierFlags.union(.command), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                clickCount: event.clickCount, pressure: event.pressure) {
            super.mouseDown(with: checkingEvent)
        } else { super.mouseDown(with: event) }
    }
}

private final class ClipboardRowView: NSTableCellView {
    let heading = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let ordinal = NSTextField(labelWithString: "")
    let thumbnail = NSImageView()
    let cursor = NSView()
    var hasThumbnail = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 13)
        heading.maximumNumberOfLines = 3; heading.lineBreakMode = .byTruncatingTail
        for field in [detail, count, ordinal] {
            field.font = .systemFont(ofSize: 10); field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
        }
        count.alignment = .right; ordinal.alignment = .right
        ordinal.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        thumbnail.imageScaling = .scaleProportionallyDown; thumbnail.imageAlignment = .alignLeft
        cursor.wantsLayer = true; cursor.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        cursor.layer?.cornerRadius = 1.5
        for view in [heading, detail, count, ordinal, thumbnail, cursor] { addSubview(view) }
        textField = heading
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        heading.frame = NSRect(x: 16, y: 29, width: max(0, width - 58), height: max(0, height - 37))
        thumbnail.frame = NSRect(x: 16, y: 30, width: max(0, width - 58), height: max(0, height - 40))
        detail.frame = NSRect(x: 16, y: 8, width: max(0, width - 190), height: 15)
        count.frame = NSRect(x: max(16, width - 182), y: 8, width: 130, height: 15)
        ordinal.frame = NSRect(x: max(16, width - 39), y: 8, width: 25, height: 15)
        cursor.frame = NSRect(x: 3, y: 10, width: 3, height: max(0, height - 20))
        heading.isHidden = hasThumbnail; thumbnail.isHidden = !hasThumbnail
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ClipboardContainerView: NSView {
    private var sections: [NSView] = []
    override var isFlipped: Bool { true }
    func addArrangedSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        sections.append(view); addSubview(view)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let heights: [CGFloat] = [56, 1, 38, 1, max(0, bounds.height - 127), 1, 30]
        var top: CGFloat = 0
        for (index, view) in sections.enumerated() {
            let height = heights[index]
            view.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            top += height
        }
    }
}

private final class ClipboardShortcutEditor: NSObject {
    private let alert = NSAlert()
    private let keys = ["panel", "stack", "next"]
    private let names = ["打开剪贴板", "开始 / 结束队列", "粘贴下一条"]
    private var values: [String: ClipboardShortcut]
    private var displays: [NSTextField] = []
    private var recording: Int?
    private var monitor: Any?
    static var defaults: [String: ClipboardShortcut] {
        ["panel": ClipboardShortcut(keyCode: 9, modifiers: 2304, label: "⌥⌘V"),
         "stack": ClipboardShortcut(keyCode: 8, modifiers: 768, label: "⇧⌘C"),
         "next": ClipboardShortcut(keyCode: 11, modifiers: 768, label: "⇧⌘B")]
    }
    init(_ shortcuts: [String: ClipboardShortcut]?, hideInScreenCapture: Bool) {
        values = shortcuts ?? Self.defaults
        super.init()
        alert.messageText = "全局快捷键"; alert.informativeText = "点击“录制”后按下组合键，需包含 ⌘、⌃ 或 ⌥。按 Esc 取消录制。"
        alert.window.sharingType = hideInScreenCapture ? .none : .readOnly
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 170))
        for index in keys.indices {
            let y = CGFloat(130 - index * 40)
            let name = NSTextField(labelWithString: names[index]); name.frame = NSRect(x: 0, y: y, width: 130, height: 24); view.addSubview(name)
            let display = NSTextField(labelWithString: ""); display.frame = NSRect(x: 130, y: y, width: 190, height: 24); display.font = .systemFont(ofSize: 13, weight: .medium); view.addSubview(display); displays.append(display)
            let record = NSButton(title: "录制", target: self, action: #selector(beginRecord(_:))); record.bezelStyle = .rounded; record.tag = index; record.frame = NSRect(x: 320, y: y - 3, width: 72, height: 30); view.addSubview(record)
            let clear = NSButton(title: "清除", target: self, action: #selector(clear(_:))); clear.bezelStyle = .rounded; clear.tag = index; clear.frame = NSRect(x: 400, y: y - 3, width: 72, height: 30); view.addSubview(clear)
        }
        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(reset)); reset.bezelStyle = .rounded; reset.frame = NSRect(x: 0, y: 0, width: 160, height: 30); view.addSubview(reset)
        alert.accessoryView = view; updateLabels()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.alert.window, let index = self.recording else { return event }
            if event.keyCode == 53 { self.recording = nil; self.updateLabels(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                self.displays[index].stringValue = "请包含 ⌘、⌃ 或 ⌥"; return nil
            }
            let special: [UInt16: String] = [49: "空格", 48: "Tab", 36: "Return", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let character = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
            guard !character.isEmpty, !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            var modifiers: UInt32 = 0; var prefix = ""
            if flags.contains(.control) { modifiers |= 4096; prefix += "⌃" }
            if flags.contains(.option) { modifiers |= 2048; prefix += "⌥" }
            if flags.contains(.shift) { modifiers |= 512; prefix += "⇧" }
            if flags.contains(.command) { modifiers |= 256; prefix += "⌘" }
            self.values[self.keys[index]] = ClipboardShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: prefix + character)
            self.recording = nil; self.updateLabels(); return nil
        }
    }
    deinit { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }
    private func updateLabels() {
        for index in keys.indices { displays[index].stringValue = recording == index ? "请按组合键…" : values[keys[index]]?.label ?? "未设置" }
        alert.buttons.first?.isEnabled = recording == nil
    }
    @objc private func beginRecord(_ sender: NSButton) { recording = sender.tag; updateLabels() }
    @objc private func clear(_ sender: NSButton) { recording = nil; values.removeValue(forKey: keys[sender.tag]); updateLabels() }
    @objc private func reset() { recording = nil; values = Self.defaults; updateLabels() }
    func run() -> [String: ClipboardShortcut]? {
        while alert.runModal() == .alertFirstButtonReturn {
            let identities = values.values.map { "\($0.keyCode):\($0.modifiers)" }
            if Set(identities).count == identities.count { return values }
            let conflict = NSAlert(); conflict.messageText = "快捷键重复"; conflict.informativeText = "不同操作需要设置不同的快捷键。"; conflict.runModal()
        }
        return nil
    }
}

/// The panel owns presentation only. The application supplies focus restoration and global paste actions.
final class ClipboardPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation, WKNavigationDelegate {
    let store: ClipboardStore
    private let copyPasteboard: NSPasteboard
    private(set) var window: NSPanel!
    var onPaste: (([ClipboardEntry], Bool) -> Void)?
    var onStartStack: (() -> Void)?
    var onPasteNext: (() -> Void)?
    var shortcutWarning: String? { didSet { refresh() } }
    private let search = ClipboardSearchField()
    private let kind = NSPopUpButton()
    private let source = NSPopUpButton()
    private let date = NSPopUpButton()
    private let boards = NSPopUpButton()
    private let table = ClipboardTableView()
    private let status = NSTextField(labelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: "记录", target: nil, action: nil)
    private let pause = NSButton(title: "暂停", target: nil, action: nil)
    private let selectionCount = NSButton(title: "", target: nil, action: nil)
    private let emptyState = NSTextField(wrappingLabelWithString: "")
    private let filtersButton = NSButton()
    private var tabs: [NSButton] = []
    private var activeTab = 0
    private var currentRow = 0
    private var filterPopover: NSPopover?
    private var menuDepth = 0
    private var pinnedOpen = false
    private var actionButtons: [NSButton] = []
    private var rows: [ClipboardEntry] = []
    private var sourceIDs: [String?] = [nil]
    private var boardIDs: [String?] = [nil]
    private var localKeys: Any?
    private var refreshing = false
    private var statusNote: String?
    private var stackStatus: String?
    private var quickLookWindow: ClipboardQuickLookWindow?
    private var quickLookView: QLPreviewView?
    private var previewDirectory: URL?
    private var previewURLs: [URL] = []
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN"); return formatter
    }()

    init(store: ClipboardStore, copyPasteboard: NSPasteboard = .general) {
        self.store = store
        self.copyPasteboard = copyPasteboard
        super.init()
        buildWindow()
        let previous = store.onChange
        store.onChange = { [weak self] in previous?(); self?.refresh() }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window, self.window.attachedSheet == nil else { return event }
            return self.handleKey(event) ? nil : event
        }
        refresh()
    }
    deinit {
        if let monitor = localKeys { NSEvent.removeMonitor(monitor) }
        quickLookView?.close()
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    func show() {
        refresh(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
    }
    func toggle() { window.isVisible && window.isKeyWindow ? hide() : show() }
    func hide() { filterPopover?.close(); closePreview(); window.orderOut(nil) }
    func setStackStatus(active: Bool, count: Int) {
        stackStatus = active ? "队列已开启 · 剩余 \(count) 条" : nil
        statusNote = nil; refresh()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === quickLookWindow { closePreview() } else { hide() }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.pinnedOpen, !self.window.isKeyWindow,
                  self.window.attachedSheet == nil, NSApp.modalWindow == nil,
                  self.quickLookWindow == nil, self.filterPopover?.isShown != true,
                  self.menuDepth == 0 else { return }
            self.hide()
        }
    }
    func menuWillOpen(_ menu: NSMenu) { menuDepth += 1 }
    func menuDidClose(_ menu: NSMenu) { menuDepth = max(0, menuDepth - 1) }

    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
        let value = NSTextField(labelWithString: text); value.font = .systemFont(ofSize: size)
        if secondary { value.textColor = .secondaryLabelColor }
        return value
    }
    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded
        if let symbol = symbol { value.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); value.imagePosition = .imageLeading }
        return value
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY
        return stack
    }
    private func iconButton(_ symbol: String, title: String, action: Selector) -> NSButton {
        let value = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        value.bezelStyle = .regularSquare; value.isBordered = false
        value.imageScaling = .scaleProportionallyDown; value.contentTintColor = .secondaryLabelColor
        value.toolTip = title; value.setAccessibilityLabel(title)
        value.widthAnchor.constraint(equalToConstant: 38).isActive = true
        value.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return value
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func buildWindow() {
        window = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "趁手 · 剪贴板"; window.minSize = NSSize(width: 680, height: 440)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        window.isReleasedWhenClosed = false; window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center(); window.setFrameAutosaveName("RightClickClipboardCompact")
        let root = ClipboardContainerView()
        root.frame = window.contentView!.bounds
        root.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(root)
        let title = label("剪贴板", size: 14); title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.setContentHuggingPriority(.required, for: .horizontal)
        let appIcon = NSImageView(image: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)!)
        appIcon.contentTintColor = .controlAccentColor; appIcon.widthAnchor.constraint(equalToConstant: 21).isActive = true
        search.placeholderString = "搜索内容、标签或图片文字…"; search.delegate = self; search.sendsSearchStringImmediately = true
        search.controlSize = .large; search.isBordered = false; search.focusRingType = .none
        search.setAccessibilityLabel("搜索剪贴板历史")
        let create = iconButton("square.and.pencil", title: "新建文本（⌘N）", action: #selector(newText))
        let dismiss = iconButton("xmark", title: "关闭（Esc）", action: #selector(dismissPanel))
        let header = row([appIcon, title, search, create, dismiss], spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 9)
        header.heightAnchor.constraint(equalToConstant: 56).isActive = true
        root.addArrangedSubview(header); root.addArrangedSubview(separator())
        for (index, name) in ["全部", "文本", "图像", "文件", "收藏"].enumerated() {
            let tab = NSButton(title: name, target: self, action: #selector(selectTab(_:)))
            tab.tag = index; tab.isBordered = false; tab.setButtonType(.toggle)
            tab.font = .systemFont(ofSize: 12); tab.setAccessibilityLabel(name)
            tab.heightAnchor.constraint(equalToConstant: 30).isActive = true
            tab.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            tabs.append(tab)
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectionCount.target = self; selectionCount.action = #selector(clearSelection)
        selectionCount.isBordered = false; selectionCount.font = .systemFont(ofSize: 11)
        selectionCount.contentTintColor = .controlAccentColor; selectionCount.toolTip = "点击取消全部勾选"
        filtersButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        filtersButton.imagePosition = .imageLeading; filtersButton.title = "筛选"; filtersButton.isBordered = false
        filtersButton.font = .systemFont(ofSize: 11); filtersButton.target = self; filtersButton.action = #selector(showFilters)
        filtersButton.toolTip = "按固定板、类型、来源应用和时间筛选"; filtersButton.setAccessibilityLabel("更多筛选")
        let tabBar = row(tabs + [spacer, selectionCount, filtersButton], spacing: 6)
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 15)
        tabBar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        root.addArrangedSubview(tabBar); root.addArrangedSubview(separator())
        boards.target = self; boards.action = #selector(filterChanged); boards.setAccessibilityLabel("固定板")
        kind.addItems(withTitles: ["全部类型", "文字", "链接", "图片", "文件", "颜色"])
        source.addItem(withTitle: "全部来源")
        date.addItems(withTitles: ["不限时间", "今天", "最近 7 天", "最近 30 天"])
        kind.setAccessibilityLabel("内容类型"); source.setAccessibilityLabel("来源应用"); date.setAccessibilityLabel("复制时间")
        for popup in [kind, source, date] { popup.target = self; popup.action = #selector(filterChanged) }
        table.headerView = nil; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true; table.style = .fullWidth
        table.dataSource = self; table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self; table.doubleAction = #selector(pasteClicked)
        table.command = { [weak self] in self?.handleKey($0) ?? false }
        table.didPointAtRow = { [weak self] row in self?.moveCursor(to: row) }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL])
        table.setAccessibilityLabel("剪贴板记录：单击勾选，双击粘贴")
        table.menu = makeActionsMenu()
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let list = NSView(); scroll.translatesAutoresizingMaskIntoConstraints = false; list.addSubview(scroll)
        emptyState.font = .systemFont(ofSize: 13); emptyState.textColor = .secondaryLabelColor; emptyState.alignment = .center
        emptyState.translatesAutoresizingMaskIntoConstraints = false; list.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: list.topAnchor), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: list.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor, constant: -60)
        ])
        let rail = NSStackView(); rail.orientation = .vertical; rail.spacing = 4; rail.alignment = .centerX
        rail.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let copy = iconButton("doc.on.doc", title: "复制所选内容（⌘C）", action: #selector(copySelected))
        let paste = iconButton("arrow.turn.down.left", title: "执行粘贴（↩，⇧↩ 纯文本）", action: #selector(pasteSelected))
        paste.contentTintColor = .controlAccentColor
        let preview = iconButton("eye", title: "快速预览（空格）", action: #selector(showPreview))
        let favorite = iconButton("star", title: "收藏到固定板", action: #selector(pinSelected))
        actionButtons = [copy, paste, preview, favorite]
        for item in actionButtons { rail.addArrangedSubview(item) }
        rail.addArrangedSubview(iconButton("ellipsis", title: "更多操作：编辑、纯文本、顺序粘贴", action: #selector(showMore(_:))))
        let railSpace = NSView(); rail.addArrangedSubview(railSpace)
        railSpace.setContentHuggingPriority(.defaultLow, for: .vertical)
        rail.addArrangedSubview(iconButton("pin", title: "保持窗口打开", action: #selector(togglePinnedOpen(_:))))
        rail.addArrangedSubview(iconButton("gearshape", title: "设置、隐私与快捷键", action: #selector(openSettings)))
        rail.addArrangedSubview(iconButton("trash", title: "清空未收藏的历史", action: #selector(clearHistory)))
        rail.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let divider = separator(); divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let body = row([list, divider, rail], spacing: 0); body.alignment = .top
        body.setHuggingPriority(.init(1), for: .vertical)
        rail.setHuggingPriority(.init(1), for: .vertical)
        for view in [list, divider, rail] { view.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        root.addArrangedSubview(body); root.addArrangedSubview(separator())
        enabled.target = self; enabled.action = #selector(toggleEnabled); enabled.controlSize = .small; enabled.font = .systemFont(ofSize: 11)
        enabled.toolTip = "开启或关闭本机剪贴板记录"
        pause.target = self; pause.action = #selector(togglePause); pause.isBordered = false; pause.font = .systemFont(ofSize: 11)
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = row([enabled, pause, status], spacing: 10)
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 15)
        footer.heightAnchor.constraint(equalToConstant: 30).isActive = true
        root.addArrangedSubview(footer)
    }
    private func makeActionsMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        let actions: [(String, Selector)] = [
            ("执行粘贴", #selector(pasteSelected)), ("复制", #selector(copySelected)), ("复制为纯文本", #selector(copyPlain)),
            ("快速预览", #selector(showPreview)), ("预览链接（联网）", #selector(showLinkPreview)),
            ("收藏到固定板…", #selector(pinSelected)), ("编辑文字或标签…", #selector(editSelected)), ("图片向右旋转", #selector(rotateSelected)),
            ("在固定板中上移", #selector(movePinnedUp)), ("在固定板中下移", #selector(movePinnedDown)),
            ("在历史中定位", #selector(jumpToHistory)), ("删除所选记录…", #selector(deleteSelected))]
        for (title, action) in actions { let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self }
        menu.addItem(.separator())
        for (title, action) in [("开始 / 结束顺序粘贴队列", #selector(startStack)), ("粘贴队列下一条", #selector(pasteNext)), ("新建固定板…", #selector(addBoard)), ("管理当前固定板…", #selector(manageBoard))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        return menu
    }
    @objc private func dismissPanel() { hide() }
    @objc private func selectTab(_ sender: NSButton) {
        activeTab = sender.tag; kind.selectItem(at: 0); boards.selectItem(at: 0)
        currentRow = 0; table.deselectAll(nil); statusNote = nil; refresh()
    }
    @objc private func clearSelection() { table.deselectAll(nil); updatePreview() }
    @objc private func showMore(_ sender: NSButton) { makeActionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender) }
    @objc private func togglePinnedOpen(_ sender: NSButton) {
        pinnedOpen.toggle(); sender.contentTintColor = pinnedOpen ? .controlAccentColor : .secondaryLabelColor
        sender.toolTip = pinnedOpen ? "取消保持窗口打开" : "保持窗口打开"
        sender.setAccessibilityLabel(sender.toolTip)
    }
    @objc private func showFilters() {
        if filterPopover?.isShown == true { filterPopover?.close(); return }
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for (title, control) in [("固定板", boards), ("内容类型", kind), ("来源应用", source), ("复制时间", date)] {
            let name = label(title, size: 11, secondary: true); content.addArrangedSubview(name); content.addArrangedSubview(control)
            control.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        content.addArrangedSubview(row([button("新建固定板", #selector(addBoard)), button("管理", #selector(manageBoard)), button("重置", #selector(resetFilters))]))
        let controller = NSViewController(); controller.view = content
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        popover.contentSize = NSSize(width: 292, height: 302); filterPopover = popover
        popover.show(relativeTo: filtersButton.bounds, of: filtersButton, preferredEdge: .minY)
    }
    @objc private func resetFilters() {
        activeTab = 0; kind.selectItem(at: 0); source.selectItem(at: 0); date.selectItem(at: 0); boards.selectItem(at: 0)
        statusNote = nil; refresh()
    }

    func refresh() {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let selectedIDs = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        let currentID = rows.indices.contains(currentRow) ? rows[currentRow].id : nil
        let selectedBoard = selectedBoardID
        let selectedSource = selectedSourceID
        boards.removeAllItems(); boards.addItem(withTitle: "剪贴板历史")
        boardIDs = [nil]
        for board in store.pinboards {
            boards.addItem(withTitle: board.name); boardIDs.append(board.id)
            if let color = board.color { boards.lastItem?.image = colorDot(color) }
        }
        boards.selectItem(at: boardIDs.firstIndex(where: { $0 == selectedBoard }) ?? 0)
        source.removeAllItems(); source.addItem(withTitle: "全部来源"); sourceIDs = [nil]
        var seen = Set<String>()
        for entry in store.entries where !entry.sourceBundleID.isEmpty {
            if seen.insert(entry.sourceBundleID).inserted { source.addItem(withTitle: entry.sourceApp.isEmpty ? entry.sourceBundleID : entry.sourceApp); sourceIDs.append(entry.sourceBundleID) }
        }
        source.selectItem(at: sourceIDs.firstIndex(where: { $0 == selectedSource }) ?? 0)
        rows = store.query(text: search.stringValue, kind: selectedKind, sourceBundleID: selectedSourceID, since: selectedSince, pinboardID: selectedBoardID)
        if activeTab == 1 { rows = rows.filter { ["text", "link", "color"].contains($0.kind) } }
        else if activeTab == 2 { rows = rows.filter { $0.kind == "image" } }
        else if activeTab == 3 { rows = rows.filter { $0.kind == "files" } }
        else if activeTab == 4 { rows = rows.filter { !$0.pinboardIDs.isEmpty } }
        currentRow = currentID.flatMap { id in rows.firstIndex { $0.id == id } } ?? min(currentRow, max(0, rows.count - 1))
        table.reloadData()
        let indices = IndexSet(rows.enumerated().compactMap { selectedIDs.contains($0.element.id) ? $0.offset : nil })
        table.selectRowIndexes(indices, byExtendingSelection: false)
        enabled.state = store.settings.enabled ? .on : .off
        pause.title = store.settings.paused ? "继续" : "暂停"; pause.isEnabled = store.settings.enabled
        window.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        let shortcut = (store.settings.shortcuts ?? ClipboardShortcutEditor.defaults)["panel"]?.label ?? "未设置快捷键"
        let state = !store.settings.enabled ? "未开启记录" : store.settings.paused ? "已暂停" : "正在记录"
        status.stringValue = store.lastError ?? shortcutWarning ?? statusNote ?? stackStatus ?? "\(state) · \(rows.count) 条    ←→ 分类 · ↑↓ 选择 · ↩ 粘贴 · \(shortcut) 唤出"
        status.toolTip = status.stringValue + "；⌘C 复制当前条目，选中搜索文字时复制文字；搜索框为空或列表获得焦点时，←→ 切换分类；⌘1–9 快速粘贴；⇧↩ 纯文本；单击勾选，双击粘贴"
        let favorites = store.entries.filter { !$0.pinboardIDs.isEmpty }.count
        for (index, tab) in tabs.enumerated() {
            tab.state = activeTab == index ? .on : .off
            tab.contentTintColor = activeTab == index ? .controlAccentColor : .secondaryLabelColor
            tab.font = .systemFont(ofSize: 12, weight: activeTab == index ? .semibold : .regular)
        }
        tabs[4].title = favorites == 0 ? "收藏" : "收藏 (\(favorites))"
        let filtersActive = selectedBoardID != nil || selectedKind != nil || selectedSourceID != nil || selectedSince != nil
        filtersButton.title = filtersActive ? "已筛选" : "筛选"
        filtersButton.contentTintColor = filtersActive ? .controlAccentColor : .secondaryLabelColor
        emptyState.isHidden = !rows.isEmpty
        emptyState.stringValue = store.entries.isEmpty ? (store.settings.enabled ? "还没有记录\n复制文字、图片或文件后，就能在这里找到。\n也可以拖入内容，或用 ⌘N 新建文本。" : "开启左下角的“记录”，开始保存剪贴板。\n也可以拖入内容，或用 ⌘N 新建文本。") : "没有找到匹配内容\n试试其他关键词，或重置筛选。"
        updatePreview()
    }
    private var selectedBoardID: String? { boardIDs.indices.contains(boards.indexOfSelectedItem) ? boardIDs[boards.indexOfSelectedItem] : nil }
    private var selectedSourceID: String? { sourceIDs.indices.contains(source.indexOfSelectedItem) ? sourceIDs[source.indexOfSelectedItem] : nil }
    private var selectedKind: String? { [nil, "text", "link", "image", "files", "color"][max(0, min(kind.indexOfSelectedItem, 5))] }
    private var selectedSince: Date? {
        switch date.indexOfSelectedItem {
        case 1: return Calendar.current.startOfDay(for: Date())
        case 2: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case 3: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        default: return nil
        }
    }
    private var selected: [ClipboardEntry] {
        let checked = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        return checked.isEmpty && rows.indices.contains(currentRow) ? [rows[currentRow]] : checked
    }
    private func typeName(_ kind: String) -> String { ["text": "文字", "link": "链接", "image": "图片", "files": "文件", "color": "颜色"][kind] ?? "内容" }
    private func symbolName(_ kind: String) -> String { ["text": "text.alignleft", "link": "link", "image": "photo", "files": "doc.on.doc", "color": "paintpalette"][kind] ?? "doc" }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 62 }
        let entry = rows[row]
        if entry.kind == "image" { return 174 }
        if entry.kind == "files" { return 86 }
        return entry.text.contains("\n") || entry.text.count > 85 ? 86 : 62
    }
    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 86400 * 7 { return "\(seconds / 86400) 天前" }
        return dateFormatter.string(from: date)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("clipboard-row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ClipboardRowView ?? ClipboardRowView()
        cell.identifier = id; let entry = rows[row]
        var text = entry.text.isEmpty ? entry.title : entry.text
        if entry.kind == "files" { text = store.fileURLs(id: entry.id).map { $0.lastPathComponent }.joined(separator: "\n") }
        cell.heading.stringValue = text.isEmpty ? typeName(entry.kind) : text
        cell.thumbnail.image = entry.kind == "image" ? store.image(id: entry.id) : nil
        cell.hasThumbnail = cell.thumbnail.image != nil
        cell.detail.stringValue = (entry.pinboardIDs.isEmpty ? "" : "★  ") + relativeTime(entry.updatedAt) + (entry.sourceApp.isEmpty ? "" : " · " + entry.sourceApp)
        if entry.kind == "image", let image = cell.thumbnail.image {
            cell.count.stringValue = "\(Int(image.size.width)) × \(Int(image.size.height))"
        } else if entry.kind == "files" { cell.count.stringValue = "\(store.fileURLs(id: entry.id).count) 个文件" }
        else { cell.count.stringValue = "\(entry.text.count) 字符" }
        cell.ordinal.stringValue = table.selectedRowIndexes.contains(row) ? "✓" : "\(row + 1)"
        cell.cursor.isHidden = row != currentRow
        cell.toolTip = entry.title + "\n" + typeName(entry.kind) + " · " + dateFormatter.string(from: entry.updatedAt)
        cell.setAccessibilityLabel((table.selectedRowIndexes.contains(row) ? "已勾选，" : "") + "第 \(row + 1) 条，" + String(text.prefix(160)))
        cell.needsLayout = true
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !refreshing { updatePreview() } }
    func controlTextDidChange(_ obj: Notification) { currentRow = 0; table.deselectAll(nil); statusNote = nil; refresh() }
    @objc private func filterChanged() { currentRow = 0; table.deselectAll(nil); statusNote = nil; refresh() }
    private func updatePreview() {
        let count = table.selectedRowIndexes.count
        selectionCount.title = "\(count) 项 · 取消勾选"
        selectionCount.isHidden = count == 0
        selectionCount.setAccessibilityLabel("已勾选 \(count) 条，点击取消全部勾选")
        for button in actionButtons { button.isEnabled = !selected.isEmpty }
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipboardRowView else { continue }
            cell.cursor.isHidden = row != currentRow
            cell.ordinal.stringValue = table.selectedRowIndexes.contains(row) ? "✓" : "\(row + 1)"
        }
    }
    private func moveCursor(to index: Int) {
        guard rows.indices.contains(index) else { return }
        currentRow = index; table.scrollRowToVisible(index); updatePreview()
    }
    @objc private func pasteClicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        currentRow = table.clickedRow; table.deselectAll(nil); pasteSelected()
    }
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        let ids = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
        guard !ids.isEmpty else { return false }
        do { try store.write(ids: ids, to: pasteboard); return true }
        catch { note("无法拖出：\(error.localizedDescription)"); return false }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === table.menu, table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(rotateSelected) { return selected.count == 1 && selected.first?.kind == "image" }
        if menuItem.action == #selector(manageBoard) { return selectedBoardID != nil }
        if menuItem.action == #selector(movePinnedUp) || menuItem.action == #selector(movePinnedDown) { return selectedBoardID != nil && search.stringValue.isEmpty && !selected.isEmpty }
        if menuItem.action == #selector(showLinkPreview) { return selected.count == 1 && selectedLinkURL != nil }
        let selectionActions = [#selector(pasteSelected), #selector(copySelected), #selector(copyPlain), #selector(showPreview), #selector(pinSelected), #selector(editSelected), #selector(jumpToHistory), #selector(deleteSelected), #selector(togglePin(_:))]
        if let action = menuItem.action, selectionActions.contains(action) { return !selected.isEmpty }
        return true
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if let origin = info.draggingSource as? NSTableView, origin === table { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        do {
            let pinboardID = selectedBoardID
            guard let entry = try store.importContent(from: info.draggingPasteboard) else {
                note("没有可导入的内容，或内容命中了隐私忽略规则。"); return false
            }
            if let id = pinboardID { try store.setPinned(id: entry.id, pinboardID: id, pinned: true) }
            refresh(); note("已保存拖入的内容。"); return true
        } catch { presentError(error.localizedDescription); return false }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        // The local monitor runs before the input method. Candidate confirmation,
        // navigation and cancellation must reach the field editor unchanged.
        if let inputClient = window.firstResponder as? NSTextInputClient, inputClient.hasMarkedText() {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 123 || event.keyCode == 124),
           modifiers.intersection([.command, .option, .control, .shift]).isEmpty {
            // Keep horizontal arrows available for editing an existing query.
            if let editor = window.firstResponder as? NSTextView,
               editor !== search.currentEditor() || !editor.string.isEmpty { return false }
            let offset = event.keyCode == 124 ? 1 : -1
            selectTab(tabs[(activeTab + offset + tabs.count) % tabs.count])
            return true
        }
        if modifiers.contains(.command), let value = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(value), rows.indices.contains(value - 1) {
            table.deselectAll(nil); moveCursor(to: value - 1)
            paste(plain: modifiers.contains(.shift) || store.settings.pasteAsPlainText == true); return true
        }
        if event.keyCode == 53 { hide(); return true }
        if event.keyCode == 49, modifiers.isEmpty, window.firstResponder === table { showPreview(); return true }
        if event.keyCode == 36 && !modifiers.contains(.command) { paste(plain: modifiers.contains(.shift) || store.settings.pasteAsPlainText == true); return true }
        if (event.keyCode == 125 || event.keyCode == 126), !modifiers.contains(.command), !rows.isEmpty {
            // Arrow navigation targets a history item while keeping the query
            // editable. An earlier text selection must not capture its copy.
            if let editor = search.currentEditor() as? NSTextView, window.firstResponder === editor {
                editor.setSelectedRange(NSRange(location: NSMaxRange(editor.selectedRange()), length: 0))
            }
            moveCursor(to: min(max(currentRow + (event.keyCode == 125 ? 1 : -1), 0), rows.count - 1))
            return true
        }
        let shortcutModifiers = modifiers.intersection([.command, .shift, .option, .control])
        if (shortcutModifiers == .command || shortcutModifiers == [.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            // Preserve native copying of selected search text and other editors.
            if let editor = window.firstResponder as? NSTextView,
               editor !== search.currentEditor() || editor.selectedRange().length > 0 { return false }
            copy(plain: shortcutModifiers.contains(.shift)); return true
        }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "f" { window.makeFirstResponder(search); return true }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "n" { newText(); return true }
        let characters = event.characters.flatMap { $0.isEmpty ? nil : $0 } ?? event.charactersIgnoringModifiers ?? ""
        if window.firstResponder === table, modifiers.intersection([.command, .control]).isEmpty,
           !characters.isEmpty, characters.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
           }), window.makeFirstResponder(search), let editor = search.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            // Send the original first keystroke through AppKit's text input path
            // so input methods and dead keys work, then consume it exactly once.
            editor.keyDown(with: event)
            return true
        }
        return false
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); refresh() }
        catch { presentError(error.localizedDescription) }
    }
    private func presentError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    private func note(_ message: String) { statusNote = message; status.stringValue = message }
    @objc private func copySelected() { copy(plain: false) }
    @objc private func copyPlain() { copy(plain: true) }
    private func copy(plain: Bool) {
        guard !selected.isEmpty else { NSSound.beep(); return }
        do {
            try store.write(ids: selected.map { $0.id }, to: copyPasteboard, plainText: plain)
            if pinnedOpen {
                note(plain ? "已复制为纯文本，可在目标应用按 ⌘V" : "已复制，可在目标应用按 ⌘V")
            } else {
                hide()
            }
        } catch { presentError(error.localizedDescription) }
    }
    @objc private func pasteSelected() { paste(plain: store.settings.pasteAsPlainText == true) }
    private func paste(plain: Bool) {
        guard !selected.isEmpty else { NSSound.beep(); return }
        if let callback = onPaste { callback(selected, plain) } else { copy(plain: plain) }
    }
    @objc private func startStack() { onStartStack?() }
    @objc private func pasteNext() { onPasteNext?() }
    @objc private func toggleEnabled() {
        var settings = store.settings; settings.enabled = enabled.state == .on
        perform { try store.updateSettings(settings) }
    }
    @objc private func togglePause() {
        if store.settings.paused {
            var settings = store.settings; settings.paused = false; settings.pausedUntil = nil
            perform { try store.updateSettings(settings) }; return
        }
        let menu = NSMenu(); menu.delegate = self
        for (title, minutes) in [("暂停 5 分钟", 5), ("暂停 15 分钟", 15), ("暂停 1 小时", 60), ("暂停至手动恢复", 0)] {
            let item = menu.addItem(withTitle: title, action: #selector(pauseFor(_:)), keyEquivalent: ""); item.target = self; item.tag = minutes
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pause.bounds.minY), in: pause)
    }
    @objc private func pauseFor(_ sender: NSMenuItem) {
        var settings = store.settings; settings.paused = true
        settings.pausedUntil = sender.tag > 0 ? Date().addingTimeInterval(TimeInterval(sender.tag * 60)) : nil
        perform { try store.updateSettings(settings) }
    }
    @objc private func rotateSelected() {
        guard selected.count == 1, let entry = selected.first, entry.kind == "image" else { return }
        perform { try store.rotateImage(id: entry.id) }
    }
    private var selectedLinkURL: URL? {
        guard let entry = selected.first, let url = URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)), Self.permitsLinkPreview(url) else { return nil }
        return url
    }
    static func permitsLinkPreview(_ url: URL?) -> Bool {
        guard let url = url, let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }
    @objc private func showLinkPreview() {
        guard selected.count == 1, let url = selectedLinkURL else { return }
        closePreview()
        let panel = ClipboardQuickLookWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "链接预览 · " + (url.host ?? "")
        panel.closeOnSpace = false
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        panel.dismiss = { [weak self] in self?.closePreview() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        panel.contentView = web
        quickLookWindow = panel
        panel.center(); panel.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.permitsLinkPreview(navigationAction.request.url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        let alert = NSAlert(); alert.messageText = "链接预览加载失败"; alert.informativeText = error.localizedDescription
        alert.window.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        if let panel = quickLookWindow { alert.beginSheetModal(for: panel) }
    }
    @objc private func showPreview() {
        guard let entry = selected.first else { return }
        closePreview()
        do {
            if entry.kind == "files" {
                previewURLs = store.fileURLs(id: entry.id).filter { FileManager.default.fileExists(atPath: $0.path) }
                if previewURLs.isEmpty { throw NSError(domain: "RightClick.Clipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "原文件已移动或不可用，无法快速预览。"]) }
            } else {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-preview-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                previewDirectory = directory
                let data: Data; let suffix: String
                if entry.kind == "image" {
                    let payload = try store.loadPayload(id: entry.id).flatMap { $0 }
                    if let png = payload.first(where: { $0.type == NSPasteboard.PasteboardType.png.rawValue }) { data = png.data; suffix = "png" }
                    else if let tiff = payload.first(where: { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }) { data = tiff.data; suffix = "tiff" }
                    else { throw NSError(domain: "RightClick.Clipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片数据不可用，无法快速预览。"]) }
                } else {
                    data = Data(entry.text.utf8); suffix = "txt"
                }
                let url = directory.appendingPathComponent("preview." + suffix)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                previewURLs = [url]
            }
            let panel = ClipboardQuickLookWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = entry.title.isEmpty ? "快速预览" : entry.title
            panel.isReleasedWhenClosed = false; panel.delegate = self; panel.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
            panel.dismiss = { [weak self] in self?.closePreview() }
            let root = NSStackView(); root.orientation = .vertical; root.spacing = 0; root.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView!.addSubview(root)
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor), root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)])
            if previewURLs.count > 1 {
                let selector = NSPopUpButton(); selector.addItems(withTitles: previewURLs.map { $0.lastPathComponent }); selector.target = self; selector.action = #selector(selectPreviewFile(_:))
                selector.setAccessibilityLabel("选择预览文件"); root.addArrangedSubview(selector)
            }
            let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 550), style: .normal)!
            preview.shouldCloseWithWindow = false; preview.previewItem = previewURLs[0] as NSURL
            root.addArrangedSubview(preview); preview.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            quickLookWindow = panel; quickLookView = preview
            panel.center(); panel.makeKeyAndOrderFront(nil)
        } catch { closePreview(); presentError(error.localizedDescription) }
    }
    @objc private func selectPreviewFile(_ sender: NSPopUpButton) {
        guard previewURLs.indices.contains(sender.indexOfSelectedItem) else { return }
        quickLookView?.previewItem = previewURLs[sender.indexOfSelectedItem] as NSURL
    }
    private func closePreview() {
        quickLookView?.close(); quickLookView = nil
        let panel = quickLookWindow; quickLookWindow = nil; panel?.close()
        previewURLs = []
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
        previewDirectory = nil
    }
    private func prompt(_ title: String, value: String = "", detail: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.window.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 380, height: 25); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    @objc private func addBoard() {
        guard let name = prompt("新建固定板", detail: "把常用片段放在一起；固定的记录不会自动过期。") else { return }
        perform {
            let board = try store.addPinboard(name: name); refresh()
            boards.selectItem(at: boardIDs.firstIndex(where: { $0 == board.id }) ?? 0)
        }
    }
    @objc private func manageBoard() {
        guard let id = selectedBoardID, let board = store.pinboards.first(where: { $0.id == id }) else { note("先选择一个固定板，再进行重命名或删除。"); return }
        let menu = NSMenu(title: board.name); menu.delegate = self
        let rename = menu.addItem(withTitle: "重命名…", action: #selector(renameBoard(_:)), keyEquivalent: ""); rename.target = self; rename.representedObject = id
        let color = menu.addItem(withTitle: "固定板颜色", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for (name, hex) in [("蓝色", "5B8DEF"), ("紫色", "8B5CF6"), ("绿色", "34A853"), ("橙色", "F59E0B"), ("红色", "EF4444"), ("粉色", "EC4899"), ("灰色", "8E8E93")] {
            let item = colors.addItem(withTitle: name, action: #selector(changeBoardColor(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ["id": id, "color": hex]; item.image = colorDot(hex); item.state = board.color == hex ? .on : .off
        }
        color.submenu = colors
        for (name, offset) in [("向前移动固定板", -1), ("向后移动固定板", 1)] {
            let item = menu.addItem(withTitle: name, action: #selector(moveBoard(_:)), keyEquivalent: ""); item.target = self; item.representedObject = id; item.tag = offset
        }
        menu.addItem(.separator())
        let remove = menu.addItem(withTitle: "删除固定板…", action: #selector(deleteBoard(_:)), keyEquivalent: ""); remove.target = self; remove.representedObject = id
        menu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView)
    }
    private func colorDot(_ hex: String) -> NSImage? {
        guard let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        let image = NSImage(size: NSSize(width: 12, height: 12)); image.lockFocus()
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill(); image.unlockFocus(); return image
    }
    @objc private func renameBoard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let board = store.pinboards.first(where: { $0.id == id }), let name = prompt("重命名固定板", value: board.name) else { return }
        perform { try store.renamePinboard(id: id, name: name) }
    }
    @objc private func changeBoardColor(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String], let id = value["id"], let color = value["color"] else { return }
        perform { try store.setPinboardColor(id: id, color: color) }
    }
    @objc private func moveBoard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform { try store.movePinboard(id: id, offset: sender.tag) }
    }
    @objc private func deleteBoard(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let board = store.pinboards.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "删除固定板“\(board.name)”？"
        alert.window.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        alert.informativeText = "内容仍保留在历史中，之后按历史保留期限清理。"
        alert.addButton(withTitle: "删除固定板"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { perform { try store.removePinboard(id: id) } }
    }
    @objc private func movePinnedUp() { movePinned(offset: -1) }
    @objc private func movePinnedDown() { movePinned(offset: 1) }
    private func movePinned(offset: Int) {
        guard let id = selectedBoardID, search.stringValue.isEmpty else { return }
        let entries = offset < 0 ? selected : selected.reversed()
        perform { for entry in entries { try store.movePinnedItem(id: entry.id, pinboardID: id, offset: offset) } }
    }
    @objc private func pinSelected() {
        guard !selected.isEmpty else { return }
        if store.pinboards.isEmpty {
            let ids = selected.map { $0.id }
            guard let name = prompt("新建固定板并保存所选记录") else { return }
            perform { let board = try store.addPinboard(name: name); for id in ids { try store.setPinned(id: id, pinboardID: board.id, pinned: true) } }
            return
        }
        let menu = NSMenu(); menu.delegate = self
        for board in store.pinboards {
            let item = menu.addItem(withTitle: board.name, action: #selector(togglePin(_:)), keyEquivalent: ""); item.target = self; item.representedObject = board.id
            item.state = selected.allSatisfy { $0.pinboardIDs.contains(board.id) } ? .on : .off
        }
        menu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView)
    }
    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let entries = selected; let pinned = sender.state != .on
        perform { for entry in entries { try store.setPinned(id: entry.id, pinboardID: id, pinned: pinned) } }
    }
    @objc private func deleteSelected() {
        let ids = selected.map { $0.id }; guard !ids.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "删除 \(ids.count) 条记录？"; alert.informativeText = "同时从历史和固定板中删除，无法撤销。原文件不受影响。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { perform { try store.remove(ids: ids) } }
    }
    @objc private func clearHistory() {
        let alert = NSAlert(); alert.messageText = "清空未固定的历史？"; alert.informativeText = "固定板中的内容将保留，清除的历史无法恢复。"
        alert.addButton(withTitle: "清空历史"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { perform { try store.clear(includePinned: false) } }
    }
    @objc private func jumpToHistory() {
        guard let id = selected.first?.id else { return }
        activeTab = 0; search.stringValue = ""; kind.selectItem(at: 0); source.selectItem(at: 0); date.selectItem(at: 0); boards.selectItem(at: 0)
        refresh()
        if let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index) }
    }
    @objc private func newText() { editText(nil) }
    @objc private func editSelected() { guard selected.count == 1 else { note("请只选择一条记录进行编辑。"); return }; editText(selected[0]) }
    private func editText(_ entry: ClipboardEntry?) {
        let editableText = entry == nil || ["text", "link", "color"].contains(entry!.kind)
        if !editableText {
            guard let entry = entry, let name = prompt("编辑记录标签", value: entry.title) else { return }
            perform { try store.rename(id: entry.id, title: name) }; return
        }
        let alert = NSAlert(); alert.messageText = entry == nil ? "新建文字片段" : "编辑文字片段"
        alert.window.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        alert.informativeText = "支持字体与文字样式；可用右键菜单的系统文字工具。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let title = NSTextField(string: entry?.title ?? ""); title.placeholderString = "标签（可选）"; title.frame = NSRect(x: 0, y: 270, width: 520, height: 25)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 245)); text.isRichText = true; text.usesFontPanel = true; text.allowsUndo = true; text.font = .systemFont(ofSize: 14)
        if let entry = entry {
            do { text.textStorage?.setAttributedString(try store.attributedText(id: entry.id)) }
            catch { presentError(error.localizedDescription); return }
        }
        text.textContainerInset = NSSize(width: 8, height: 8); text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 255)); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        accessory.addSubview(title); accessory.addSubview(scroll); alert.accessoryView = accessory; alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            _ = try store.editRichText(id: entry?.id, attributedText: text.attributedString(), title: title.stringValue, pinboardID: selectedBoardID)
        }
    }
    @objc private func openSettings() { showSettings() }
    @objc private func editShortcuts() {
        let editor = ClipboardShortcutEditor(store.settings.shortcuts, hideInScreenCapture: store.settings.hideInScreenCapture)
        guard let shortcuts = editor.run() else { return }
        var settings = store.settings; settings.shortcuts = shortcuts
        perform { try store.updateSettings(settings) }
    }
    func showSettings() {
        if !window.isVisible { show() }
        let alert = NSAlert(); alert.messageText = "剪贴板设置"; alert.informativeText = "历史、隐私和全局快捷键。"
        alert.window.sharingType = store.settings.hideInScreenCapture ? .none : .readOnly
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 570))
        let shortcuts = button("设置全局快捷键…", #selector(editShortcuts)); shortcuts.frame = NSRect(x: 0, y: 536, width: 180, height: 28); view.addSubview(shortcuts)
        func checkbox(_ title: String, _ state: Bool, _ y: CGFloat) -> NSButton {
            let control = NSButton(checkboxWithTitle: title, target: nil, action: nil); control.state = state ? .on : .off
            control.frame = NSRect(x: 0, y: y, width: 555, height: 24); view.addSubview(control); return control
        }
        func caption(_ title: String, _ y: CGFloat) { let control = label(title, size: 11, secondary: true); control.frame = NSRect(x: 0, y: y, width: 555, height: 20); view.addSubview(control) }
        let recording = checkbox("记录剪贴板内容（保存在本机，可随时暂停）", store.settings.enabled, 470)
        let plainText = checkbox("默认以纯文本粘贴（可保留历史中的原始格式）", store.settings.pasteAsPlainText == true, 504)
        let paused = checkbox("暂停记录", store.settings.paused, 440)
        let hidden = checkbox("请求窗口捕获隐藏内容（部分录屏方式不支持）", store.settings.hideInScreenCapture, 410)
        caption("历史保留天数（0 = 不自动过期；固定板内容永久保留）", 382)
        let retention = NSTextField(string: String(store.settings.retentionDays)); retention.frame = NSRect(x: 0, y: 352, width: 100, height: 25); view.addSubview(retention)
        caption("忽略以下应用（每行一个 Bundle ID，例如 com.apple.keychainaccess）", 322)
        func multiline(_ text: String, y: CGFloat, height: CGFloat) -> NSTextView {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: height)); editor.string = text; editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            editor.textContainerInset = NSSize(width: 5, height: 4); editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: NSRect(x: 0, y: y, width: 555, height: height)); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; view.addSubview(scroll); return editor
        }
        let excludedApps = multiline(store.settings.ignoredBundleIDs.joined(separator: "\n"), y: 242, height: 78)
        caption("忽略匹配的文字（每行一个正则表达式；留空不按内容排除）", 216)
        let excludedPatterns = multiline(store.settings.ignoredPatterns.joined(separator: "\n"), y: 138, height: 76)
        let mcp = checkbox("允许本机 AI 工具通过 MCP 读取固定板", store.settings.mcpEnabled, 102)
        let history = checkbox("同时允许 MCP 读取全部剪贴板历史", store.settings.mcpIncludeHistory, 72)
        caption("MCP 默认关闭；取消勾选会撤销后续读取。密码标记的内容始终跳过。", 44)
        caption("共享整个屏幕前请关闭面板；窗口捕获保护不能覆盖所有录屏软件。", 16)
        alert.accessoryView = view
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let days = Int(retention.stringValue), days >= 0, days <= 36500 else { presentError("保留天数请输入 0–36500 之间的整数。"); return }
        var settings = store.settings
        settings.enabled = recording.state == .on; settings.paused = paused.state == .on
        if !settings.paused { settings.pausedUntil = nil }
        settings.pasteAsPlainText = plainText.state == .on
        settings.hideInScreenCapture = hidden.state == .on; settings.retentionDays = days
        settings.ignoredBundleIDs = excludedApps.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        settings.ignoredPatterns = excludedPatterns.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        settings.mcpEnabled = mcp.state == .on; settings.mcpIncludeHistory = history.state == .on
        perform { try store.updateSettings(settings) }
    }
}
