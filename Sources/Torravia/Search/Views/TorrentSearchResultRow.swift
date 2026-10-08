import TorraviaSearchCore
//
//  TorrentSearchResultRow.swift
//  Torravia
//
//  Search result row and torrent export/share actions.
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct TorrentRow: View {
    let item: TorrentItem
    var peerCount = SearchPeerCountState()
    var onAdd: () -> Void
    var onError: (String) -> Void

    @EnvironmentObject private var downloadsVM: DownloadsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Label(peerCount.seedersLabel(for: item), systemImage: "arrow.up.circle")
                        .foregroundStyle(.green)
                    Label(peerCount.leechersLabel(for: item), systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                    Text(item.sizeBytes.byteCountFormatted)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if let detail = peerCount.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let source = item.source {
                    HStack(spacing: 4) {
                        Text("Provider:")

                        if let sourceURL = item.sourceURL {
                            Text(source)
                            Text("·")
                            Link(destination: sourceURL) {
                                HStack(spacing: 3) {
                                    Text("View on Website")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .help(sourceURL.absoluteString)
                            .accessibilityLabel("View on Website: \(source)")
                        } else {
                            Text(source)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            TorrentRowActions(item: item, onAdd: onAdd, onError: onError)
                .environmentObject(downloadsVM)
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
    }
}

#if os(macOS)
struct TorrentRowActions: View {
    let item: TorrentItem
    var onAdd: () -> Void
    var onError: (String) -> Void

    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @State private var isExporting = false

    var body: some View {
        HStack(spacing: 10) {
            shareMenu
            if downloadsVM.hasDownload(for: item.magnetLink) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .controlCursor()
            }
        }
        .textSelection(.disabled)
    }
}

private extension TorrentRowActions {
    @ViewBuilder
    var shareMenu: some View {
        Menu {
            if let exportURL = exportSourceURL {
                Button("Export Torrent") {
                    beginExport(from: exportURL)
                }
                .disabled(isExporting)
            }
            Button("Copy Magnet Link") {
                copyToPasteboard(item.magnetLink)
            }
            Button("Copy Torrent Name") {
                copyToPasteboard(item.title)
            }
            if let sourceString = item.sourceURL?.absoluteString {
                Button("Copy Source URL") {
                    copyToPasteboard(sourceString)
                }
            }
        } label: {
            shareMenuLabel
        }
        .menuStyle(.borderlessButton)
        .hideMenuIndicatorIfSupported()
        .help("Share options")
        .accessibilityLabel("Share options")
        .controlSize(.small)
        .disabled(isExporting)
        .controlCursor()
    }

    private var exportSourceURL: URL? {
        guard let url = item.sourceURL else { return nil }
        if url.isFileURL { return url }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private var shareMenuLabel: some View {
        Group {
            if isExporting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }

    private func beginExport(from url: URL) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                let data = try await loadTorrentData(from: url)
                try Task.checkCancellation()
                await MainActor.run {
                    presentSavePanel(with: data)
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    onError("Failed to export torrent: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                isExporting = false
            }
        }
    }

    private func loadTorrentData(from url: URL) async throws -> Data {
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw TorrentExportError.emptyData
            }
            return data
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw HTTPStatusError(url: url, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw TorrentExportError.emptyData
        }
        return data
    }

    @MainActor
    private func presentSavePanel(with data: Data) {
        let panel = NSSavePanel()
        if #available(macOS 11.0, *) {
            if let torrentType = UTType(filenameExtension: "torrent") {
                panel.allowedContentTypes = [torrentType]
            }
        } else {
            panel.allowedFileTypes = ["torrent"]
        }
        panel.nameFieldStringValue = preferredExportFileName()
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try data.write(to: destination, options: [.atomic])
            } catch {
                onError("Failed to export torrent: \(error.localizedDescription)")
            }
        }
    }

    private func preferredExportFileName() -> String {
        ensureTorrentExtension(
            cleanedCandidate(from: item.sourceURL?.lastPathComponent, treatAsFileName: true)
            ?? cleanedCandidate(from: item.title, treatAsFileName: false)
            ?? "download"
        )
    }

    private func ensureTorrentExtension(_ base: String) -> String {
        if base.lowercased().hasSuffix(".torrent") {
            return base
        }
        return base + ".torrent"
    }

    private func cleanedCandidate(from raw: String?, treatAsFileName: Bool) -> String? {
        guard let raw else { return nil }
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if treatAsFileName {
            let components = candidate.components(separatedBy: CharacterSet(charactersIn: "/\\"))
            candidate = components.last ?? candidate
            if let queryIndex = candidate.firstIndex(of: "?") {
                candidate = String(candidate[..<queryIndex])
            }
            if candidate.lowercased().hasSuffix(".torrent") {
                candidate = String(candidate.dropLast(8))
            }
        }

        let disallowed = CharacterSet(charactersIn: "\n\r\t:/\\?%*|\"<>")
        let sanitizedScalars = candidate.unicodeScalars.map { disallowed.contains($0) ? "_" : $0 }
        candidate = String(String.UnicodeScalarView(sanitizedScalars))
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func copyToPasteboard(_ value: String) {
        guard !value.isEmpty else { return }
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    private enum TorrentExportError: LocalizedError {
        case emptyData

        var errorDescription: String? {
            switch self {
            case .emptyData:
                return "The downloaded torrent file was empty."
            }
        }
    }
}
#endif

#if os(macOS)
private extension View {
    @ViewBuilder
    func hideMenuIndicatorIfSupported() -> some View {
        if #available(macOS 13.0, *) {
            self.menuIndicator(.hidden)
        } else {
            self
        }
    }
}
#endif

#if os(macOS)
/// A single AppKit text system for the complete search-results document.
///
/// Keeping every result in one NSTextStorage gives selection the same semantics
/// as TextEdit/Word: one stable anchor, native reverse selection, and selection
/// highlights which remain attached to their characters while the enclosing
/// scroll view moves. Interactive row actions are ordinary hosted controls laid
/// over the reserved trailing margin, outside the text container.
struct NativeSearchResultsView: NSViewRepresentable {
    let items: [TorrentItem]
    @ObservedObject var peerCounts: SearchPeerCountsStore
    let disclaimer: String
    let downloadsVM: DownloadsViewModel
    let onAdd: (TorrentItem) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> NativeSearchResultsScrollView {
        NativeSearchResultsScrollView()
    }

    func updateNSView(_ scrollView: NativeSearchResultsScrollView, context: Context) {
        scrollView.update(
            items: items,
            peerStates: peerCounts.states,
            disclaimer: disclaimer,
            downloadsVM: downloadsVM,
            onAdd: onAdd,
            onError: onError
        )
    }
}

final class NativeSearchResultsScrollView: NSScrollView {
    private let resultsTextView = NativeSearchResultsTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .legacy
        documentView = resultsTextView
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func tile() {
        super.tile()
        resultsTextView.setViewportWidth(contentSize.width)
    }

    func update(
        items: [TorrentItem],
        peerStates: [String: SearchPeerCountState],
        disclaimer: String,
        downloadsVM: DownloadsViewModel,
        onAdd: @escaping (TorrentItem) -> Void,
        onError: @escaping (String) -> Void
    ) {
        resultsTextView.update(
            items: items,
            peerStates: peerStates,
            disclaimer: disclaimer,
            downloadsVM: downloadsVM,
            onAdd: onAdd,
            onError: onError
        )
        resultsTextView.setViewportWidth(contentSize.width)
    }
}

final class NativeSearchResultsTextView: NSTextView, NSTextViewDelegate {
    private struct RowLayout {
        let item: TorrentItem
        let characterRange: NSRange
    }

    private let horizontalInset: CGFloat = 16
    private let topInset: CGFloat = 12
    private let actionMargin: CGFloat = 100
    private var rowLayouts: [RowLayout] = []
    private var actionViews: [UUID: NSHostingView<AnyView>] = [:]
    private var actionItems: [UUID: TorrentItem] = [:]
    private var dividerViews: [NSBox] = []
    private var contentSignature = ""
    private var viewportWidth: CGFloat = 0
    private var isUpdatingGeometry = false
    private var geometryNeedsUpdate = true
    private var lastViewportSize = NSSize.zero
    private var cursorEventMonitor: Any?
    private weak var cursorWindow: NSWindow?
    private var previousMouseMovedEvents = false

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        allowsUndo = false
        isHorizontallyResizable = false
        // This view owns its document height. NSTextView's automatic resizing
        // otherwise competes with the minimum viewport height during layout.
        isVerticallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minSize = .zero
        textContainerInset = NSSize(width: horizontalInset, height: topInset)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        delegate = self
        usesFindBar = true
        setAccessibilityLabel("Search results")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + actionViews.values
            .sorted { $0.frame.minY < $1.frame.minY }
            .flatMap { $0.accessibilityChildren() ?? [$0] }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoringCursorEvents()
        guard let window else { return }

        cursorWindow = window
        previousMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        cursorEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .cursorUpdate]
        ) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            let hitView = window.contentView?.hitTest(event.locationInWindow)
            guard self.contains(hitView) else { return event }

            let point = self.convert(event.locationInWindow, from: nil)
            self.applyCursor(at: point)
            // Keep the result authoritative. NSTextView and hosted SwiftUI
            // labels otherwise restore the I-beam over controls and padding.
            return nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopMonitoringCursorEvents()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        stopMonitoringCursorEvents()
    }

    override func layout() {
        super.layout()
        updateOverlayGeometry()
    }

    override func resetCursorRects() {
        discardCursorRects()
        selectableTextRects.forEach { addCursorRect($0, cursor: .iBeam) }
        linkRects.forEach { addCursorRect($0, cursor: .pointingHand) }
        actionRects.forEach { addCursorRect($0, cursor: .arrow) }
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    func setViewportWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        guard abs(viewportWidth - width) > 0.5 else {
            updateOverlayGeometry()
            return
        }
        viewportWidth = width
        let documentWidth = max(width, 240)
        let availableTextWidth = max(documentWidth - (horizontalInset * 2) - actionMargin, 140)
        textContainer?.containerSize = NSSize(width: availableTextWidth, height: CGFloat.greatestFiniteMagnitude)
        if abs(frame.width - documentWidth) > 0.5 {
            frame.size.width = documentWidth
        }
        geometryNeedsUpdate = true
        updateOverlayGeometry()
    }

    func update(
        items: [TorrentItem],
        peerStates: [String: SearchPeerCountState],
        disclaimer: String,
        downloadsVM: DownloadsViewModel,
        onAdd: @escaping (TorrentItem) -> Void,
        onError: @escaping (String) -> Void
    ) {
        updateDocument(items: items, peerStates: peerStates, disclaimer: disclaimer)

        let currentIDs = Set(items.map(\.id))
        for id in actionViews.keys.filter({ !currentIDs.contains($0) }) {
            actionViews.removeValue(forKey: id)?.removeFromSuperview()
            actionItems[id] = nil
        }

        for item in items where actionItems[item.id] != item {
            let root = AnyView(
                TorrentRowActions(
                    item: item,
                    onAdd: { onAdd(item) },
                    onError: onError
                )
                .environmentObject(downloadsVM)
            )
            if let existing = actionViews[item.id] {
                existing.rootView = root
            } else {
                let hosting = NSHostingView(rootView: root)
                hosting.translatesAutoresizingMaskIntoConstraints = true
                hosting.frame.size = NSSize(width: 82, height: 44)
                addSubview(hosting)
                actionViews[item.id] = hosting
            }
            actionItems[item.id] = item
            geometryNeedsUpdate = true
        }

        updateOverlayGeometry()
    }

    func updateDocument(items: [TorrentItem], peerStates: [String: SearchPeerCountState], disclaimer: String) {
        let signature = items.map { item in
            let peer = TrackerPeerScraper.infoHash(in: item.magnetLink).flatMap { peerStates[$0] } ?? SearchPeerCountState()
            return [
                item.id.uuidString,
                item.title,
                String(item.seeders),
                String(item.leechers),
                peer.seedersLabel(for: item),
                peer.leechersLabel(for: item),
                peer.detail ?? "",
                String(item.sizeBytes),
                item.source ?? "",
                item.sourceURL?.absoluteString ?? ""
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}") + "\u{1d}" + disclaimer

        if signature != contentSignature {
            contentSignature = signature
            let oldSections = Dictionary(uniqueKeysWithValues: rowLayouts.map { ($0.item.id, $0.characterRange) })
            let document = Self.makeDocument(items: items, peerStates: peerStates, disclaimer: disclaimer)
            rowLayouts = document.rows
            SelectableDocument.update(self, with: document.text,
                oldSections: oldSections,
                newSections: Dictionary(uniqueKeysWithValues: document.rows.map { ($0.item.id, $0.characterRange) }))
            geometryNeedsUpdate = true
        }
        updateOverlayGeometry()
    }

    private func updateOverlayGeometry() {
        guard !isUpdatingGeometry,
              let layoutManager,
              let textContainer,
              viewportWidth > 0 else { return }
        let viewportSize = enclosingScrollView?.contentSize ?? .zero
        guard geometryNeedsUpdate || viewportSize != lastViewportSize else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        geometryNeedsUpdate = false
        lastViewportSize = viewportSize

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let requiredHeight = max(usedRect.maxY + (topInset * 2), enclosingScrollView?.contentSize.height ?? 0)
        if abs(frame.height - requiredHeight) > 0.5 {
            frame.size.height = requiredHeight
        }

        while dividerViews.count < max(rowLayouts.count - 1, 0) {
            let divider = NSBox()
            divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = true
            addSubview(divider, positioned: .below, relativeTo: nil)
            dividerViews.append(divider)
        }
        while dividerViews.count > max(rowLayouts.count - 1, 0) {
            dividerViews.removeLast().removeFromSuperview()
        }

        for (index, row) in rowLayouts.enumerated() {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: row.characterRange, actualCharacterRange: nil)
            var rowRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rowRect.origin.x += textContainerOrigin.x
            rowRect.origin.y += textContainerOrigin.y

            if let actionView = actionViews[row.item.id] {
                let frame = NSRect(
                    x: max(bounds.width - actionMargin + 8, horizontalInset),
                    y: max(rowRect.minY - 5, topInset),
                    width: 82,
                    height: 44
                )
                if actionView.frame != frame { actionView.frame = frame }
            }

            if index < dividerViews.count {
                let frame = NSRect(
                    x: horizontalInset,
                    y: rowRect.maxY + 8,
                    width: max(bounds.width - (horizontalInset * 2), 1),
                    height: 1
                )
                if dividerViews[index].frame != frame { dividerViews[index].frame = frame }
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    private var actionRects: [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)

        let zoneStartX = max(bounds.maxX - actionMargin - horizontalInset, bounds.minX)
        return rowLayouts.compactMap { row in
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: row.characterRange,
                actualCharacterRange: nil
            )
            var rowRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rowRect.origin.x += textContainerOrigin.x
            rowRect.origin.y += textContainerOrigin.y

            let zone = NSRect(
                x: zoneStartX,
                y: rowRect.minY - 8,
                width: bounds.maxX - zoneStartX,
                height: rowRect.height + 16
            ).intersection(bounds)
            return zone.isEmpty ? nil : zone
        }
    }

    private var selectableTextRects: [NSRect] {
        guard let layoutManager, let textContainer, let textStorage else { return [] }
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] _, usedRect, _, lineGlyphRange, _ in
            guard let self else { return }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            guard self.containsVisibleText(in: characterRange, textStorage: textStorage) else { return }

            var rect = usedRect
            rect.origin.x += self.textContainerOrigin.x
            rect.origin.y += self.textContainerOrigin.y
            rect = rect.intersection(self.bounds)
            if !rect.isEmpty {
                rects.append(rect)
            }
        }
        return rects
    }

    private var linkRects: [NSRect] {
        guard let layoutManager, let textContainer, let textStorage else { return [] }
        layoutManager.ensureLayout(for: textContainer)

        var rects: [NSRect] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.link, in: fullRange) { value, characterRange, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += self.textContainerOrigin.x
            rect.origin.y += self.textContainerOrigin.y
            rect = rect.intersection(self.bounds)
            if !rect.isEmpty {
                rects.append(rect)
            }
        }
        return rects
    }

    private func containsVisibleText(in range: NSRange, textStorage: NSTextStorage) -> Bool {
        var containsVisibleText = false
        textStorage.enumerateAttribute(.foregroundColor, in: range) { value, attributeRange, stop in
            let text = (textStorage.string as NSString).substring(with: attributeRange)
            guard text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else { return }
            if let color = value as? NSColor, color.alphaComponent <= 0.01 {
                return
            }
            containsVisibleText = true
            stop.pointee = true
        }
        return containsVisibleText
    }

    private func applyCursor(at point: NSPoint) {
        if actionRects.contains(where: { $0.contains(point) }) {
            NSCursor.arrow.set()
        } else if linkRects.contains(where: { $0.contains(point) }) {
            NSCursor.pointingHand.set()
        } else if selectableTextRects.contains(where: { $0.contains(point) }) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func contains(_ view: NSView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current === self { return true }
            candidate = current.superview
        }
        return false
    }

    private func stopMonitoringCursorEvents() {
        if let cursorEventMonitor {
            NSEvent.removeMonitor(cursorEventMonitor)
            self.cursorEventMonitor = nil
        }
        if let cursorWindow {
            cursorWindow.acceptsMouseMovedEvents = previousMouseMovedEvents
        }
        cursorWindow = nil
    }

    private static func makeDocument(items: [TorrentItem], peerStates: [String: SearchPeerCountState], disclaimer: String) -> (text: NSAttributedString, rows: [RowLayout]) {
        let result = NSMutableAttributedString(string: "")
        var rows: [RowLayout] = []

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineBreakMode = .byWordWrapping
        titleParagraph.paragraphSpacing = 4

        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.lineBreakMode = .byWordWrapping
        detailParagraph.paragraphSpacing = 4

        let sourceParagraph = NSMutableParagraphStyle()
        sourceParagraph.lineBreakMode = .byWordWrapping
        sourceParagraph.paragraphSpacing = 18

        for item in items {
            let peer = TrackerPeerScraper.infoHash(in: item.magnetLink).flatMap { peerStates[$0] } ?? SearchPeerCountState()
            let start = result.length
            result.append(NSAttributedString(
                string: item.title + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: titleParagraph
                ]
            ))

            result.append(NSAttributedString(
                string: "↑ " + peer.seedersLabel(for: item),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.systemGreen,
                    .paragraphStyle: detailParagraph
                ]
            ))
            result.append(NSAttributedString(
                string: "    ↓ " + peer.leechersLabel(for: item),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.systemOrange,
                    .paragraphStyle: detailParagraph
                ]
            ))
            result.append(NSAttributedString(
                string: "    \(item.sizeBytes.byteCountFormatted)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: detailParagraph
                ]
            ))

            let sourceAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: sourceParagraph
            ]
            var checkAttributes = sourceAttributes
            let checkStyle = sourceParagraph.mutableCopy() as! NSMutableParagraphStyle
            checkStyle.paragraphSpacing = 4
            checkAttributes[.paragraphStyle] = checkStyle
            result.append(NSAttributedString(string: (peer.detail ?? "Tracker estimate unknown") + "\n", attributes: checkAttributes))
            result.append(NSAttributedString(string: "Provider: ", attributes: sourceAttributes))
            if let source = item.source {
                result.append(NSAttributedString(string: source, attributes: sourceAttributes))
                if let sourceURL = item.sourceURL {
                    result.append(NSAttributedString(string: " · ", attributes: sourceAttributes))
                    var linkAttributes = sourceAttributes
                    linkAttributes[.link] = sourceURL
                    linkAttributes[.toolTip] = sourceURL.absoluteString
                    result.append(NSAttributedString(
                        string: "View on Website ↗",
                        attributes: linkAttributes
                    ))
                }
                result.append(NSAttributedString(string: "\n", attributes: sourceAttributes))
            } else {
                result.append(NSAttributedString(string: "Unavailable\n", attributes: sourceAttributes))
            }
            rows.append(RowLayout(item: item, characterRange: NSRange(location: start, length: result.length - start)))
        }

        result.append(NSAttributedString(
            string: disclaimer,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        ))
        return (result, rows)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }

}
#endif
