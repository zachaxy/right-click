import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-keyboard-" + UUID().uuidString)
let history = directory.appendingPathComponent("history.json")
defer { try? FileManager.default.removeItem(at: directory) }

var front: String? = "chat"
var source: String? = "FR"
var installed: Set<String> = ["EN", "JP", "ZH", "FR"]
var attempts = [String]()
var delayedSelection = false
var checks = 0

func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { fatalError(message) }
}
func rule(_ app: String, _ source: String?, remember: Bool = false) -> InputSourceRule {
    InputSourceRule(bundleID: app, name: app, defaultSourceID: source, rememberLast: remember, forceEnglishPunctuation: false)
}
func runtime() -> InputSourceCoordinator {
    InputSourceCoordinator(historyURL: history, frontmostBundleID: { front }, currentSource: { source }, selectSource: {
        attempts.append($0)
        guard installed.contains($0) else { return false }
        if !delayedSelection { source = $0 }
        return true
    })
}

var coordinator = runtime()
coordinator.start()
check(attempts.isEmpty && !FileManager.default.fileExists(atPath: history.path), "empty configuration is inactive")
var settings = InputSourceSettings(rules: ["chat": rule("chat", "ZH", remember: true), "term": rule("term", "EN")])
coordinator.update(settings: settings)
check(source == "ZH" && attempts == ["ZH"], "first visit uses the configured fallback")
source = "JP"
coordinator.recordSelectedSource()
settings.rules["chat"]?.forceEnglishPunctuation = true
coordinator.update(settings: settings)
coordinator.applicationActivated()
check(source == "JP" && attempts == ["ZH"], "unrelated edits and duplicate activations preserve manual selections")
front = "term"
source = "EN"
coordinator.recordSelectedSource() // Source notification can precede the pending workspace activation.
coordinator.applicationActivated()
source = "FR"
coordinator.recordSelectedSource()
front = "chat"
delayedSelection = true
coordinator.applicationActivated()
coordinator.recordSelectedSource()
check(attempts.last == "JP", "a late cross-app notification cannot replace the chat's remembered source")
let delayedHistory = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: history))
check(delayedHistory["chat"] == "JP", "an old source during a delayed TIS selection cannot overwrite memory")
delayedSelection = false
source = "JP"
coordinator.recordSelectedSource()
front = "other"
coordinator.applicationActivated()
check(source == "JP", "unconfigured applications leave the active source alone")
front = "term"
coordinator.applicationActivated()
check(source == "EN", "an app without memory always returns to its configured default")

front = "chat"
coordinator.applicationActivated()
source = "FR" // A final source notification may still be outstanding at shutdown.
coordinator.stop()
attempts.removeAll()
source = "EN"
coordinator = runtime()
coordinator.update(settings: settings)
coordinator.start()
check(source == "FR" && attempts == ["FR"], "last confirmed selection survives process restart")
front = "other"
coordinator.applicationActivated()
source = "JP"
installed.remove("FR")
attempts.removeAll()
front = "chat"
coordinator.applicationActivated()
check(source == "ZH" && attempts == ["FR", "ZH"], "unavailable remembered source falls back to enabled default")
settings.rules["chat"]?.rememberLast = false
coordinator.update(settings: settings)
check(!FileManager.default.fileExists(atPath: history.path), "turning off the last memory rule clears its durable history")
settings.rules["chat"] = rule("chat", nil, remember: true)
source = "JP"
coordinator.update(settings: settings)
front = "term"
coordinator.applicationActivated()
front = "chat"
coordinator.applicationActivated()
check(source == "JP", "remember-only rules restore even with no default")
settings.rules.removeValue(forKey: "chat")
coordinator.update(settings: settings)
check(!FileManager.default.fileExists(atPath: history.path), "removing a rule clears its durable history")
source = "ZH"
front = "term"
coordinator.applicationActivated()
front = "chat"
coordinator.applicationActivated()
check(source == "EN", "a removed rule does not switch input sources")
settings.rules["chat"] = rule("chat", "missing")
source = "JP"
coordinator.update(settings: settings)
check(source == "JP", "missing default leaves current source alone")
settings.rules["chat"] = rule("chat", nil)
settings.rules["term"] = nil
settings.rules["chat"]?.forceEnglishPunctuation = true
coordinator.update(settings: settings)
attempts.removeAll()
front = "term"
coordinator.applicationActivated()
coordinator.stop()
check(attempts.isEmpty && !FileManager.default.fileExists(atPath: history.path), "punctuation-only configuration does not change or persist input sources")

// A text document can restore its own layout immediately after the workspace activation.
front = "chat"
source = "JP"
settings = InputSourceSettings(rules: ["chat": rule("chat", "JP", remember: true)])
coordinator = runtime()
coordinator.update(settings: settings)
coordinator.start()
source = "EN"
coordinator.recordSelectedSource()
func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }
settle()
check(source == "JP" && attempts == ["JP"], "rollbacks are corrected even when the target was already selected on activation")
source = "EN"
coordinator.recordSelectedSource()
settle()
check(source == "EN" && attempts == ["JP"], "after verification the user's selection takes effect")
front = "other"
coordinator.applicationActivated()
source = "ZH"
front = "chat"
coordinator.applicationActivated()
source = "ZH"
coordinator.recordSelectedSource()
front = "other"
coordinator.applicationActivated()
let before = attempts
settle()
check(source == "ZH" && attempts == before, "a delayed retry cannot change the next application's keyboard")
coordinator.stop()
print("PASS: \(checks) per-app input source checks")
