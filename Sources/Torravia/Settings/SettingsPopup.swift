#if os(macOS)
import AppKit
import SwiftUI

@MainActor
private enum SettingsCursorCoordinator {
    static var isHoveringDone = false
}

/// Separate Settings window with native pane navigation and remembered selection.
struct NativeSettingsWindow: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.selectedPane") private var selection: SettingsCategory = .general
    @EnvironmentObject private var preferences: SeedingPreferencesStore
    @EnvironmentObject private var searchPreferences: SearchPreferencesStore
    @EnvironmentObject private var downloadLocation: DownloadLocationStore
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @EnvironmentObject private var automation: DownloadAutomationStore
    @EnvironmentObject private var providerHealth: ProviderHealthStore

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsCategory.allCases) { category in
                UnifiedSettingsPane(
                    category: category,
                    preferences: preferences,
                    searchPreferences: searchPreferences,
                    downloadLocation: downloadLocation,
                    downloadsVM: downloadsVM,
                    automation: automation,
                    providerHealth: providerHealth
                )
                .id(category)
                .tabItem { Label(category.title, systemImage: category.systemImage) }
                .tag(category)
            }
        }
        .frame(width: 600, height: selection == .general ? 360 : 560)
        .textSelection(.disabled)
        .overlay {
            SettingsSelectionWindowBridge()
                .allowsHitTesting(false)
        }
        .onExitCommand { dismiss() }
    }

}

/// Keeps SwiftUI's selectable text fully native while making a click outside
/// text clear the current selection, matching normal AppKit document behavior.
final class SettingsSelectionMarkerView: NSView {
    private var localMonitor: Any?
    private weak var observedWindow: NSWindow?
    private var previousMouseMovedEvents = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let contentView = window?.contentView else { return }
        Self.addControlCursorRects(from: contentView, to: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }

        observedWindow = window
        previousMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .rightMouseDown,
            .leftMouseUp,
            .rightMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .mouseMoved,
            .cursorUpdate
        ]) { [weak self] event in
            guard let self else { return event }
            return self.handleSelectionEvent(event)
        }

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.invalidateCursorRects(for: self)
        }

    }

    func handleSelectionEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        // The full-size content view can extend underneath the native title
        // and traffic lights. Those belong to AppKit, not the text document.
        guard window.contentLayoutRect.contains(event.locationInWindow) else {
            if event.type == .mouseMoved || event.type == .cursorUpdate {
                NSCursor.arrow.set()
            }
            return event
        }

        let hitPoint = window.contentView?.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        let hitView = window.contentView?.hitTest(hitPoint)
        let nativeControl = Self.interactiveControl(
            at: event.locationInWindow,
            in: window.contentView
        )
        let isOverNativeControl = nativeControl != nil
        let isOverDone = SettingsCursorCoordinator.isHoveringDone
        let isOverControl = isOverNativeControl || isOverDone

        if isOverNativeControl {
            NSCursor.pointingHand.set()
            // Keep control hover authoritative. The selectable text view
            // underneath the embedded controls otherwise receives the
            // motion/update event and immediately restores its I-beam.
            // Mouse down/up events still pass through normally.
            if event.type == .cursorUpdate || event.type == .mouseMoved {
                return nil
            }
        } else if isOverDone {
            NSCursor.pointingHand.set()
            if event.type == .cursorUpdate { return nil }
            if event.type == .mouseMoved {
                // Let SwiftUI receive the movement so it can emit `.ended`
                // when the pointer leaves Done. Restore the hand afterward
                // only if the button is still hovered.
                let windowPoint = event.locationInWindow
                DispatchQueue.main.async { [weak window] in
                    if SettingsCursorCoordinator.isHoveringDone {
                        NSCursor.pointingHand.set()
                    } else {
                        Self.applyCursor(at: windowPoint, in: window?.contentView)
                    }
                }
            }
        }

        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !Self.isSelectableText(hitView) {
                Self.clearSelections(in: window.contentView)
            }
        } else if !isOverControl {
            Self.applyCursor(at: event.locationInWindow, in: window.contentView)
            if event.type == .cursorUpdate || event.type == .mouseMoved {
                return nil
            }
        }

        // Never consume the event: selectable text still receives the
        // complete mouse-down/drag/up sequence used for range selection.
        return event
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopObserving() }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit { stopObserving() }

    private func stopObserving() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let observedWindow {
            observedWindow.acceptsMouseMovedEvents = previousMouseMovedEvents
        }
        observedWindow = nil
        SettingsCursorCoordinator.isHoveringDone = false
        NSCursor.arrow.set()
    }

    private static func isSelectableText(_ view: NSView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if let textView = current as? NSTextView, textView.isSelectable {
                return true
            }
            if let textField = current as? NSTextField,
               textField.isSelectable || textField.isEditable {
                return true
            }
            if current.accessibilityRole() == .staticText {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    private static func clearSelections(in view: NSView?) {
        guard let view else { return }
        if let textView = view as? NSTextView,
           textView.isSelectable,
           !textView.isEditable,
           textView.selectedRange().length > 0 {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        view.subviews.forEach { clearSelections(in: $0) }
    }

    private static func addControlCursorRects(from view: NSView, to marker: NSView) {
        if isInteractiveControl(view) {
            let rect = marker.convert(view.bounds, from: view).intersection(marker.bounds)
            if !rect.isEmpty { marker.addCursorRect(rect, cursor: .pointingHand) }
        }
        view.subviews.forEach { addControlCursorRects(from: $0, to: marker) }
    }

    private static func interactiveControl(at windowPoint: NSPoint, in view: NSView?) -> NSView? {
        guard let view, !view.isHidden, view.alphaValue > 0,
              view.visibleRect.contains(view.convert(windowPoint, from: nil)) else { return nil }

        for subview in view.subviews.reversed() {
            if let control = interactiveControl(at: windowPoint, in: subview) {
                return control
            }
        }

        if isInteractiveControl(view) {
            let rectInWindow = view.convert(view.bounds, to: nil)
            if rectInWindow.contains(windowPoint) { return view }
        }
        return nil
    }

    private static func isInteractiveControl(_ view: NSView) -> Bool {
        if view is NSButton || view is NSPopUpButton || view is NSSwitch || view is NSStepper {
            return true
        }
        switch view.accessibilityRole() {
        case .button, .checkBox, .popUpButton, .radioButton:
            return true
        default:
            return false
        }
    }

    private static func applyCursor(at windowPoint: NSPoint, in root: NSView?) {
        if interactiveControl(at: windowPoint, in: root) != nil {
            NSCursor.pointingHand.set()
        } else if linkedText(at: windowPoint, in: root) {
            NSCursor.pointingHand.set()
        } else if selectableText(at: windowPoint, in: root) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private static func linkedText(at windowPoint: NSPoint, in view: NSView?) -> Bool {
        guard let view, !view.isHidden, view.alphaValue > 0,
              view.visibleRect.contains(view.convert(windowPoint, from: nil)) else { return false }

        for subview in view.subviews.reversed() {
            if linkedText(at: windowPoint, in: subview) { return true }
        }

        let rectInWindow = view.convert(view.bounds, to: nil)
        guard rectInWindow.contains(windowPoint) else { return false }

        if let textView = view as? NSTextView, textView.isSelectable {
            return isOverLink(windowPoint, in: textView)
        }
        return false
    }

    private static func isOverLink(_ windowPoint: NSPoint, in textView: NSTextView) -> Bool {
        guard let manager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              manager.numberOfGlyphs > 0 else { return false }

        let localPoint = textView.convert(windowPoint, from: nil)
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: localPoint.x - origin.x, y: localPoint.y - origin.y)
        let glyphIndex = manager.glyphIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < manager.numberOfGlyphs else { return false }

        let glyphRect = manager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: container
        ).offsetBy(dx: origin.x, dy: origin.y)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(localPoint) else { return false }

        let characterIndex = manager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < storage.length else { return false }
        return storage.attribute(.link, at: characterIndex, effectiveRange: nil) != nil
    }

    private static func selectableText(at windowPoint: NSPoint, in view: NSView?) -> Bool {
        guard let view, !view.isHidden, view.alphaValue > 0,
              view.visibleRect.contains(view.convert(windowPoint, from: nil)) else { return false }

        for subview in view.subviews.reversed() {
            if selectableText(at: windowPoint, in: subview) { return true }
        }

        let rectInWindow = view.convert(view.bounds, to: nil)
        guard rectInWindow.contains(windowPoint) else { return false }

        if let textField = view as? NSTextField,
           textField.isSelectable || textField.isEditable {
            return true
        }
        if let textView = view as? NSTextView, textView.isSelectable {
            if textView.isEditable { return true }
            return isOverLaidOutGlyph(windowPoint, in: textView)
        }
        return false
    }

    private static func isOverLaidOutGlyph(_ windowPoint: NSPoint, in textView: NSTextView) -> Bool {
        guard let manager = textView.layoutManager,
              let container = textView.textContainer,
              manager.numberOfGlyphs > 0 else { return false }

        let localPoint = textView.convert(windowPoint, from: nil)
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: localPoint.x - origin.x, y: localPoint.y - origin.y)
        let glyphIndex = manager.glyphIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < manager.numberOfGlyphs else { return false }

        let glyphRect = manager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: container
        ).offsetBy(dx: origin.x, dy: origin.y)
        return glyphRect.insetBy(dx: -2, dy: -2).contains(localPoint)
    }
}

private struct SettingsSelectionWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsSelectionMarkerView {
        SettingsSelectionMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: SettingsSelectionMarkerView, context: Context) {}
}
#endif
