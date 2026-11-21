#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Opt-in desktop test. Run on an unlocked Mac with two overlapping work windows.
// swift tests/tray-focus-live.swift [target-bundle-id] [background-bundle-id]
// 0 = passed, 1 = focus or window order regressed, 2 = unsuitable environment.
enum CheckError: Error { case environment(String), regression(String) }

func app(_ id: String) throws -> NSRunningApplication {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: id)
    guard matches.count == 1 else { throw CheckError.environment("Expected one running instance of \(id)") }
    return matches[0]
}

func ax(_ item: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, attribute as CFString, &value) == .success ? value : nil
}

func bounds(_ item: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let p = ax(item, "AXPosition"), let s = ax(item, "AXSize"),
          AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

func trayCenter(_ target: AXUIElement, pid: pid_t) throws -> CGPoint {
    guard let extras = ax(target, "AXExtrasMenuBar"), let items = ax(extras as! AXUIElement, "AXChildren") as? [AXUIElement] else {
        throw CheckError.environment("Cannot read target's menu bar items")
    }
    for item in items {
        var owner: pid_t = 0
        guard AXUIElementGetPid(item, &owner) == .success, owner == pid,
              ax(item, "AXRole") as? String == "AXMenuBarItem", ax(item, "AXEnabled") as? Bool == true,
              (ax(item, "AXDescription") as? String)?.hasPrefix("趁手") == true,
              let rect = bounds(item), !rect.isEmpty else { continue }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        var displays: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 0, nil, &displays) == .success, displays > 0 { return point }
    }
    throw CheckError.environment("No enabled, on-screen 趁手 status item owned by the target")
}

struct Window {
    let id: CGWindowID, pid: pid_t, rect: CGRect
}

func windows() -> [Window] {
    let result = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    return (result as? [[String: Any]] ?? []).compactMap { row -> Window? in
        // Desktop overlays may span the screen with transparent content. Compare normal application windows.
        guard row[kCGWindowLayer as String] as? Int == 0,
              (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = row[kCGWindowNumber as String] as? CGWindowID,
              let pid = row[kCGWindowOwnerPID as String] as? pid_t,
              let raw = row[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw) else { return nil }
        return Window(id: id, pid: pid, rect: rect)
    }
}

func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func waitUntil(_ predicate: () -> Bool) -> Bool {
    let end = now() + 2
    while now() < end { if predicate() { return true }; pause(0.012) }
    return predicate()
}
func mouse(_ type: CGEventType, at point: CGPoint) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { throw CheckError.environment("Could not create a mouse event") }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count <= 2 else { throw CheckError.environment("Usage: tray-focus-live.swift [target-bundle-id] [background-bundle-id]") }
    let target = try app(args.first ?? "dev.rustclick.app")
    let background = try app(args.count == 2 ? args[1] : "com.openai.codex")
    let pid = target.processIdentifier, axTarget = AXUIElementCreateApplication(pid)
    guard pid != background.processIdentifier, AXIsProcessTrusted(), CGPreflightPostEventAccess()
    else { throw CheckError.environment("Use distinct apps and give the invoking terminal Accessibility access") }

    let workspace = NSWorkspace.shared, oldFront = workspace.frontmostApplication, oldMouse = CGEvent(source: nil)?.location
    defer {
        if let oldMouse { CGWarpMouseCursorPosition(oldMouse) }
        if let oldFront, workspace.frontmostApplication?.processIdentifier != oldFront.processIdentifier { _ = oldFront.activate(options: []) }
    }
    _ = background.activate(options: [])
    guard waitUntil({ workspace.frontmostApplication?.processIdentifier == background.processIdentifier })
    else { throw CheckError.environment("Background app did not activate") }
    let initialPoint = try trayCenter(axTarget, pid: pid)
    try mouse(.leftMouseDown, at: initialPoint)
    pause(0.08)
    try mouse(.leftMouseUp, at: initialPoint)
    guard waitUntil({ workspace.frontmostApplication?.processIdentifier == pid })
    else { throw CheckError.environment("Initial physical status-item click did not activate 趁手") }

    guard let workbench = (ax(axTarget, "AXWindows") as? [AXUIElement])?.first(where: {
        (ax($0, "AXTitle") as? String) == "趁手 · 桌面工具箱"
    }), let frame = bounds(workbench) else { throw CheckError.environment("Cannot locate the 趁手 workbench") }
    guard let main = windows().first(where: {
        $0.pid == pid && abs($0.rect.midX - frame.midX) < 2 && abs($0.rect.midY - frame.midY) < 2 &&
        abs($0.rect.width - frame.width) < 3 && abs($0.rect.height - frame.height) < 3
    }) else { throw CheckError.environment("Workbench has no matching on-screen window") }
    let backgroundWindows = windows().filter { $0.pid == background.processIdentifier }
    let intersections = backgroundWindows.map { $0.rect.intersection(main.rect) }
    let overlaps = intersections.filter { $0.width > 40 && $0.height > 40 }
    guard let overlap = overlaps.max(by: { first, second in
        first.width * first.height < second.width * second.height
    }) else {
        throw CheckError.environment("The background window must overlap the workbench")
    }
    let point = CGPoint(x: overlap.midX, y: overlap.midY)
    guard waitUntil({ windows().first { $0.rect.contains(point) }?.id == main.id }) else {
        throw CheckError.environment("The initial click did not put the workbench in front")
    }

    for hold in [0.075, 0.30, 0.075, 0.30] {
        let itemPoint = try trayCenter(axTarget, pid: pid)
        let start = now()
        var firstLoss: String?
        func observe(_ phase: String, for seconds: TimeInterval) {
            let end = now() + seconds
            repeat {
                let front = workspace.frontmostApplication, top = windows().first { $0.rect.contains(point) }
                if firstLoss == nil && (front?.processIdentifier != pid || top?.id != main.id) {
                    firstLoss = "\(phase) +\(Int((now() - start) * 1000)) ms: front=\(front?.bundleIdentifier ?? "none"), top window=\(top?.id.description ?? "none") (expected \(main.id))"
                }
                pause(0.003)
            } while now() < end
        }
        try mouse(.leftMouseDown, at: itemPoint)
        observe("down", for: hold)
        try mouse(.leftMouseUp, at: itemPoint)
        observe("up", for: 0.45)
        if let firstLoss { throw CheckError.regression("\(Int(hold * 1000)) ms press: \(firstLoss)") }
        print("PASS \(Int(hold * 1000)) ms press kept the workbench frontmost")
        pause(0.15)
    }
}

do { try run() }
catch CheckError.regression(let message) { print("FAIL: \(message)"); exit(1) }
catch { print("INCONCLUSIVE: \(error)"); exit(2) }
