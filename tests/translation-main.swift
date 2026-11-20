import Cocoa
import Translation

// The model has no attached translationTask, so these checks never download
// language models, access the pasteboard, or submit text to a translation service.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: " + message + "\n", stderr); exit(1) }
}
func settle(_ seconds: TimeInterval = 0.1) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

if #available(macOS 15.0, *) {
    let model = TranslationModel()
    check(model.source.isEmpty && model.result.isEmpty && model.request == nil,
          "opening an empty model does not implicitly read or translate text")
    model.setSource("clear")
    model.translateNow()
    check(model.request?.text == "clear" && model.configuration?.source?.languageCode?.identifier == "en",
          "short English input supplies an explicit source language instead of opening system language detection")
    for (text, language) in [
        ("hello", "en"), ("test", "en"), ("set", "en"), ("save", "en"),
        ("open", "en"), ("clear cache", "en"), ("bonjour", "fr"),
        ("merci", "fr"), ("hola", "es"), ("こんにちは、今日は良い天気ですね。", "ja")
    ] {
        model.setSource(text)
        model.translateNow()
        check(model.request?.text == text && model.configuration?.source?.languageCode?.identifier == language,
              "automatic detection chooses an explicit \(language) source for \(text)")
    }
    for text in ["12345", "?! +-= @#$", "🙂🎉"] {
        model.setSource(text)
        model.translateNow()
        check(model.request == nil && model.configuration == nil && !model.isTranslating && model.result == text,
              "numeric or symbol-only input does not invoke language detection: \(text)")
    }
    model.setSource("clear")
    model.translateNow()
    let automaticallyDetected = model.request!
    model.setSourceLanguage("fr")
    let manuallySelected = model.request!
    check(model.sourceLanguageID == "fr" && model.configuration?.source?.languageCode?.identifier == "fr"
          && manuallySelected.id != automaticallyDetected.id,
          "manually selecting a source language replaces an in-flight automatic request")
    model.complete(automaticallyDetected, text: "过时的自动识别结果")
    model.fail(automaticallyDetected, error: TranslationError.unsupportedSourceLanguage)
    check(model.result.isEmpty && model.request == manuallySelected && model.isTranslating,
          "late automatic callbacks cannot override the manually selected language")
    model.setSourceLanguage("")
    check(model.sourceLanguageID.isEmpty && model.configuration?.source?.languageCode?.identifier == "en"
          && model.request?.id != manuallySelected.id,
          "switching back to automatic detection restores the English source for clear")
    model.setSource("这是一个测试，欢迎使用翻译功能。")
    model.setSourceLanguage("en")
    check(model.configuration?.source?.languageCode?.identifier == "en" && model.request?.text == model.source
          && model.result.isEmpty && model.isTranslating,
          "manual English selection takes precedence over Chinese passthrough detection")
    model.setSourceLanguage("")
    model.setSource("The first sentence should be replaced before translation starts.")
    settle(0.15)
    check(model.request == nil && !model.isTranslating, "typing waits for the debounce period")
    let latest = "The newest sentence is the only one that should be translated.\nKeep this second line."
    model.setSource(latest)
    settle(0.8)
    let first = model.request!
    check(first.text == latest && model.isTranslating && model.configuration?.source?.languageCode?.identifier == "en",
          "debouncing submits only the latest full text with its locally detected source language")
    check(model.configuration?.target == Locale.Language(identifier: "zh-Hans"),
          "translation targets Simplified Chinese")

    let beforeEdit = model.configuration!
    model.setSource("A new edit invalidates the previous translation immediately.")
    check(model.request == nil && model.result.isEmpty && model.configuration == nil && !model.isTranslating,
          "editing invalidates an active request and clears its old output")
    model.complete(first, text: "过时的译文")
    model.fail(first, error: TranslationError.unsupportedSourceLanguage)
    check(model.result.isEmpty && !model.status.contains("暂不支持"),
          "late success and failure callbacks cannot overwrite a newer edit")

    model.translateNow()
    let second = model.request!
    check(model.configuration != beforeEdit && model.configuration!.version > beforeEdit.version,
          "editing and immediately submitting within one runloop turn changes the framework configuration")
    let initialVersion = model.configuration!.version
    model.fail(second, error: TranslationError.unableToIdentifyLanguage)
    check(!model.isTranslating && model.request == nil && model.status.contains("无法识别"),
          "language detection failure leaves an actionable idle state")
    model.translateNow()
    let retry = model.request!
    check(retry.id != second.id && model.configuration!.version > initialVersion && model.isTranslating,
          "retry creates a new request and invalidates the existing framework configuration")
    model.complete(second, text: "过时的重试结果")
    check(model.result.isEmpty && model.request == retry,
          "an older attempt cannot complete a newer retry")
    model.complete(retry, text: "新的编辑会立即取消先前的翻译。")
    check(model.result == "新的编辑会立即取消先前的翻译。" && !model.isTranslating && model.request == nil,
          "the current result is shown and the busy state finishes")

    let focus = model.focusID
    model.resume()
    check(model.focusID != focus && model.request == nil && !model.result.isEmpty,
          "reopening completed content restores focus without translating again")
    model.setSource("This pending input is cleared before its delayed request starts.")
    model.setSource(" \n\t ")
    settle(0.8)
    check(model.request == nil && model.configuration == nil && model.result.isEmpty && !model.isTranslating,
          "whitespace-only input cancels pending work and removes stale output")
    model.translateNow()
    check(model.request == nil, "manual translation does nothing for whitespace-only input")

    model.setSource("This sentence is cancelled when the window is dismissed.")
    model.translateNow()
    let dismissed = model.request!
    let beforeDismiss = model.configuration!
    model.cancel()
    model.complete(dismissed, text: "不应出现")
    settle(0.8)
    check(model.request == nil && model.configuration == nil && model.result.isEmpty && !model.isTranslating,
          "dismissing cancels active and delayed work and rejects late results")
    model.resume()
    check(model.request?.text == dismissed.text && model.request?.id != dismissed.id && model.isTranslating,
          "reopening unfinished input starts a fresh request")
    check(model.configuration != beforeDismiss && model.configuration!.version > beforeDismiss.version,
          "resuming after cancellation creates a distinct framework configuration")
    let resumed = model.request!
    let beforeRepeatedResume = model.configuration!
    model.resume()
    check(model.request == resumed && model.configuration == beforeRepeatedResume,
          "repeated shortcut invocation during translation preserves the active request")
    model.cancel()
    model.resume()
    check(model.configuration != beforeRepeatedResume && model.configuration!.version > beforeRepeatedResume.version,
          "cancel and resume within one runloop turn still advances the framework configuration")
    model.fail(model.request!, error: CancellationError())
    check(!model.isTranslating && model.status.contains("取消"), "system cancellation does not leave a spinner running")

    model.setSource("这是一个测试，欢迎使用翻译功能。")
    model.translateNow()
    check(model.result == model.source && model.request == nil && !model.isTranslating,
          "Simplified Chinese input is displayed without an unsupported same-language request")
    model.setSource("這是一個測試，歡迎使用翻譯功能。")
    model.translateNow()
    check(model.result == "这是一个测试，欢迎使用翻译功能。" && model.configuration == nil,
          "Traditional Chinese is converted to Simplified Chinese locally")
    model.cancel()
}

// Inspect a hidden panel without initiating any translation.
let panel = TranslationPanelController()
panel.window.setFrameAutosaveName("")
check(!panel.window.isVisible && panel.window.isReleasedWhenClosed == false,
      "the panel starts hidden and is retained for repeated shortcut invocation")
check(panel.window.minSize == NSSize(width: 680, height: 400) && panel.window.styleMask.contains(.resizable),
      "the two-column window is resizable with a usable minimum size")
panel.window.setFrame(NSRect(x: 0, y: 0, width: 680, height: 400), display: false)
panel.window.contentView!.layoutSubtreeIfNeeded()
settle()
check(abs(panel.window.frame.width - 680) < 0.5 && abs(panel.window.frame.height - 400) < 0.5,
      "hosting the content preserves the requested minimum window size")
check(panel.window.contentView!.bounds.width >= 640 && panel.window.contentView!.bounds.height >= 340,
      "the native content area remains large enough for both text panes")
check(panel.windowShouldClose(panel.window) == false && !panel.window.isVisible,
      "closing hides the panel instead of destroying its content")
check(app.activationPolicy() == .prohibited, "isolated checks never activate or show the app")
print("Translation: \(checks) isolated checks passed")
