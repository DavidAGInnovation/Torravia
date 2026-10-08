#if os(macOS)
import AppKit
import Combine

@MainActor
final class UnifiedSettingsDocumentView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    private struct Placement {
        let range: NSRange
        let view: NSView
        let x: CGFloat
        let width: CGFloat
        let height: CGFloat
        let yOffset: CGFloat
    }

    struct ProviderLink {
        let label: String?
        let url: URL

        var text: String {
            label.map { "\($0): \(url.absoluteString)" } ?? url.absoluteString
        }
    }

    struct ProviderTextLayout {
        let range: NSRange
        let dividerRange: NSRange
    }

    final class ActionTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: Any?) { action() }
    }

    enum Style {
        case heading, label, secondary, caption

        var font: NSFont {
            switch self {
            case .heading: .systemFont(ofSize: 15, weight: .semibold)
            case .label: .systemFont(ofSize: 13)
            case .secondary: .systemFont(ofSize: 12)
            case .caption: .systemFont(ofSize: 11)
            }
        }

        var color: NSColor {
            switch self {
            case .heading, .label: .labelColor
            case .secondary, .caption: .secondaryLabelColor
            }
        }
    }

    let category: SettingsCategory
    let preferences: SeedingPreferencesStore
    let searchPreferences: SearchPreferencesStore
    let downloadLocation: DownloadLocationStore
    let downloadsVM: DownloadsViewModel
    let automation: DownloadAutomationStore
    let providerHealth: ProviderHealthStore

    private let scrollView = NSScrollView()
    let documentView = FlippedSettingsDocumentView()
    let textView = SelectableSettingsTextView()
    private var placements: [Placement] = []
    var selectionSections: [UUID: NSRange] = [:]
    let providerSelectionIDs = Dictionary(uniqueKeysWithValues: TorrentSearchSite.defaultOrder.map { ($0, UUID()) })
    var targets: [ActionTarget] = []
    var fields: [String: NSTextField] = [:]
    var editors: [String: NSTextView] = [:]
    private let contentWidth: CGFloat = 548
    private var textContentHeight: CGFloat = 1
    var rssDraft: DownloadAutomationStore.RSSRule?
    var editingRSSRuleID: UUID?
    var rssRuleError: String?
    var rssPreviewTitle = ""
    var rssPreviewResult: String?
    var rssSmartEpisodes = false
    var rssDownloadRepacks = false
    var rssStartPaused = false
    var rssSequential = false
    var rssMatchAll = false
    var rssQueuePriority = 0
    private var cancellables: Set<AnyCancellable> = []

    init(
        category: SettingsCategory,
        preferences: SeedingPreferencesStore,
        searchPreferences: SearchPreferencesStore,
        downloadLocation: DownloadLocationStore,
        downloadsVM: DownloadsViewModel,
        automation: DownloadAutomationStore,
        providerHealth: ProviderHealthStore
    ) {
        self.category = category
        self.preferences = preferences
        self.searchPreferences = searchPreferences
        self.downloadLocation = downloadLocation
        self.downloadsVM = downloadsVM
        self.automation = automation
        self.providerHealth = providerHealth
        super.init(frame: .zero)
        configureView()
        observeModelChanges()
        rebuildDocument()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let requiredHeight = max(documentView.frame.height, scrollView.contentSize.height)
        if documentView.frame.height != requiredHeight {
            documentView.frame.size.height = requiredHeight
        }
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: textContentHeight)
        materializePlacements()
    }

    private func configureView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Legacy scrollers stay visible while content overflows; autohiding
        // removes them only when the entire document fits in the viewport.
        scrollView.scrollerStyle = .legacy
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        scrollView.documentView = documentView

        textView.isEditable = false
        textView.isSelectable = true
        textView.setAccessibilityLabel("\(category.title) settings")
        textView.isRichText = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.usesFindPanel = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.delegate = self
        documentView.addSubview(textView)
    }

    private func observeModelChanges() {
        if category == .transfers {
            preferences.$bandwidthSchedule.dropFirst()
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refreshAfterAction() }
                .store(in: &cancellables)
        }
        if category == .automation {
            downloadsVM.$remoteControlURL.dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshAfterAction() }
                .store(in: &cancellables)
            downloadsVM.$remoteControlLANURLs.dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshAfterAction() }
                .store(in: &cancellables)
            downloadsVM.$remoteControlError.dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshAfterAction() }
                .store(in: &cancellables)
        }
        guard category == .search else { return }
        providerHealth.$states
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAfterAction() }
            .store(in: &cancellables)
        providerHealth.$isChecking
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAfterAction() }
            .store(in: &cancellables)
        providerHealth.$lastCheckedAt
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAfterAction() }
            .store(in: &cancellables)
        providerHealth.$providerLinks
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAfterAction() }
            .store(in: &cancellables)
        providerHealth.$sourceLinks
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAfterAction() }
            .store(in: &cancellables)
        providerHealth.$proxyDirectoryLinks
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAfterAction() }
            .store(in: &cancellables)
    }

    func rebuildDocument(preserveScroll: Bool = false) {
        if category == .automation, fields["rssFeed"] != nil {
            rssDraft = readRSSDraft()
            rssPreviewTitle = fields["rssPreview"]?.stringValue ?? ""
        }
        let origin = preserveScroll ? scrollView.contentView.bounds.origin : .zero
        let oldSections = selectionSections
        selectionSections.removeAll()
        placements.removeAll()
        targets.removeAll()
        fields.removeAll()
        editors.removeAll()
        documentView.subviews.filter { $0 !== textView }.forEach { $0.removeFromSuperview() }

        let storage = NSMutableAttributedString()
        appendIntroduction(to: storage)
        switch category {
        case .general: buildGeneral(storage)
        case .automation: buildAutomation(storage)
        case .transfers: buildTransfers(storage)
        case .network: buildNetwork(storage)
        case .search: buildSearch(storage)
        }

        SelectableDocument.update(textView, with: storage, oldSections: oldSections, newSections: selectionSections)
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let used = textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0) } ?? .zero
        textContentHeight = used.maxY + 28
        let height = max(textContentHeight, bounds.height)
        documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: textContentHeight)
        materializePlacements()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func refreshAfterAction() {
        DispatchQueue.main.async { [weak self] in self?.rebuildDocument(preserveScroll: true) }
    }

    /// Keep the introduction in the same native text document as the settings,
    /// so drag selection and Select All can continue through every section.
    private func appendIntroduction(to storage: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 20
        paragraph.headIndent = 20
        paragraph.tailIndent = -20
        paragraph.paragraphSpacingBefore = 20
        paragraph.paragraphSpacing = 6
        paragraph.minimumLineHeight = 20
        if category == .search {
            storage.append(NSAttributedString(string: "Search Websites\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        let subtitleStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
        subtitleStyle.paragraphSpacingBefore = category == .search ? 0 : 16
        subtitleStyle.paragraphSpacing = 20
        subtitleStyle.minimumLineHeight = 18
        storage.append(NSAttributedString(string: category.subtitle + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: subtitleStyle
        ]))
        place(separator(), at: NSRange(location: storage.length - 2, length: 1),
              x: 20, width: 508, height: 1, yOffset: 26)
    }

    func attributes(_ style: Style, reserveControl: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 20
        paragraph.headIndent = 20
        paragraph.tailIndent = reserveControl ? -228 : -20
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacingBefore = style == .heading ? 16 : 4
        paragraph.paragraphSpacing = style == .heading ? 8 : 5
        paragraph.minimumLineHeight = style == .heading ? 22 : 20
        return [.font: style.font, .foregroundColor: style.color, .paragraphStyle: paragraph]
    }

    @discardableResult
    func append(_ text: String, style: Style = .label, reserveControl: Bool = false, to storage: NSMutableAttributedString) -> NSRange {
        let start = storage.length
        storage.append(NSAttributedString(string: text + "\n", attributes: attributes(style, reserveControl: reserveControl)))
        return NSRange(location: start, length: storage.length - start)
    }

    func heading(_ title: String, to storage: NSMutableAttributedString) {
        append(title, style: .heading, to: storage)
    }

    func blankLines(_ count: Int, to storage: NSMutableAttributedString) -> NSRange {
        let start = storage.length
        storage.append(NSAttributedString(string: String(repeating: " \n", count: count), attributes: attributes(.label)))
        return NSRange(location: start, length: storage.length - start)
    }

    func place(_ view: NSView, at range: NSRange, x: CGFloat, width: CGFloat, height: CGFloat = 26, yOffset: CGFloat = 0) {
        placements.append(Placement(range: range, view: view, x: x, width: width, height: height, yOffset: yOffset))
    }

    private func materializePlacements() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        for item in placements {
            let glyphs = manager.glyphRange(forCharacterRange: item.range, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let documentRect = textView.convert(rect, to: documentView)
            if item.view.superview !== documentView { documentView.addSubview(item.view) }
            let fieldHeight = (item.view as? NSTextField)?.intrinsicContentSize.height
            let height = fieldHeight.map { min(item.height, $0) } ?? item.height
            item.view.frame = NSRect(
                x: item.x,
                y: documentRect.minY + item.yOffset + (item.height - height) / 2,
                width: item.width,
                height: height
            )
        }
        window?.invalidateCursorRects(for: documentView)
    }
}

#endif
