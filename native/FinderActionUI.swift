import Cocoa
import UniformTypeIdentifiers

private func onMain<T>(_ work: () -> T) -> T {
    Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
}

// A Finder operation can accept keyboard input without activating the app and
// bringing its existing main window to the front.
private final class FinderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func createFinderPanel(_ title: String, size: NSSize) -> FinderPanel {
    let window = FinderPanel(contentRect:NSRect(origin:.zero,size:size),
        styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.isFloatingPanel = false
    window.center()
    return window
}

private func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString:text)
    field.font = bold ? .boldSystemFont(ofSize:size) : .systemFont(ofSize:size)
    field.isSelectable = true
    return field
}

private final class FinderPromptWindow: NSObject, NSWindowDelegate {
    let window: FinderPanel
    let fields: [FinderField]
    var controls: [String:NSControl] = [:]
    var values: [String:String]?
    let validation = label("")

    init(title: String, message: String, fields: [FinderField], accept: String) {
        self.fields = fields
        window = createFinderPanel(title,size:NSSize(width:460,height:280))
        super.init()
        window.delegate = self
        let body = NSStackView()
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:22),
            body.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-22),
            body.topAnchor.constraint(equalTo:content.topAnchor,constant:20),
            body.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-18)
        ])
        body.addArrangedSubview(label(title,size:17,bold:true))
        if !message.isEmpty {
            let scroll = NSTextView.scrollablePlainDocumentContentTextView()
            let text = scroll.documentView as! NSTextView
            text.string = message; text.isEditable = false; text.isSelectable = true
            text.drawsBackground = false; text.font = .systemFont(ofSize:13)
            text.textColor = .secondaryLabelColor
            text.textContainerInset = NSSize(width:0,height:3)
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            body.addArrangedSubview(scroll)
            let lines = message.split(separator:"\n",omittingEmptySubsequences:false).count
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalTo:body.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant:CGFloat(min(max(lines * 18 + message.count / 42 * 16,38),140)))
            ])
        }
        for field in fields {
            body.addArrangedSubview(label(field.label,bold:true))
            let control: NSControl
            if !field.choices.isEmpty {
                let popup = NSPopUpButton(frame:.zero,pullsDown:false)
                for choice in field.choices { popup.addItem(withTitle:choice.1); popup.lastItem?.representedObject = choice.0 }
                if let selected = field.choices.firstIndex(where:{$0.0 == field.value}) { popup.selectItem(at:selected) }
                control = popup
            } else {
                let input: NSTextField = field.secure ? NSSecureTextField() : NSTextField()
                input.stringValue = field.value; input.font = .systemFont(ofSize:14)
                input.bezelStyle = .roundedBezel
                control = input
            }
            control.setAccessibilityLabel(field.label)
            controls[field.key] = control
            body.addArrangedSubview(control)
            control.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true
        }
        validation.textColor = .systemRed
        body.addArrangedSubview(validation)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let cancel = NSButton(title:"取消",target:self,action:#selector(cancelAction))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title:accept,target:self,action:#selector(acceptAction))
        ok.bezelStyle = .rounded; ok.keyEquivalent = "\r"
        buttons.addArrangedSubview(spacer); buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(ok)
        body.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true
        content.layoutSubtreeIfNeeded()
        let height = body.fittingSize.height + 38
        window.setContentSize(NSSize(width:460,height:max(200,height)))
        window.center()
        if let first = fields.first, let input = controls[first.key] as? NSTextField {
            window.initialFirstResponder = input
        }
    }
    func run() -> [String:String]? {
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for:window)
        window.orderOut(nil)
        return values
    }
    @objc func acceptAction() {
        var output: [String:String] = [:]
        for field in fields {
            let value: String
            if let popup = controls[field.key] as? NSPopUpButton { value = popup.selectedItem?.representedObject as? String ?? "" }
            else { value = (controls[field.key] as? NSTextField)?.stringValue ?? "" }
            if field.required && value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                validation.stringValue = "请填写" + field.label
                window.makeFirstResponder(controls[field.key]); return
            }
            output[field.key] = value
        }
        values = output
        NSApp.stopModal(withCode:.OK)
    }
    @objc func cancelAction() { NSApp.stopModal(withCode:.cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelAction(); return false }
}

private final class FinderResultWindow: NSObject, NSWindowDelegate {
    let window: FinderPanel
    let text: String
    let paths: [String]
    let closed: () -> Void
    init(title: String, text: String, paths: [String], closed: @escaping () -> Void) {
        self.text = text; self.paths = paths; self.closed = closed
        window = createFinderPanel(title,size:NSSize(width:680,height:460))
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width:440,height:280)
        super.init()
        window.delegate = self
        let content = window.contentView!
        let scroll = NSTextView.scrollablePlainDocumentContentTextView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let view = scroll.documentView as! NSTextView; view.string = text; view.isEditable = false
        view.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        view.textContainerInset = NSSize(width:12,height:12)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byCharWrapping
        view.textStorage?.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:(text as NSString).length))
        content.addSubview(scroll)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let copy = NSButton(title:"拷贝结果",target:self,action:#selector(copyResult)); copy.bezelStyle = .rounded
        buttons.addArrangedSubview(copy)
        if !paths.isEmpty {
            let reveal = NSButton(title:"在访达中显示",target:self,action:#selector(revealResult)); reveal.bezelStyle = .rounded
            buttons.addArrangedSubview(reveal)
        }
        let close = NSButton(title:"关闭",target:self,action:#selector(closeResult)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(close); content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo:content.topAnchor,constant:16),
            scroll.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),
            scroll.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),
            scroll.bottomAnchor.constraint(equalTo:buttons.topAnchor,constant:-14),
            buttons.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),
            buttons.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-14)
        ])
        window.makeKeyAndOrderFront(nil)
    }
    @objc func copyResult() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
    @objc func revealResult() { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath:$0) }) }
    @objc func closeResult() { window.close() }
    func windowWillClose(_ notification: Notification) { closed() }
}

final class DesktopFinderUI: FinderActionUI {
    private var windows: [UUID:FinderResultWindow] = [:]
    private var notice: NSPanel?
    private var noticeToken = UUID()
    func prompt(_ title: String, message: String, fields: [FinderField], accept: String) -> [String:String]? {
        onMain {
            hideNotice()
            return FinderPromptWindow(title:title,message:message,fields:fields,accept:accept).run()
        }
    }
    func confirm(_ title: String, message: String, accept: String) -> Bool {
        prompt(title,message:message,fields:[],accept:accept) != nil
    }
    func choose(_ title: String, directory: Bool, initial: String) -> String? {
        onMain {
            hideNotice()
            let chooser = NSOpenPanel()
            chooser.title = title; chooser.prompt = "选择"
            chooser.canChooseDirectories = directory; chooser.canChooseFiles = !directory
            chooser.allowsMultipleSelection = false; chooser.canCreateDirectories = directory
            chooser.directoryURL = URL(fileURLWithPath:initial)
            if !directory { chooser.allowedContentTypes = [.image] }
            return chooser.runModal() == .OK ? chooser.url?.path : nil
        }
    }
    func result(_ title: String, text: String, paths: [String]) {
        onMain {
            hideNotice()
            let id = UUID()
            windows[id] = FinderResultWindow(title:title,text:text,paths:paths) { [weak self] in self?.windows.removeValue(forKey:id) }
        }
    }
    func begin() {
        onMain {
            hideNotice()
            let token = noticeToken
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.7) { [weak self] in
                guard let self = self, self.noticeToken == token else { return }
                self.showNotice("RightClick 正在处理…")
            }
        }
    }
    func finish(_ message: String?) {
        onMain {
            hideNotice()
            guard let message = message else { return }
            showNotice(message)
            let token = noticeToken
            DispatchQueue.main.asyncAfter(deadline:.now() + 2.5) { [weak self] in
                guard let self = self, self.noticeToken == token else { return }
                self.hideNotice()
            }
        }
    }
    private func hideNotice() { noticeToken = UUID(); notice?.orderOut(nil); notice = nil }
    private func showNotice(_ message: String) {
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:340,height:64),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.level = .floating; window.ignoresMouseEvents = true
        window.backgroundColor = .windowBackgroundColor; window.hasShadow = true
        let text = label(message,size:13,bold:true); text.frame = NSRect(x:18,y:12,width:304,height:40)
        window.contentView?.addSubview(text)
        if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-364,y:screen.visibleFrame.maxY-90)) }
        notice = window; window.orderFrontRegardless()
    }
}
