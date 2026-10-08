#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Button labels are not selectable text. Register an explicit cursor too,
    /// so a plain SwiftUI button does not retain the adjacent editor's I-beam.
    func controlCursor() -> some View {
        textSelection(.disabled)
            .background(ControlCursorRegion())
    }
}

private struct ControlCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlCursorView { ControlCursorView() }
    func updateNSView(_ nsView: ControlCursorView, context: Context) {}
}

final class ControlCursorView: NSView {
    private var eventMonitor: Any?

    // The region supplies a cursor without intercepting button clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        discardCursorRects()
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        addCursorRect(rect, cursor: .arrow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate]) {
            [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return self.handleCursorEvent(event)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopMonitoring() }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit { stopMonitoring() }

    func handleCursorEvent(_ event: NSEvent) -> NSEvent? {
        guard event.type == .mouseMoved || event.type == .cursorUpdate,
              event.window === window, window != nil,
              !isHiddenOrHasHiddenAncestor,
              bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return event }
        NSCursor.arrow.set()
        // Selectable views behind the button must not reset the cursor after
        // this event. Click, drag and hover tracking events remain untouched.
        return nil
    }

    private func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}

/// Refresh a read-only document without moving a selection onto unrelated text.
/// Row identities disambiguate repeated titles when results move or disappear.
@MainActor
enum SelectableDocument {
    static func update(_ view: NSTextView, with document: NSAttributedString,
                       oldSections: [UUID: NSRange] = [:], newSections: [UUID: NSRange] = [:]) {
        guard let storage = view.textStorage, !storage.isEqual(to: document) else { return }
        let old = storage.string as NSString
        let new = document.string as NSString
        let ranges = view.selectedRanges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.length > 0, NSMaxRange(range) <= old.length else { return nil }
            if range.location == 0, range.length == old.length {
                return NSValue(range: NSRange(location: 0, length: new.length))
            }
            var searchRange = NSRange(location: 0, length: new.length)
            var expectedLocation = range.location
            if let section = oldSections.first(where: { NSLocationInRange(range.location, $0.value) && NSMaxRange(range) <= NSMaxRange($0.value) }) {
                guard let replacement = newSections[section.key] else { return nil }
                searchRange = replacement
                expectedLocation = replacement.location + range.location - section.value.location
            }
            let selected = old.substring(with: range)
            let before = old.substring(with: NSRange(location: max(0, range.location - 64), length: min(64, range.location)))
            let after = old.substring(with: NSRange(location: NSMaxRange(range), length: min(64, old.length - NSMaxRange(range))))
            var best: NSRange?
            var bestScore = -1
            var remaining = searchRange
            while remaining.length >= range.length {
                let candidate = new.range(of: selected, options: .literal, range: remaining)
                guard candidate.location != NSNotFound else { break }
                let prefix = new.substring(with: NSRange(location: max(0, candidate.location - 64), length: min(64, candidate.location)))
                let suffix = new.substring(with: NSRange(location: NSMaxRange(candidate), length: min(64, new.length - NSMaxRange(candidate))))
                let score = zip(before.reversed(), prefix.reversed()).prefix(while: { $0 == $1 }).count
                    + zip(after, suffix).prefix(while: { $0 == $1 }).count
                if score > bestScore || (score == bestScore && abs(candidate.location - expectedLocation) < abs((best?.location ?? 0) - expectedLocation)) {
                    best = candidate
                    bestScore = score
                }
                let next = NSMaxRange(candidate)
                remaining = NSRange(location: next, length: NSMaxRange(searchRange) - next)
            }
            return best.map { NSValue(range: $0) }
        }
        storage.setAttributedString(document)
        view.selectedRanges = ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
    }
}

/// Native selection for small informational labels, including labels beside
/// toggles. Buttons keep their own hit targets instead of swallowing the text.
struct SelectableLabel: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 12)
    var color: NSColor = .secondaryLabelColor

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isSelectable = true
        label.isEditable = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        if label.stringValue != text { label.stringValue = text }
        label.font = font
        label.textColor = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
#endif
