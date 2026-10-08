@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct SettingsTitleBarCursorTests {
    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        if type == .cursorUpdate {
            return try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
    }

    @Test func nativeTitleAndTrafficLightsKeepArrowAndReceiveTheirEvents() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Search"
        let root = try #require(window.contentView)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        text.string = "Selectable settings information"
        text.isEditable = false; text.isSelectable = true
        text.setSelectedRange(NSRange(location: 0, length: 10))
        root.addSubview(text)
        let marker = SettingsSelectionMarkerView(frame: root.bounds)
        root.addSubview(marker)
        let previousCursor = NSCursor.current
        defer { marker.removeFromSuperview(); previousCursor.set() }

        var points = [NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.maxY + 5)]
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(window.standardWindowButton(kind))
            points.append(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        }
        for point in points {
            #expect(!window.contentLayoutRect.contains(point))
            for type in [NSEvent.EventType.mouseMoved, .cursorUpdate, .leftMouseDown, .leftMouseUp] {
                let event = try event(type, at: point, in: window)
                NSCursor.iBeam.set()
                #expect(marker.handleSelectionEvent(event) === event)
                if type == .mouseMoved || type == .cursorUpdate { #expect(NSCursor.current == NSCursor.arrow) }
                #expect(text.selectedRange() == NSRange(location: 0, length: 10))
            }
        }
    }

    @Test func clippedSettingsTextCannotSetCursorOutsideItsViewport() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        let label = NSTextField(labelWithString: "Selectable document text")
        label.isSelectable = true
        label.frame = NSRect(x: 20, y: 180, width: 200, height: 20)
        document.addSubview(label); scroll.documentView = document; root.addSubview(scroll)
        let marker = SettingsSelectionMarkerView(frame: root.bounds)
        root.addSubview(marker)
        let previousCursor = NSCursor.current
        defer { marker.removeFromSuperview(); previousCursor.set() }

        let clippedPoint = label.convert(NSPoint(x: 10, y: 10), to: nil)
        #expect(window.contentLayoutRect.contains(clippedPoint))
        #expect(!label.visibleRect.contains(NSPoint(x: 10, y: 10)))
        NSCursor.iBeam.set()
        #expect(marker.handleSelectionEvent(try event(.mouseMoved, at: clippedPoint, in: window)) == nil)
        #expect(NSCursor.current == NSCursor.arrow)

        label.frame.origin.y = 40
        let visiblePoint = label.convert(NSPoint(x: 10, y: 10), to: nil)
        #expect(label.visibleRect.contains(NSPoint(x: 10, y: 10)))
        #expect(marker.handleSelectionEvent(try event(.mouseMoved, at: visiblePoint, in: window)) == nil)
        #expect(NSCursor.current == NSCursor.iBeam)
    }
}
