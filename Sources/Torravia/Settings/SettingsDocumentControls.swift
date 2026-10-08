#if os(macOS)
import AppKit

/// Shared settings input surface; semantic colors follow appearance and contrast.
private enum SettingsInputSurface {
    static func outline(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    }

    static func draw(_ rect: NSRect) {
        let path = outline(rect)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func textRect(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: 8, dy: 4)
    }
}

final class SettingsTextFieldCell: NSTextFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        SettingsInputSurface.draw(cellFrame)
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: SettingsInputSurface.textRect(rect))
    }

    override var cellSize: NSSize { NSSize(width: super.cellSize.width + 16, height: 26) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView,
                   editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView,
                     editor: editor, delegate: delegate, start: start, length: length)
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        SettingsInputSurface.outline(cellFrame).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect { cellFrame }
}

/// Keep secure entry in AppKit's secure cell, including its field editor.
final class SettingsSecureTextFieldCell: NSSecureTextFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        SettingsInputSurface.draw(cellFrame)
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: SettingsInputSurface.textRect(rect))
    }

    override var cellSize: NSSize { NSSize(width: super.cellSize.width + 16, height: 26) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView,
                   editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView,
                     editor: editor, delegate: delegate, start: start, length: length)
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        SettingsInputSurface.outline(cellFrame).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect { cellFrame }
}

/// Let the settings page take over when an embedded editor cannot scroll
/// farther in the requested direction, including when its text fits entirely.
final class SettingsEditorScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        SettingsInputSurface.draw(bounds)
        if window?.isKeyWindow == true, window?.firstResponder === documentView {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            SettingsInputSurface.outline(bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshFocusRing), name: name, object: window)
            }
        }
    }

    @objc func refreshFocusRing() {
        needsDisplay = true
        setKeyboardFocusRingNeedsDisplay(bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        if let documentView, event.scrollingDeltaY != 0,
           let parentScrollView = superview?.enclosingScrollView {
            let visible = documentVisibleRect
            let delta = documentView.isFlipped ? -event.scrollingDeltaY : event.scrollingDeltaY
            let canScroll = delta > 0
                ? visible.maxY < documentView.bounds.maxY - 0.5
                : visible.minY > documentView.bounds.minY + 0.5
            if !canScroll {
                parentScrollView.scrollWheel(with: event)
                return
            }
        }
        super.scrollWheel(with: event)
    }
}

final class SettingsEditorTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        (enclosingScrollView as? SettingsEditorScrollView)?.refreshFocusRing()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        (enclosingScrollView as? SettingsEditorScrollView)?.refreshFocusRing()
        return accepted
    }
}

final class FlippedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        for view in subviews where Self.usesPointingHand(view) {
            addCursorRect(view.frame, cursor: .pointingHand)
        }
    }

    private static func usesPointingHand(_ view: NSView) -> Bool {
        view is NSButton || view is NSPopUpButton || view is NSSwitch || view is NSStepper
    }
}

final class PointingHandButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { enforcePointingHand() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

final class PointingHandSwitch: NSSwitch {
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { enforcePointingHand() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

final class PointingHandPopUpButton: NSPopUpButton {
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { enforcePointingHand() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

final class PointingHandStepper: NSStepper {
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { enforcePointingHand() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

private func enforcePointingHand() {
    NSCursor.pointingHand.set()
}

/// Cursor ownership is coordinated by SettingsSelectionWindowBridge. The
/// default NSTextView cursor rect covers its entire frame and can override
/// controls layered above it, so this view deliberately installs none.
final class SelectableSettingsTextView: NSTextView {
    override func resetCursorRects() {
        discardCursorRects()
    }

    override func cursorUpdate(with event: NSEvent) {
        // The window bridge sets the I-beam only when this view is the target.
    }
}

#endif
