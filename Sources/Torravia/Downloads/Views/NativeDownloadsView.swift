//
//  NativeDownloadsView.swift
//  Torravia
//
//  A single selectable AppKit document for the Downloads screen.
//

#if os(macOS)
import AppKit
import SwiftUI

struct NativeDownloadsView: NSViewRepresentable {
    let downloads: [DownloadsViewModel.Download]
    let downloadsVM: DownloadsViewModel
    let onPause: (DownloadsViewModel.Download) -> Void
    let onResume: (DownloadsViewModel.Download) -> Void
    let onForceStart: (DownloadsViewModel.Download) -> Void
    let onCancel: (DownloadsViewModel.Download) -> Void
    let onRedownload: (DownloadsViewModel.Download) -> Void
    let onError: (String) -> Void
    let onPreview: (URL) -> Void
    let onRelocate: (DownloadsViewModel.Download, URL, Data?) -> Void
    let onSetSeeding: (DownloadsViewModel.Download, Bool) -> Void

    func makeNSView(context: Context) -> NativeDownloadsScrollView {
        NativeDownloadsScrollView()
    }

    func updateNSView(_ scrollView: NativeDownloadsScrollView, context: Context) {
        scrollView.update(
            downloads: downloads,
            downloadsVM: downloadsVM,
            onPause: onPause,
            onResume: onResume,
            onForceStart: onForceStart,
            onCancel: onCancel,
            onRedownload: onRedownload,
            onError: onError,
            onPreview: onPreview,
            onRelocate: onRelocate,
            onSetSeeding: onSetSeeding
        )
    }
}

final class NativeDownloadsScrollView: NSScrollView {
    private let downloadsTextView = NativeDownloadsTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .legacy
        documentView = downloadsTextView
    }

    required init?(coder: NSCoder) { nil }

    override func tile() {
        super.tile()
        downloadsTextView.setViewportWidth(contentSize.width)
    }

    func update(
        downloads: [DownloadsViewModel.Download],
        downloadsVM: DownloadsViewModel,
        onPause: @escaping (DownloadsViewModel.Download) -> Void,
        onResume: @escaping (DownloadsViewModel.Download) -> Void,
        onForceStart: @escaping (DownloadsViewModel.Download) -> Void,
        onCancel: @escaping (DownloadsViewModel.Download) -> Void,
        onRedownload: @escaping (DownloadsViewModel.Download) -> Void,
        onError: @escaping (String) -> Void,
        onPreview: @escaping (URL) -> Void,
        onRelocate: @escaping (DownloadsViewModel.Download, URL, Data?) -> Void,
        onSetSeeding: @escaping (DownloadsViewModel.Download, Bool) -> Void
    ) {
        downloadsTextView.update(
            downloads: downloads,
            downloadsVM: downloadsVM,
            onPause: onPause,
            onResume: onResume,
            onForceStart: onForceStart,
            onCancel: onCancel,
            onRedownload: onRedownload,
            onError: onError,
            onPreview: onPreview,
            onRelocate: onRelocate,
            onSetSeeding: onSetSeeding
        )
        downloadsTextView.setViewportWidth(contentSize.width)
    }
}

final class NativeDownloadsTextView: NSTextView, NSTextViewDelegate {
    private struct RowLayout {
        let download: DownloadsViewModel.Download
        let characterRange: NSRange
        let controlsRange: NSRange
        let seedingRange: NSRange?
        let progressRange: NSRange?
    }

    private let horizontalInset: CGFloat = 16
    private let topInset: CGFloat = 12
    private var rowLayouts: [RowLayout] = []
    private var controlViews: [UUID: NSHostingView<AnyView>] = [:]
    private var dividerViews: [NSBox] = []
    private let summaryDivider = NSBox()
    private var seedingControls: [UUID: NSButton] = [:]
    private var progressIndicators: [UUID: NSProgressIndicator] = [:]
    private var seedingHandlers: [UUID: (Bool) -> Void] = [:]
    private var actionHandlers: [String: (Int) -> Void] = [:]
    private var peerPopover: NSPopover?
    private var displayedDocument: NSAttributedString?
    private var viewportWidth: CGFloat = 0
    private var geometryUpdateScheduled = false
    private var isUpdatingGeometry = false
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
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minSize = .zero
        textContainerInset = NSSize(width: horizontalInset, height: topInset)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        usesFindBar = true
        setAccessibilityLabel("Transfers")
        delegate = self
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        summaryDivider.boxType = .separator
        addSubview(summaryDivider)
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityChildren() -> [Any]? {
        // NSTextView normally exposes only its text. Include the overlaid
        // labels and actions so they retain native accessibility and focus.
        (super.accessibilityChildren() ?? []) + controlViews.values
            .sorted { $0.frame.minY < $1.frame.minY }
            .flatMap { $0.accessibilityChildren() ?? [$0] } + Array(seedingControls.values)
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

            let localPoint = self.convert(event.locationInWindow, from: nil)
            self.applyCursor(at: localPoint)
            // Keep this decision authoritative. NSTextView and SwiftUI's
            // hosted button labels otherwise restore the I-beam over actions.
            // Clicks, drags and tracking-area events still pass through.
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
        scheduleGeometryUpdate()
    }

    override func resetCursorRects() {
        discardCursorRects()
        selectableTextRects.forEach { addCursorRect($0, cursor: .iBeam) }
        linkRects.forEach { addCursorRect($0, cursor: .pointingHand) }
        controlRects.forEach { addCursorRect($0, cursor: .arrow) }
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func applyCursor(at point: NSPoint) {
        if controlRects.contains(where: { $0.contains(point) }) {
            NSCursor.arrow.set()
        } else if linkRects.contains(where: { $0.contains(point) }) {
            NSCursor.pointingHand.set()
        } else if selectableTextRects.contains(where: { $0.contains(point) }) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func setViewportWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        guard abs(viewportWidth - width) > 0.5 else { return }
        viewportWidth = width
        let documentWidth = max(width, 480)
        let containerWidth = max(documentWidth - horizontalInset * 2, 320)
        if textContainer?.containerSize.width != containerWidth {
            textContainer?.containerSize = NSSize(
                width: containerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        if abs(frame.width - documentWidth) > 0.5 {
            frame.size.width = documentWidth
        }
        scheduleGeometryUpdate()
    }

    func update(
        downloads: [DownloadsViewModel.Download],
        downloadsVM: DownloadsViewModel,
        onPause: @escaping (DownloadsViewModel.Download) -> Void,
        onResume: @escaping (DownloadsViewModel.Download) -> Void,
        onForceStart: @escaping (DownloadsViewModel.Download) -> Void,
        onCancel: @escaping (DownloadsViewModel.Download) -> Void,
        onRedownload: @escaping (DownloadsViewModel.Download) -> Void,
        onError: @escaping (String) -> Void,
        onPreview: @escaping (URL) -> Void,
        onRelocate: @escaping (DownloadsViewModel.Download, URL, Data?) -> Void,
        onSetSeeding: @escaping (DownloadsViewModel.Download, Bool) -> Void
    ) {
        let currentIDs = Set(downloads.map(\.id))
        for id in controlViews.keys.filter({ !currentIDs.contains($0) }) {
            controlViews.removeValue(forKey: id)?.removeFromSuperview()
        }

        for download in downloads where controlViews[download.id] == nil {
            let root = AnyView(
                DownloadRow(
                    download: download,
                    onPause: { onPause(download) },
                    onResume: { onResume(download) },
                    onForceStart: { onForceStart(download) },
                    onCancel: { onCancel(download) },
                    onRedownload: { onRedownload(download) },
                    onError: onError,
                    onPreview: onPreview,
                    onRelocate: { url, bookmark in onRelocate(download, url, bookmark) },
                    onSetSeeding: { enabled in onSetSeeding(download, enabled) }
                )
                .environmentObject(downloadsVM)
                .downloadRowControlsOnly()
            )
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.translatesAutoresizingMaskIntoConstraints = true
            addSubview(hosting)
            controlViews[download.id] = hosting
        }

        // Apply the action column before installing new text. Resetting its
        // paragraph widths and fixing them on the next run-loop turn makes
        // every live transfer update briefly rewrap the entire list.
        updateDocument(downloads: downloads, controlWidths: controlViews.mapValues {
            $0.intrinsicContentSize.width
        })

        for id in seedingControls.keys.filter({ id in !downloads.contains { $0.id == id && $0.status == .completed } }) {
            seedingControls.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in progressIndicators.keys.filter({ id in !downloads.contains { $0.id == id && $0.status != .completed } }) {
            progressIndicators.removeValue(forKey: id)?.removeFromSuperview()
        }
        actionHandlers.removeAll()
        seedingHandlers.removeAll()
        for download in downloads {
            if download.status == .completed {
                let checkbox = seedingControls[download.id] ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(seedingChanged(_:)))
                checkbox.controlSize = .small
                checkbox.identifier = NSUserInterfaceItemIdentifier(download.id.uuidString)
                checkbox.setAccessibilityLabel("Seeding")
                let state: NSControl.StateValue = download.isSeeding ? .on : .off
                if checkbox.state != state { checkbox.state = state }
                if checkbox.superview == nil { addSubview(checkbox) }
                seedingControls[download.id] = checkbox
                seedingHandlers[download.id] = { onSetSeeding(download, $0) }
            } else {
                let progress: NSProgressIndicator
                if let existing = progressIndicators[download.id] {
                    progress = existing
                } else {
                    progress = NSProgressIndicator()
                    progress.style = .bar
                    progress.isIndeterminate = false
                    progress.minValue = 0
                    progress.maxValue = 1
                    addSubview(progress)
                }
                if progress.doubleValue != download.displayProgress {
                    progress.doubleValue = download.displayProgress
                }
                progressIndicators[download.id] = progress
            }
            actionHandlers[Self.actionURL("peers", download.id).absoluteString] = { [weak self] index in
                guard let self, let manager = layoutManager, let container = textContainer else { return }
                let glyph = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyph, in: container)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                peerPopover?.close()
                let popover = NSPopover()
                popover.behavior = .transient
                let anchor = window?.convertToScreen(convert(rect, to: nil)) ?? rect
                let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
                let placement = Self.peerPopoverPlacement(anchor: anchor, screen: screen, isFlipped: isFlipped)
                popover.contentViewController = NSHostingController(rootView:
                    PeerInspectorView(downloadID: download.id, title: download.title,
                                      maximumSize: placement.size,
                                      onContentSizeChange: { [weak self, weak popover] size in
                        DispatchQueue.main.async {
                            guard let self, let popover, popover.isShown else { return }
                            // Keep the arrow attached to its link when the content shrinks
                            // or grows after the first SwiftUI layout pass.
                            popover.contentSize = size
                            popover.show(relativeTo: rect, of: self, preferredEdge: placement.edge)
                        }
                    }).environmentObject(downloadsVM))
                peerPopover = popover
                popover.show(relativeTo: rect, of: self, preferredEdge: placement.edge)
            }
        }

        updateOverlayGeometry()
    }

    @objc private func seedingChanged(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        seedingHandlers[id]?(sender.state == .on)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, let action = actionHandlers[url.absoluteString] else { return false }
        action(charIndex)
        return true
    }

    private static func actionURL(_ action: String, _ id: UUID) -> URL {
        URL(string: "torravia-action://\(action)/\(id.uuidString)")!
    }

    static func peerPopoverPlacement(anchor: NSRect, screen: NSRect, isFlipped: Bool) -> (size: CGSize, edge: NSRectEdge) {
        let above = max(screen.maxY - anchor.maxY, 0)
        let below = max(anchor.minY - screen.minY, 0)
        let opensAbove = above > below
        let size = CGSize(width: min(480, max(screen.width - 32, 1)),
                          height: min(420, max(max(above, below) - 24, 1)))
        let edge: NSRectEdge = opensAbove == isFlipped ? .minY : .maxY
        return (size, edge)
    }

    func updateDocument(downloads: [DownloadsViewModel.Download], controlWidths: [UUID: CGFloat]) {
        let oldSections = Dictionary(uniqueKeysWithValues: rowLayouts.map { ($0.download.id, $0.characterRange) })
        let document = Self.makeDocument(downloads: downloads, controlWidths: controlWidths)
        rowLayouts = document.rows
        // AppKit can decorate links in the live text storage. Compare against
        // our last rendered document so those attributes don't force another
        // replacement when raw metrics change but their display stays equal.
        guard displayedDocument?.isEqual(to: document.text) != true else { return }
        displayedDocument = document.text
        SelectableDocument.update(self, with: document.text,
            oldSections: oldSections,
            newSections: Dictionary(uniqueKeysWithValues: document.rows.map { ($0.download.id, $0.characterRange) }))
    }

    static func selectableText(downloads: [DownloadsViewModel.Download], controlWidths: [UUID: CGFloat] = [:]) -> NSAttributedString {
        makeDocument(downloads: downloads, controlWidths: controlWidths).text
    }

    private func scheduleGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            geometryUpdateScheduled = false
            updateOverlayGeometry()
        }
    }

    private func updateOverlayGeometry() {
        guard !isUpdatingGeometry,
              let layoutManager,
              let textContainer,
              viewportWidth > 0 else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }

        // Reserve exactly the native controls' intrinsic width. Text wraps in
        // the remaining column, keeping long titles clear of every hit target.
        var controlSizes: [UUID: NSSize] = [:]
        for row in rowLayouts {
            guard let hosting = controlViews[row.download.id] else { continue }
            let size = hosting.intrinsicContentSize
            controlSizes[row.download.id] = size
            var updates: [(NSRange, NSMutableParagraphStyle)] = []
            textStorage?.enumerateAttribute(.paragraphStyle, in: row.controlsRange) { value, range, _ in
                guard let style = value as? NSParagraphStyle, style.tailIndent != -(size.width + 20),
                      let replacement = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                replacement.tailIndent = -(size.width + 20)
                updates.append((range, replacement))
            }
            for (range, style) in updates {
                textStorage?.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let requiredHeight = max(usedRect.maxY + topInset * 2, enclosingScrollView?.contentSize.height ?? 0)
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

        let summaryRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: textContainer)
        summaryDivider.frame = NSRect(x: horizontalInset, y: summaryRect.maxY + textContainerOrigin.y + 8,
                                     width: bounds.width - horizontalInset * 2, height: 1)
        for (index, row) in rowLayouts.enumerated() {
            let controlsGlyphs = layoutManager.glyphRange(forCharacterRange: row.controlsRange, actualCharacterRange: nil)
            let size = controlSizes[row.download.id] ?? .zero
            let firstCenter = visibleTextCenter(forGlyphAt: controlsGlyphs.location)
            let lastCenter = visibleTextCenter(forGlyphAt: NSMaxRange(controlsGlyphs) - 1)
            let actionY = (firstCenter + lastCenter - size.height) / 2
            controlViews[row.download.id]?.frame = NSRect(
                x: bounds.width - horizontalInset - size.width,
                y: actionY,
                width: size.width,
                height: size.height
            )
            if let range = row.seedingRange, let checkbox = seedingControls[row.download.id] {
                let glyph = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil).location
                checkbox.frame = NSRect(x: horizontalInset, y: visibleTextCenter(forGlyphAt: glyph) - 9, width: 18, height: 18)
            }
            if let range = row.progressRange, let progress = progressIndicators[row.download.id] {
                let glyph = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil).location
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                progress.frame = NSRect(x: horizontalInset, y: line.midY + textContainerOrigin.y - 3, width: bounds.width - horizontalInset * 2, height: 6)
            }
            if index < dividerViews.count {
                let rowGlyphs = layoutManager.glyphRange(forCharacterRange: row.characterRange, actualCharacterRange: nil)
                let rowRect = layoutManager.boundingRect(forGlyphRange: rowGlyphs, in: textContainer)
                dividerViews[index].frame = NSRect(
                    x: horizontalInset,
                    y: rowRect.maxY + textContainerOrigin.y - 7,
                    width: max(bounds.width - horizontalInset * 2, 1),
                    height: 1
                )
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    private func visibleTextCenter(forGlyphAt glyph: Int) -> CGFloat {
        guard let manager = layoutManager, let storage = textStorage else { return 0 }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let character = manager.characterIndexForGlyph(at: glyph)
        let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
        // A glyph bounding box includes fixed line height and paragraph space.
        // Use the baseline and cap height to align controls with visible text.
        return line.minY + manager.location(forGlyphAt: glyph).y - font.capHeight / 2 + textContainerOrigin.y
    }

    private var controlRects: [NSRect] {
        // The checkbox overlaps the selectable seeding line too. Give both
        // native and hosted controls priority over the document's text cursor.
        let controls: [NSView] = Array(controlViews.values) + Array(seedingControls.values)
        return controls.compactMap { control in
            let converted = convert(control.bounds, from: control).intersection(bounds)
            return converted.isEmpty ? nil : converted
        }
    }

    private var linkRects: [NSRect] {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return [] }
        var rects: [NSRect] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rects.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
        }
        return rects
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

    private static func makeDocument(downloads: [DownloadsViewModel.Download], controlWidths: [UUID: CGFloat]) -> (text: NSAttributedString, rows: [RowLayout]) {
        let result = NSMutableAttributedString()
        var rows: [RowLayout] = []

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byWordWrapping
        titleStyle.paragraphSpacing = 5
        let detailStyle = NSMutableParagraphStyle()
        detailStyle.lineBreakMode = .byWordWrapping
        detailStyle.paragraphSpacing = 5
        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.minimumLineHeight = 24
        summaryStyle.paragraphSpacing = 24
        let downloading = downloads.filter { $0.status == .downloading }.count
        let completed = downloads.filter { $0.status == .completed }.count
        let seeding = downloads.filter { $0.isSeeding }.count
        result.append(NSAttributedString(string: "↓ \(downloading) downloading    ✓ \(completed) completed    ↑ \(seeding) seeding\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: summaryStyle
        ]))

        for download in downloads {
            let rowStart = result.length
            result.append(NSAttributedString(
                string: download.title + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: titleStyle
                ]
            ))

            let size = download.hasResolvedSize ? " · \(download.resolvedSizeBytes.byteCountFormatted)" : ""
            let category = download.category.isEmpty ? "" : " · \(download.category)"
            let tags = download.tags.prefix(3).map { "#\($0)" }.joined(separator: " ")
            let tagSuffix = tags.isEmpty ? "" : " · \(tags)"
            let forced = download.isForceStarted ? " · Forced" : ""
            let policy = download.seedingPolicyDescription.map { " · \($0)" } ?? ""
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: detailStyle
            ]
            result.append(NSAttributedString(
                string: "↑ \(download.compactSeederDescription)",
                attributes: [
                    .toolTip: download.seederCountHelp,
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.systemGreen,
                    .paragraphStyle: detailStyle
                ]
            ))
            result.append(NSAttributedString(
                string: " · ↓ \(download.compactLeecherDescription)",
                attributes: [
                    .toolTip: download.leecherCountHelp,
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.systemOrange,
                    .paragraphStyle: detailStyle
                ]
            ))
            result.append(NSAttributedString(
                string: "\(size)\(category)\(tagSuffix)\(forced)\(policy)\n",
                attributes: detailAttributes
            ))

            if let error = download.errorMessage {
                result.append(NSAttributedString(
                    string: error + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: download.status == .failed ? NSColor.systemRed : NSColor.systemOrange,
                        .paragraphStyle: detailStyle
                    ]
                ))
            }

            var activity: [String] = [download.activityStatusDescription]
            if download.status != .completed { activity.append(String(format: "%.1f%%", download.displayProgressPercentage)) }
            if (download.status == .downloading && !download.isRestoringProgress) || download.isSeeding {
                activity.append("↓ \(download.speedBytesPerSec.transferRateFormatted)/s")
                activity.append("↑ \(download.uploadSpeedBytesPerSec.transferRateFormatted)/s")
            }
            if let eta = download.etaSeconds, download.status != .completed {
                activity.append("ETA \(eta.timeSpanFormatted)")
            }
            if download.isSeeding, download.uploadedBytes > 0 {
                activity.append("Uploaded \(download.uploadedBytes.byteCountFormatted)")
            }
            result.append(NSAttributedString(
                string: activity.joined(separator: " · ") + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: detailStyle
                ]
            ))

            var peerAttributes = detailAttributes
            peerAttributes[.link] = actionURL("peers", download.id)
            peerAttributes[.toolTip] = "Show torrent names, connected peers, and discovery details"
            result.append(NSAttributedString(string: "Details…\n", attributes: peerAttributes))

            let controlsRange = NSRange(location: rowStart, length: result.length - rowStart)
            if let width = controlWidths[download.id] {
                var styles: [(NSRange, NSMutableParagraphStyle)] = []
                result.enumerateAttribute(.paragraphStyle, in: controlsRange) { value, range, _ in
                    guard let style = value as? NSParagraphStyle,
                          let replacement = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                    replacement.tailIndent = -(width + 20)
                    styles.append((range, replacement))
                }
                for (range, style) in styles {
                    result.addAttribute(.paragraphStyle, value: style, range: range)
                }
            }
            var seedingRange: NSRange?
            if download.status == .completed || download.isSeeding {
                let seedingStyle = NSMutableParagraphStyle()
                seedingStyle.minimumLineHeight = 24
                seedingStyle.headIndent = download.status == .completed ? 24 : 0
                seedingStyle.firstLineHeadIndent = seedingStyle.headIndent
                let label = download.isSeeding ? download.seedingDurationFormatted.map { "Seeding \($0)" } ?? "Seeding" : "Seeding Off"
                seedingRange = NSRange(location: result.length, length: (label as NSString).length)
                result.append(NSAttributedString(string: label + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: seedingStyle
                ]))
            }
            var progressRange: NSRange?
            if download.status != .completed {
                let progressStyle = NSMutableParagraphStyle()
                progressStyle.minimumLineHeight = 16
                progressStyle.maximumLineHeight = 16
                progressRange = NSRange(location: result.length, length: 1)
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: progressStyle, .font: NSFont.systemFont(ofSize: 12)]))
            }
            let spacingStyle = NSMutableParagraphStyle()
            spacingStyle.minimumLineHeight = 18
            spacingStyle.maximumLineHeight = 18
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: spacingStyle, .font: NSFont.systemFont(ofSize: 12)]))
            rows.append(RowLayout(
                download: download,
                characterRange: NSRange(location: rowStart, length: result.length - rowStart),
                controlsRange: controlsRange,
                seedingRange: seedingRange,
                progressRange: progressRange
            ))
        }
        return (result, rows)
    }

}

#endif
