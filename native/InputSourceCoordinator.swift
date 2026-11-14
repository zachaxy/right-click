import Cocoa
import Carbon

struct InputSourceOption {
    let id: String
    let name: String
}

private enum SystemKeyboardSources {
    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func id(_ source: TISInputSource) -> String? {
        guard let id = string(source, kTISPropertyInputSourceID) else { return nil }
        // Some input methods expose several selectable modes under one source ID.
        if let mode = string(source, kTISPropertyInputModeID), !mode.isEmpty, mode != id {
            return id + "/" + mode
        }
        return id
    }

    private static func selectable() -> [TISInputSource] {
        let properties = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ] as CFDictionary
        return TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func options() -> [InputSourceOption] {
        var seen = Set<String>()
        return selectable().compactMap { source in
            guard let id = id(source), seen.insert(id).inserted else { return nil }
            return InputSourceOption(id: id, name: string(source, kTISPropertyLocalizedName) ?? id)
        }
    }

    static func current() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return id(source)
    }

    static func select(_ wanted: String) -> Bool {
        guard let source = selectable().first(where: { id($0) == wanted }) else { return false }
        return TISSelectInputSource(source) == noErr
    }
}

final class InputSourceCoordinator {
    private let historyURL: URL
    private let frontmostBundleID: () -> String?
    private let currentSource: () -> String?
    private let selectSource: (String) -> Bool
    private var settings = InputSourceSettings()
    private var remembered: [String: String]
    private var activeApp: String?
    // A transition with no previous ID was already at its target on activation. In this
    // case verify once too, since the incoming text document may restore its own layout.
    private var transition: (previous: String?, wanted: String)?
    private var confirmation: DispatchWorkItem?
    private var started = false
    private var appObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?

    static func availableSources() -> [InputSourceOption] { SystemKeyboardSources.options() }

    init(historyURL: URL? = nil,
         frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         currentSource: @escaping () -> String? = SystemKeyboardSources.current,
         selectSource: @escaping (String) -> Bool = SystemKeyboardSources.select) {
        let root = ProcessInfo.processInfo.environment["RUSTCLICK_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RustClick")
        let url = historyURL ?? root.appendingPathComponent("input-source-history.json")
        self.historyURL = url
        self.frontmostBundleID = frontmostBundleID
        self.currentSource = currentSource
        self.selectSource = selectSource
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            remembered = stored
        } else {
            remembered = [:]
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refreshObservation()
    }

    func stop() {
        recordSelectedSource()
        started = false
        removeObservers()
    }

    func update(settings newSettings: InputSourceSettings) {
        let priorRule = activeApp.flatMap { settings.rules[$0] }
        settings = newSettings
        let retained = remembered.filter { settings.rules[$0.key]?.rememberLast == true }
        if retained != remembered {
            remembered = retained
            saveHistory()
        }
        guard started else { return }
        let wasObserving = appObserver != nil
        refreshObservation()
        guard wasObserving, appObserver != nil else { return }
        if frontmostBundleID() != activeApp {
            applicationActivated()
        } else if let app = activeApp {
            let rule = settings.rules[app]
            if priorRule?.defaultSourceID != rule?.defaultSourceID || priorRule?.rememberLast != rule?.rememberLast {
                endTransition()
                if let rule { apply(rule, app: app) }
            }
        }
    }

    private func refreshObservation() {
        guard settings.rules.values.contains(where: { $0.rememberLast || $0.defaultSourceID != nil }) else {
            removeObservers()
            return
        }
        guard appObserver == nil else { return }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applicationActivated() }
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.recordSelectedSource() }
        applicationActivated()
    }

    private func removeObservers() {
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        appObserver = nil
        sourceObserver = nil
        activeApp = nil
        endTransition()
    }

    func applicationActivated() {
        guard started, appObserver != nil else { return }
        // A queued activation can already refer to a background app. Always read the live owner.
        let app = frontmostBundleID()
        guard activeApp != app else { return }
        activeApp = app
        endTransition()
        if let app, let rule = settings.rules[app] { apply(rule, app: app) }
    }

    private func apply(_ rule: InputSourceRule, app: String) {
        guard rule.rememberLast || rule.defaultSourceID != nil else { return }
        let last = rule.rememberLast ? remembered[app] : nil
        let current = currentSource()
        var candidates = [String]()
        if let last { candidates.append(last) }
        if let fallback = rule.defaultSourceID, fallback != last { candidates.append(fallback) }
        for wanted in candidates {
            guard frontmostBundleID() == app else { return }
            if current == wanted {
                remember(wanted, for: app)
                transition = (nil, wanted)
                confirmSelection(for: app, allowRetry: true)
                return
            }
            transition = (current, wanted)
            if selectSource(wanted) {
                if currentSource() == wanted { remember(wanted, for: app) }
                confirmSelection(for: app, allowRetry: true)
                return
            }
            endTransition()
        }
        if let current { remember(current, for: app) }
    }

    private func endTransition() {
        confirmation?.cancel()
        confirmation = nil
        transition = nil
    }

    private func confirmSelection(for app: String, allowRetry: Bool) {
        // Document activation and TIS selection can both succeed and then the IME rolls
        // back to the outgoing layout. Recheck after activation settles, and retry once
        // only for that same layout and foreground app. A third selection belongs to the user.
        let task = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.transition else { return }
            guard self.activeApp == app, self.frontmostBundleID() == app else {
                self.endTransition()
                return
            }
            let observed = self.currentSource()
            let reverted = observed != pending.wanted && (pending.previous == nil || observed == pending.previous)
            if allowRetry, reverted, self.selectSource(pending.wanted) {
                self.confirmSelection(for: app, allowRetry: false)
                return
            }
            self.endTransition()
            // A refused retry is not a user's choice. Keep the saved source for the
            // next visit; subsequent manual input-source notifications still take effect.
            if !reverted, let observed { self.remember(observed, for: app) }
        }
        confirmation = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: task)
    }

    func recordSelectedSource() {
        // The system may have applied an incoming document's keyboard before our app-activation
        // callback. Reading a source on departure would save that keyboard for the outgoing app.
        guard let app = activeApp, settings.rules[app]?.rememberLast == true,
              frontmostBundleID() == app, let source = currentSource() else { return }
        if let pending = transition {
            if source != pending.wanted && (pending.previous == nil || source == pending.previous) { return }
            if source != pending.wanted { endTransition() }
        }
        remember(source, for: app)
    }

    private func remember(_ source: String, for app: String) {
        guard settings.rules[app]?.rememberLast == true, frontmostBundleID() == app,
              remembered[app] != source else { return }
        remembered[app] = source
        saveHistory()
    }

    private func saveHistory() {
        do {
            if remembered.isEmpty {
                if FileManager.default.fileExists(atPath: historyURL.path) { try FileManager.default.removeItem(at: historyURL) }
            } else {
                try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(remembered).write(to: historyURL, options: .atomic)
            }
        } catch {
            NSLog("RightClick 无法保存应用输入法记录：%@", error.localizedDescription)
        }
    }
}
