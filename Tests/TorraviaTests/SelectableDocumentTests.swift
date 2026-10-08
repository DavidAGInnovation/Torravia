@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

private final class LayoutInvalidationRecorder: NSObject, NSLayoutManagerDelegate {
    var invalidations = 0
    func layoutManagerDidInvalidateLayout(_ sender: NSLayoutManager) {
        invalidations += 1
    }
}

private final class TextEditRecorder: NSObject, NSTextStorageDelegate {
    var editCount = 0

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        editCount += 1
    }
}


@MainActor
struct SelectableDocumentTests {
    @Test func buttonCursorRegionOverridesTextCursorWithoutConsumingClicks() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let region = ControlCursorView(frame: NSRect(x: 100, y: 10, width: 60, height: 30))
        try #require(window.contentView).addSubview(region)
        let previousCursor = NSCursor.current
        defer { previousCursor.set(); region.removeFromSuperview() }
        for type in [NSEvent.EventType.mouseMoved, .cursorUpdate] {
            let event: NSEvent
            if type == .cursorUpdate {
                event = try #require(NSEvent.enterExitEvent(with: type, location: NSPoint(x: 120, y: 20),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            } else {
                event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 120, y: 20),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            }
            NSCursor.iBeam.set()
            #expect(region.handleCursorEvent(event) == nil)
            #expect(NSCursor.current == NSCursor.arrow)
        }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 120, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        #expect(region.handleCursorEvent(click) === click)
        #expect(region.hitTest(NSPoint(x: 120, y: 20)) == nil)
    }

    @Test func buttonCursorRegionLeavesTextAndDetachedControlsAlone() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let region = ControlCursorView(frame: NSRect(x: 100, y: 10, width: 60, height: 30))
        try #require(window.contentView).addSubview(region)
        let previousCursor = NSCursor.current
        defer { previousCursor.set(); region.removeFromSuperview() }
        let outside = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        NSCursor.iBeam.set()
        #expect(region.handleCursorEvent(outside) === outside)
        #expect(NSCursor.current == NSCursor.iBeam)
        let inside = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 120, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        region.isHidden = true
        #expect(region.handleCursorEvent(inside) === inside)
        region.isHidden = false
        // SwiftUI can briefly place a control outside its clipped container
        // while adding results. Empty cursor rects must not reach AppKit.
        region.frame.origin.x = 300
        #expect(region.bounds.intersection(region.visibleRect).isEmpty)
        region.resetCursorRects()
        region.removeFromSuperview()
        #expect(region.handleCursorEvent(inside) === inside)
        #expect(NSCursor.current == NSCursor.iBeam)
    }

    @Test func unchangedSearchResultsKeepTheirDocumentAndLayoutStable() throws {
        let scroll = NativeSearchResultsScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let view = try #require(scroll.documentView as? NativeSearchResultsTextView)
        let items = [TorrentItem(title: "Ubuntu", seeders: 10, leechers: 2, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))]
        view.updateDocument(items: items, peerStates: [:], disclaimer: "Fixture")
        scroll.tile()
        view.layoutSubtreeIfNeeded()
        let frame = view.frame
        let layout = LayoutInvalidationRecorder()
        let edits = TextEditRecorder()
        view.layoutManager?.delegate = layout
        view.textStorage?.delegate = edits
        for _ in 0..<30 {
            view.setViewportWidth(scroll.contentSize.width)
            view.updateDocument(items: items, peerStates: [:], disclaimer: "Fixture")
            view.layoutSubtreeIfNeeded()
            #expect(view.frame == frame)
        }
        #expect(edits.editCount == 0)
        #expect(layout.invalidations == 0)
        #expect(view.frame.height >= scroll.contentSize.height)
    }

    @Test func searchDocumentUpdatesAndResizesLayOutDividersSynchronously() throws {
        let scroll = NativeSearchResultsScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let view = try #require(scroll.documentView as? NativeSearchResultsTextView)
        let items = (1...10).map { index in
            TorrentItem(title: "Result \(index) with a long title that wraps when the window gets narrower",
                seeders: 10, leechers: 2, sizeBytes: 1, magnetLink: "magnet:?xt=urn:btih:" + String(format: "%040x", index))
        }
        scroll.tile()
        view.updateDocument(items: items, peerStates: [:], disclaimer: "Fixture")
        let dividers = view.subviews.compactMap { $0 as? NSBox }
        #expect(dividers.count == 9)
        #expect(dividers.allSatisfy { $0.frame.width > 0 && $0.frame.minY > 0 })
        let initialHeight = view.frame.height
        view.selectAll(nil)
        scroll.frame.size.width = 400
        scroll.tile()
        #expect(view.frame.height > initialHeight)
        #expect(dividers.allSatisfy { $0.frame.width <= 400 })
        #expect(view.selectedRange().length == (view.string as NSString).length)
        view.updateDocument(items: [items[0]], peerStates: [:], disclaimer: "Fixture")
        #expect(view.subviews.compactMap { $0 as? NSBox }.isEmpty)
        #expect(view.frame.height == scroll.contentSize.height)
        scroll.frame.size.height = 500
        scroll.tile()
        #expect(view.frame.height == scroll.contentSize.height)
    }

    @Test func selectedUnicodeTextSurvivesLiveRefreshAndCopiesExactly() throws {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        let old = "Downloading: 9%\nUbuntu 🐧 — español\n↑ 10 seeders\n"
        view.textStorage?.setAttributedString(NSAttributedString(string: old))
        let selected = "Ubuntu 🐧 — español\n↑ 10 seeders"
        view.setSelectedRange((old as NSString).range(of: selected))
        SelectableDocument.update(view, with: NSAttributedString(string: "Downloading: 100%\n" + selected + "\n"))
        let pasteboard = NSPasteboard(name: .init("TorraviaTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes(view.writablePasteboardTypes, owner: nil)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == selected)
        #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == selected)
    }

    @Test func selectionFollowsItsRowWhenIdenticalTitlesReorder() {
        let view = NSTextView()
        let first = UUID(), second = UUID()
        let old = "Same title\nProvider A\nSame title\nProvider B\n"
        let new = "Same title\nProvider B\nSame title\nProvider A\n"
        let rowLength = ("Same title\nProvider A\n" as NSString).length
        view.string = old
        view.setSelectedRange(NSRange(location: 0, length: 10))
        SelectableDocument.update(view, with: NSAttributedString(string: new),
            oldSections: [first: NSRange(location: 0, length: rowLength), second: NSRange(location: rowLength, length: rowLength)],
            newSections: [second: NSRange(location: 0, length: rowLength), first: NSRange(location: rowLength, length: rowLength)])
        #expect(view.selectedRange() == NSRange(location: rowLength, length: 10))
    }

    @Test func removedSelectedRowDoesNotSelectAnotherIdenticalTitle() {
        let view = NSTextView()
        let first = UUID(), second = UUID()
        view.string = "Same title\nSame title\n"
        view.setSelectedRange(NSRange(location: 0, length: 10))
        SelectableDocument.update(view, with: NSAttributedString(string: "Same title\n"),
            oldSections: [first: NSRange(location: 0, length: 11), second: NSRange(location: 11, length: 11)],
            newSections: [second: NSRange(location: 0, length: 11)])
        #expect(view.selectedRange().length == 0)
    }

    @Test func selectionSurvivesAttributeOnlyRefresh() {
        let view = NSTextView()
        view.string = "Online — 1337x"
        let range = NSRange(location: 0, length: 6)
        view.setSelectedRange(range)
        SelectableDocument.update(view, with: NSAttributedString(string: view.string, attributes: [.foregroundColor: NSColor.systemGreen]))
        #expect(view.selectedRange() == range)
    }

    @Test func selectAllRemainsSelectedWhenLiveValuesChange() {
        let view = NSTextView()
        view.string = "1 downloading\nUbuntu — 9.0%\n3 connected peers\n"
        view.selectAll(nil)
        let new = "1 downloading\nUbuntu — 10.0%\n12 connected peers\n"
        SelectableDocument.update(view, with: NSAttributedString(string: new))
        #expect(view.selectedRange() == NSRange(location: 0, length: (new as NSString).length))
    }

    @Test func selectAllDownloadsCopiesSummaryAndSeedingTogether() throws {
        let torrent = TorrentItem(title: "Nintendo Gigaleak 2020-07-24", seeders: 24, leechers: 17, sizeBytes: 2_290_000_000, magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        let download = DownloadsViewModel.Download(torrent: torrent, status: .completed)
        let view = NativeDownloadsTextView()
        SelectableDocument.update(view, with: NativeDownloadsTextView.selectableText(downloads: [download]))
        view.selectAll(nil)
        let pasteboard = NSPasteboard(name: .init("TorraviaTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes(view.writablePasteboardTypes, owner: nil)
        #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        let copied = try #require(pasteboard.string(forType: .string))
        for visibleLabel in ["0 downloading", "1 completed", "0 seeding", torrent.title, "Completed", "Seeding Off"] {
            #expect(copied.contains(visibleLabel))
        }
        #expect(!copied.contains("\u{00A0}"))
        let start = (view.string as NSString).range(of: torrent.title).location
        let end = NSMaxRange((view.string as NSString).range(of: "Seeding Off"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        let selected = (view.string as NSString).substring(with: view.selectedRange())
        #expect(selected.hasPrefix(torrent.title))
        #expect(selected.hasSuffix("Seeding Off"))
    }

    @Test func activeDownloadProgressAndPeersBelongToSameSelectableDocument() {
        let torrent = TorrentItem(title: "Ubuntu 🐧", seeders: 8, leechers: 2, sizeBytes: 100_000_000, magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        let download = DownloadsViewModel.Download(torrent: torrent, progress: 0.425, status: .downloading, numPeers: 3, knownPeerCount: 12)
        let view = NativeDownloadsTextView()
        SelectableDocument.update(view, with: NativeDownloadsTextView.selectableText(downloads: [download]))
        view.selectAll(nil)
        let selected = (view.string as NSString).substring(with: view.selectedRange())
        #expect(selected.contains("1 downloading"))
        #expect(selected.contains("42.5%"))
        #expect(selected.contains("Details…"))
        #expect(!selected.contains(download.peerCountDescription))
        #expect(selected.contains("0 connected seeders · ↓ 0 connected leechers"))
        let seedRange = (view.string as NSString).range(of: "0 connected seeders")
        #expect(view.textStorage?.attribute(.toolTip, at: seedRange.location, effectiveRange: nil) as? String == download.seederCountHelp)
        let peerRange = (view.string as NSString).range(of: "Details…")
        #expect(view.textStorage?.attribute(.link, at: peerRange.location, effectiveRange: nil) as? URL != nil)
    }

    @Test func liveDownloadsKeepTheirActionColumnWithoutRedrawingUnchangedValues() throws {
        let torrent = TorrentItem(title: "Ubuntu 🐧 — a long download title that wraps beside its actions",
                                  seeders: 8, leechers: 2, sizeBytes: 100_000_000,
                                  magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        var download = DownloadsViewModel.Download(torrent: torrent, progress: 0.425,
                                                   status: .downloading, numPeers: 3, knownPeerCount: 12)
        let view = NativeDownloadsTextView()
        view.setViewportWidth(800)
        let widths = [download.id: CGFloat(320)]
        view.updateDocument(downloads: [download], controlWidths: widths)
        let storage = try #require(view.textStorage)
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        let initialHeight = manager.usedRect(for: container).height
        view.setSelectedRange((view.string as NSString).range(of: torrent.title))

        download.numPeers = 4
        download.progress = 0.426
        view.updateDocument(downloads: [download], controlWidths: widths)
        let titleStyle = try #require(storage.attribute(.paragraphStyle,
            at: (view.string as NSString).range(of: torrent.title).location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(titleStyle.tailIndent == -340)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).height == initialHeight)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == torrent.title)
        #expect(view.string.contains("Details…"))
        #expect(!view.string.contains("4 connected"))

        let recorder = TextEditRecorder()
        storage.delegate = recorder
        defer { storage.delegate = nil }
        // These raw values change without changing any displayed text.
        download.progress = 0.42601
        download.uploadedBytes = 1
        view.updateDocument(downloads: [download], controlWidths: widths)
        view.setViewportWidth(800)
        #expect(recorder.editCount == 0)
    }

    @Test func peerPopoverFitsTheUsableScreenAndOpensTowardAvailableSpace() {
        let screen = NSRect(x: 100, y: 60, width: 900, height: 600)
        let nearBottom = NativeDownloadsTextView.peerPopoverPlacement(
            anchor: NSRect(x: 200, y: 90, width: 80, height: 16), screen: screen, isFlipped: true)
        #expect(nearBottom.edge == .minY)
        #expect(nearBottom.size.height == 420)
        let nearTop = NativeDownloadsTextView.peerPopoverPlacement(
            anchor: NSRect(x: 200, y: 630, width: 80, height: 16), screen: screen, isFlipped: true)
        #expect(nearTop.edge == .maxY)
        let small = NativeDownloadsTextView.peerPopoverPlacement(
            anchor: NSRect(x: 50, y: 150, width: 80, height: 16),
            screen: NSRect(x: 0, y: 0, width: 400, height: 320), isFlipped: true)
        #expect(small.size.width == 368)
        #expect(small.size.height <= 136)
    }

    @Test func peerInspectorDoesNotWaitForInactiveTorrentsAndRecoversFromLateResponses() {
        let item = TorrentItem(title: "Ubuntu", seeders: 12, leechers: 4, sizeBytes: 1, magnetLink: "")
        var download = DownloadsViewModel.Download(torrent: item, status: .completed)
        #expect(!download.supportsLivePeerInspection)
        #expect(PeerInspectorView.displayState(download: download, snapshot: nil, timedOut: false) == .inactive)
        download.status = .paused
        #expect(PeerInspectorView.displayState(download: download, snapshot: nil, timedOut: false) == .inactive)
        download.status = .failed
        #expect(PeerInspectorView.displayState(download: download, snapshot: nil, timedOut: false) == .inactive)
        download.status = .downloading
        #expect(PeerInspectorView.displayState(download: download, snapshot: nil, timedOut: false) == .loading)
        #expect(PeerInspectorView.displayState(download: download, snapshot: nil, timedOut: true) == .unavailable)
        let empty = WebTorrentSession.Event.PeerSnapshot(id: download.id.uuidString, availability: 0, peers: [])
        #expect(PeerInspectorView.displayState(download: download, snapshot: empty, timedOut: true) == .empty)
        download.numPeers = 1
        let peer = WebTorrentSession.Event.Peer(address: "192.0.2.1", port: 6881, client: "Test",
            transport: "TCP", direction: "outgoing", sources: [], downloadSpeed: 0, uploadSpeed: 0,
            progress: 1, isSeed: true)
        let connected = WebTorrentSession.Event.PeerSnapshot(id: download.id.uuidString, availability: 1, peers: [peer])
        #expect(PeerInspectorView.displayState(download: download, snapshot: connected, timedOut: true) == .peers)
        download.numPeers = 0
        download.status = .completed
        download.isSeeding = true
        #expect(download.supportsLivePeerInspection)
        #expect(PeerInspectorView.displayState(download: download, snapshot: nil, timedOut: false) == .loading)
        #expect(PeerInspectorView.displayState(download: nil, snapshot: nil, timedOut: false) == .inactive)
    }
}
