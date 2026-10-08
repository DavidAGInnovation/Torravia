@testable import TorraviaSearchCore
import AppKit
import Testing
@testable import Torravia

@MainActor
private final class SettingsPageScrollRecorder: NSScrollView {
    var receivedEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) { receivedEvents.append(event) }
}

@MainActor
struct SettingsEditorScrollTests {
    private func scrollEvent(_ delta: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    private func fixture(editorHeight: CGFloat) -> (SettingsPageScrollRecorder, SettingsEditorScrollView) {
        let page = SettingsPageScrollRecorder(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        page.hasVerticalScroller = true
        page.verticalScrollElasticity = .none
        let document = FlippedSettingsDocumentView(frame: NSRect(x: 0, y: 0, width: 500, height: 1500))
        page.documentView = document
        let editor = SettingsEditorScrollView(frame: NSRect(x: 20, y: 200, width: 400, height: 100))
        editor.hasVerticalScroller = true
        editor.verticalScrollElasticity = .none
        editor.documentView = FlippedSettingsDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: editorHeight))
        document.addSubview(editor)
        page.tile()
        editor.tile()
        page.contentView.scroll(to: NSPoint(x: 0, y: 150))
        return (page, editor)
    }

    @Test func emptyAndShortEditorsScrollTheSettingsPage() throws {
        for height: CGFloat in [0, 40, 100] {
            let (page, editor) = fixture(editorHeight: height)
            let down = try scrollEvent(-40)
            let up = try scrollEvent(40)
            editor.scrollWheel(with: down)
            editor.scrollWheel(with: up)
            #expect(page.receivedEvents.count == 2)
            #expect(page.receivedEvents.first === down)
            #expect(page.receivedEvents.last === up)
        }
    }

    @Test func overflowingEditorScrollsItsTextBeforeThePage() throws {
        let (page, editor) = fixture(editorHeight: 500)
        editor.contentView.scroll(to: NSPoint(x: 0, y: 100))
        editor.scrollWheel(with: try scrollEvent(-40))
        editor.scrollWheel(with: try scrollEvent(40))
        #expect(page.receivedEvents.isEmpty)
    }

    @Test func editorHandsScrollingToThePageAtBothEnds() throws {
        let (page, editor) = fixture(editorHeight: 500)
        editor.contentView.scroll(to: NSPoint(x: 0, y: 500 - editor.contentSize.height))
        let down = try scrollEvent(-40)
        editor.scrollWheel(with: down)
        #expect(page.receivedEvents.count == 1)
        #expect(page.receivedEvents.last === down)
        editor.contentView.scroll(to: .zero)
        let up = try scrollEvent(40)
        editor.scrollWheel(with: up)
        #expect(page.receivedEvents.count == 2)
        #expect(page.receivedEvents.last === up)
    }
}
