import Cocoa

// Shortcut tools take keyboard focus without activating the whole application
// and raising an already-open console behind them. Set this style at creation;
// changing a panel's activation style later does not update all AppKit state.
class ToolPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask.union(.nonactivatingPanel),
                   backing: backing, defer: flag)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
    }
}
