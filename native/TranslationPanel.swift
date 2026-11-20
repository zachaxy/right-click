import Cocoa
import SwiftUI
import Translation
import NaturalLanguage

@available(macOS 15.0, *)
final class TranslationModel: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let text: String
    }
    struct SourceLanguage: Identifiable {
        let id: String
        let name: String
    }

    @Published private(set) var source = ""
    @Published private(set) var result = ""
    @Published private(set) var status = "输入或粘贴文字，自动翻译为中文"
    @Published private(set) var isTranslating = false
    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var sourceLanguageID = ""
    @Published private(set) var automaticLanguageLabel = "自动识别"
    @Published private(set) var supportedLanguages = [
        SourceLanguage(id: "en", name: "英语"),
        SourceLanguage(id: Locale.Language(identifier: "zh-Hans").minimalIdentifier, name: "简体中文")
    ]
    @Published var shortcutWarning: String?
    @Published var focusID = UUID()
    private(set) var request: Request?
    private var debounce: Task<Void, Never>?
    private var nextConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))

    @MainActor func loadSupportedLanguages() async {
        let languages = await LanguageAvailability().supportedLanguages
        let locale = Locale(identifier: "zh-Hans")
        let choices = languages.map {
            SourceLanguage(id: $0.minimalIdentifier,
                           name: locale.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !choices.isEmpty { supportedLanguages = choices }
    }

    func setSourceLanguage(_ identifier: String) {
        guard identifier != sourceLanguageID else { return }
        cancel()
        sourceLanguageID = identifier
        result = ""
        status = "输入或粘贴文字，自动翻译为中文"
        translateNow()
    }

    func setSource(_ text: String) {
        guard text != source else { return }
        cancel()
        source = text
        result = ""
        automaticLanguageLabel = "自动识别"
        status = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "输入或粘贴文字，自动翻译为中文" : "等待输入完成…"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        debounce = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) }
            catch { return }
            self?.translateNow()
        }
    }

    func translateNow() {
        debounce?.cancel()
        debounce = nil
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let letters = source.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else {
            cancel()
            result = source
            status = "没有需要翻译的文字"
            return
        }
        let sourceLanguage: Locale.Language
        if !sourceLanguageID.isEmpty {
            sourceLanguage = Locale.Language(identifier: sourceLanguageID)
        } else {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(source)
            let candidate = recognizer.languageHypotheses(withMaximum: 1).first
            var language = candidate?.key
            // Short Latin words are ambiguous. Prefer English only when the
            // local detector is uncertain; preserve confident French, etc.
            let useEnglishFallback = source.count < 20 && letters.allSatisfy { $0.value < 128 }
                && (candidate?.value ?? 0) < 0.5
            if useEnglishFallback { language = .english }
            guard let language, language != .undetermined else {
                cancel()
                status = "无法确定原文语言，请在原文上方选择语言"
                return
            }
            sourceLanguage = Locale.Language(identifier: language.rawValue)
            let name = Locale(identifier: "zh-Hans").localizedString(forIdentifier: language.rawValue) ?? language.rawValue
            automaticLanguageLabel = "自动 · \(name)\(useEnglishFallback ? "（默认）" : "")"
        }
        // The framework cannot translate between two variants of Chinese.
        if sourceLanguage.languageCode?.identifier == "zh" {
            cancel()
            result = source.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? source
            status = "原文已是中文"
            return
        }
        request = Request(text: source)
        result = ""
        isTranslating = true
        status = "正在翻译…首次使用请按系统提示下载语言包"
        // Keep versions increasing even if SwiftUI coalesces cancel + restart
        // into one render (for example when the Services menu supplies new text).
        // Never leave source nil: Translation's own detector opens a blocking
        // language chooser for short words such as "clear" and "hello".
        nextConfiguration.source = sourceLanguage
        nextConfiguration.invalidate()
        configuration = nextConfiguration
    }

    func complete(_ request: Request, text: String) {
        guard self.request?.id == request.id else { return }
        self.request = nil
        result = text
        isTranslating = false
        status = "翻译完成"
    }

    func fail(_ request: Request, error: Error) {
        guard self.request?.id == request.id else { return }
        self.request = nil
        isTranslating = false
        switch error {
        case is CancellationError:
            status = "翻译已取消，点击「翻译」重试"
        case TranslationError.unableToIdentifyLanguage:
            status = "无法识别原文语言，请在原文上方选择语言后重试"
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedLanguagePairing:
            status = "系统暂不支持将此语言翻译为中文"
        default:
            status = "翻译未完成：\(error.localizedDescription) 点击「翻译」可重试。"
        }
    }

    func cancel() {
        debounce?.cancel()
        debounce = nil
        request = nil
        configuration = nil
        if isTranslating { status = "翻译已暂停，点击「翻译」重试" }
        isTranslating = false
    }

    func resume() {
        focusID = UUID()
        if !isTranslating && result.isEmpty && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translateNow() }
    }
}

@available(macOS 15.0, *)
private struct TranslationContent: View {
    @ObservedObject var model: TranslationModel
    @FocusState private var sourceFocused: Bool
    let close: () -> Void

    var body: some View {
        let request = model.request
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "character.bubble").font(.title2).foregroundStyle(Color.accentColor)
                Text("翻译").font(.title2.weight(.semibold))
                Spacer()
                Text("⇧⌘T 唤出").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("原文").font(.headline)
                        Picker("原文语言", selection: Binding(get: { model.sourceLanguageID }, set: { model.setSourceLanguage($0) })) {
                            Text(model.automaticLanguageLabel).tag("")
                            ForEach(model.supportedLanguages) { language in
                                Text(language.name).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        .accessibilityLabel("原文语言")
                        Spacer()
                        Button("清空") { model.setSource(""); sourceFocused = true }
                            .disabled(model.source.isEmpty)
                    }
                    TextEditor(text: Binding(get: { model.source }, set: { model.setSource($0) }))
                        .font(.system(size: 16))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                        .focused($sourceFocused)
                        .accessibilityLabel("原文")
                        .accessibilityIdentifier("translation-source")
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("中文").font(.headline)
                        Text("简体").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制译文") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.result, forType: .string)
                        }.disabled(model.result.isEmpty)
                    }
                    ScrollView {
                        Text(model.result.isEmpty ? "译文将显示在这里" : model.result)
                            .font(.system(size: 16))
                            .foregroundStyle(model.result.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    .accessibilityLabel("中文译文")
                    .accessibilityIdentifier("translation-result")
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                if model.isTranslating { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("translation-status")
                Spacer(minLength: 8)
                Button("翻译 ⌘↩") { model.translateNow() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTranslating)
            }
            if let warning = model.shortcutWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Text("使用 macOS 系统翻译 · 首次使用需要下载语言包，之后可离线翻译")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 340)
        .onAppear { sourceFocused = true }
        .task { await model.loadSupportedLanguages() }
        .onChange(of: model.focusID) { sourceFocused = true }
        .onExitCommand(perform: close)
        .translationTask(model.configuration) { session in
            guard let request else { return }
            do {
                let response = try await session.translate(request.text)
                try Task.checkCancellation()
                await MainActor.run { model.complete(request, text: response.targetText) }
            } catch {
                await MainActor.run { model.fail(request, error: error) }
            }
        }
    }
}

final class TranslationPanelController: NSObject, NSWindowDelegate {
    let window: NSPanel
    var shortcutWarning: String? { didSet { updateWarning?(shortcutWarning) } }
    private var updateWarning: ((String?) -> Void)?
    private var updateSource: ((String) -> Void)?
    private var resume: (() -> Void)?
    private var cancel: (() -> Void)?

    override init() {
        window = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 500),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "RightClick · 翻译"
        window.minSize = NSSize(width: 680, height: 400)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        if #available(macOS 15.0, *) {
            let model = TranslationModel()
            updateSource = { model.setSource($0) }
            updateWarning = { model.shortcutWarning = $0 }
            resume = { model.resume() }
            cancel = { model.cancel() }
            window.contentView = NSHostingView(rootView: TranslationContent(model: model, close: { [weak self] in self?.hide() }))
        } else {
            let label = NSTextField(wrappingLabelWithString: "系统翻译需要 macOS 15 或更新版本。\n请升级 macOS 后使用双栏翻译；当前仍可在「文字工具」中使用网页翻译。")
            label.frame = NSRect(x: 30, y: 180, width: 600, height: 100)
            window.contentView?.addSubview(label)
        }
        window.center()
        window.setFrameAutosaveName("RightClickTranslation")
    }

    func show(text: String? = nil) {
        if let text { updateSource?(text) }
        window.makeKeyAndOrderFront(nil)
        resume?()
    }

    func hide() { cancel?(); window.orderOut(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}
