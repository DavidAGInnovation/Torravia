import TorraviaSearchCore
//
//  SearchView.swift
//  Torravia
//
//

#if os(macOS)
import AppKit
#endif
import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct SearchView: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @EnvironmentObject private var searchPreferences: SearchPreferencesStore
    @EnvironmentObject private var providerHealth: ProviderHealthStore
    @EnvironmentObject private var networkPreferences: SeedingPreferencesStore
    @StateObject private var peerCounts = SearchPeerCountsStore()
    @Environment(\.colorScheme) private var colorScheme

    @State private var query: String = ""
    @State private var results: [TorrentItem] = []
    @State private var isSearching: Bool = false
    @State private var isCheckingTrackers = false
    @State private var errorMessage: String?
    @State private var hasSearched: Bool = false
    @State private var lastQuery: String? = nil
    @State private var isDropTargeted: Bool = false
    @State private var lastHandledMagnet: String? = nil
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearchID: UUID?
    @State private var searchProvider: SearchProvider?
    @State private var providerSites: Set<TorrentSearchSite> = []
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dropHintInset
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .onPasteCommand(of: [.url, .text, .utf8PlainText], perform: handlePaste(providers:))
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cancelSearch()
            }
            handlePotentialMagnet(from: newValue)
        }
        .onDisappear { cancelSearch() }
        .onChange(of: trackerChecksAllowed) { _, _ in
            cancelSearch()
            results = []
            hasSearched = false
        }
        .textSelection(.enabled)
    }

    private var searchBar: some View {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrentQuerySearching = isSearching && trimmedQuery == lastQuery
        let isDarkMode = colorScheme == .dark
        let backgroundColors: [Color] = isDarkMode
            ? [
                Color(red: 63/255, green: 67/255, blue: 72/255),
                Color(red: 38/255, green: 41/255, blue: 46/255)
            ]
            : [
                Color(red: 250/255, green: 251/255, blue: 253/255),
                Color(red: 235/255, green: 240/255, blue: 248/255)
            ]

        let strokeColorsFocused: [Color] = isDarkMode
            ? [
                Color.white.opacity(0.4),
                Color.white.opacity(0.12)
            ]
            : [
                Color.black.opacity(0.18),
                Color.white.opacity(0.45)
            ]

        let strokeColorsIdle: [Color] = isDarkMode
            ? [
                Color.white.opacity(0.25),
                Color.white.opacity(0.08)
            ]
            : [
                Color.black.opacity(0.1),
                Color.white.opacity(0.25)
            ]

        return HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.medium)
                    .foregroundStyle(Color.primary.opacity(isDarkMode ? 0.75 : 0.6))

                ZStack(alignment: .leading) {
                    if query.isEmpty {
                        Text("Search or paste a magnet link")
                            .foregroundStyle(Color.primary.opacity(isDarkMode ? 0.45 : 0.4))
                    }
                    MacSearchField(
                        text: $query,
                        isFocused: $isSearchFieldFocused,
                        onSubmit: startSearch,
                        onPaste: handleSearchFieldPaste
                    )
                }

                if !query.isEmpty {
                    Button {
                        cancelSearch()
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.primary.opacity(isDarkMode ? 0.55 : 0.45))
                    }
                    .buttonStyle(.plain)
                    .controlCursor()
                    .accessibilityLabel("Clear search")
                    .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: backgroundColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: isSearchFieldFocused ? strokeColorsFocused : strokeColorsIdle,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(isDarkMode ? 0.45 : 0.12), radius: isDarkMode ? 18 : 14, x: 0, y: isDarkMode ? 12 : 9)
            .shadow(color: .white.opacity(isDarkMode ? 0.06 : 0.65), radius: 1, x: 0, y: 1)

            if hasSearched {
                sortMenu
            }

            Button(action: startSearch) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 83/255, green: 148/255, blue: 255/255),
                                    Color(red: 42/255, green: 96/255, blue: 255/255)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: Color.blue.opacity(0.45), radius: 16, x: 0, y: 8)

                    if isCurrentQuerySearching {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .disabled(isCurrentQuerySearching || trimmedQuery.isEmpty)
            .opacity(isCurrentQuerySearching || !trimmedQuery.isEmpty ? 1 : 0.7)
            .controlCursor()
        }
        .textSelection(.disabled)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sortMenu: some View {
        let isDarkMode = colorScheme == .dark
        return Menu {
            ForEach(SearchResultsSortOrder.allCases) { option in
                Button {
                    searchPreferences.sortOrder = option
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .hidden(option != searchPreferences.sortOrder)
                        sortOrderIcon(for: option)
                            .frame(width: 16, height: 16, alignment: .center)
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .imageScale(.medium)
                    .symbolRenderingMode(.hierarchical)
                Text(searchPreferences.sortOrder.shortLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(isDarkMode ? 0.25 : 0.12), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort search results")
        .controlCursor()
    }

    @ViewBuilder
    private func sortOrderIcon(for order: SearchResultsSortOrder) -> some View {
        switch order {
        case .seeders:
            Image(systemName: "person.3.fill")
                .imageScale(.medium)
        case .sizeDescending:
            #if os(macOS)
            Image(nsImage: SortOrderIconRenderer.image(for: .descending))
                .renderingMode(.template)
            #else
            Image(systemName: "chart.bar.fill")
                .imageScale(.medium)
            #endif
        case .sizeAscending:
            #if os(macOS)
            Image(nsImage: SortOrderIconRenderer.image(for: .ascending))
                .renderingMode(.template)
            #else
            Image(systemName: "chart.bar")
                .imageScale(.medium)
            #endif
        }
    }

#if os(macOS)
    private enum SortOrderIconRenderer {
        enum Direction {
            case ascending
            case descending
        }

        private static var cache: [Direction: NSImage] = [:]

        static func image(for direction: Direction) -> NSImage {
            if let cached = cache[direction] {
                return cached
            }

            let size = NSSize(width: 16, height: 16)
            let image = NSImage(size: size, flipped: false) { _ in
                let barHeights: [CGFloat] = {
                    switch direction {
                    case .ascending:
                        return [4, 8, 12]
                    case .descending:
                        return [12, 8, 4]
                    }
                }()

                let barWidth: CGFloat = 3
                let spacing: CGFloat = 2
                for (index, height) in barHeights.enumerated() {
                    let x = CGFloat(index) * (barWidth + spacing)
                    let barRect = NSRect(x: x, y: 0, width: barWidth, height: height)
                    let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
                    NSColor.labelColor.setFill()
                    path.fill()
                }
                return true
            }
            image.isTemplate = true
            cache[direction] = image
            return image
        }
    }
#endif

    @ViewBuilder
    private var content: some View {
        if isSearching && results.isEmpty {
            ProgressView(isCheckingTrackers ? "Checking tracker estimates…" : "Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            if hasSearched {
                noResultsState
            } else {
                emptyState
            }
        } else {
#if os(macOS)
            NativeSearchResultsView(
                items: sortedResults,
                peerCounts: peerCounts,
                disclaimer: searchDisclaimerMessage,
                downloadsVM: downloadsVM,
                onAdd: { item in
                    downloadsVM.add(from: item)
                },
                onError: { message in
                    errorMessage = message
                }
            )
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
#else
            List {
                Section(footer: searchDisclaimer) {
                    ForEach(sortedResults) { item in
                        TorrentRow(
                            item: item,
                            peerCount: peerCounts.state(for: item),
                            onAdd: {
                                downloadsVM.add(from: item)
                            },
                            onError: { message in
                                errorMessage = message
                            }
                        )
                    }
                }
            }
            .listStyle(.inset)
#endif
        }
    }

    private var searchDisclaimer: some View {
        Text(searchDisclaimerMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.vertical, 4)
    }

    private var searchDisclaimerMessage: String {
        let enabled = searchPreferences.enabledSites
        let enabledSites = TorrentSearchSite.defaultOrder
            .filter { enabled.isEmpty || enabled.contains($0) }
        let displayNames = enabledSites.map(\.displayName)
        let maxShown = 4
        let listed: String
        if displayNames.count <= maxShown {
            listed = displayNames.joined(separator: ", ")
        } else {
            let remaining = displayNames.count - maxShown
            let truncated = displayNames.prefix(maxShown).joined(separator: ", ")
            listed = "\(truncated), +\(remaining) more"
        }
        let summary = displayNames.isEmpty ? "no enabled sites" : listed
        return "Results come from public indexes (\(summary)). Verify legality before downloading."
    }

    private var emptyState: some View {
        SelectableEmptyState(
            title: "Search Torrents",
            systemImage: "magnifyingglass",
            message: "Search or paste magnet links to add them to your downloads queue."
        )
    }

    private var noResultsState: some View {
        let shownQuery = lastQuery?.isEmpty == false ? lastQuery! : query
        return SelectableEmptyState(
            title: "No Results",
            systemImage: "magnifyingglass",
            message: "No results for \"\(shownQuery)\". Try different keywords."
        )
    }

    @MainActor
    private func startSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelSearch()
        results = []
        errorMessage = nil
        hasSearched = true
        lastQuery = trimmed
        let enabledSites = searchPreferences.enabledSites
        guard !enabledSites.isEmpty else {
            errorMessage = "Enable at least one search website in Settings."
            return
        }

        // Keep connections warm between searches. Recreate providers when
        // the user changes which websites are enabled.
        if searchProvider == nil || providerSites != enabledSites {
            searchProvider = SearchProvider(mode: .balanced, enabledSites: enabledSites)
            providerSites = enabledSites
        }
        guard let provider = searchProvider else { return }
        let searchID = UUID()
        activeSearchID = searchID
        isSearching = true

        searchTask = Task { @MainActor in
            var pendingResults: [TorrentItem]?
            var preparationTask: Task<Void, Never>?

            // Coalesce provider updates while a batch is being checked. Publish
            // only completed batches; the slowest website need not hide them.
            func queueTrackerChecks(_ items: [TorrentItem]) {
                pendingResults = items
                guard preparationTask == nil else { return }
                preparationTask = Task { @MainActor in
                    defer { preparationTask = nil }
                    while let items = pendingResults {
                        pendingResults = nil
                        guard activeSearchID == searchID, !Task.isCancelled else { return }
                        isCheckingTrackers = true
                        await peerCounts.checkAll(items, allowed: trackerChecksAllowed)
                        guard activeSearchID == searchID, !Task.isCancelled else { return }
                        results = items
                        isCheckingTrackers = false
                    }
                }
            }

            defer {
                preparationTask?.cancel()
                if activeSearchID == searchID {
                    isSearching = false
                    isCheckingTrackers = false
                    activeSearchID = nil
                    searchTask = nil
                }
            }
            do {
                let items = try await provider.search(query: trimmed, finishWhenFull: false, limitResults: false, onProviderResult: { name, error in
                    guard activeSearchID == searchID, !Task.isCancelled else { return }
                    providerHealth.recordSearchOutcome(providerName: name, error: error)
                }, onResults: { items in
                    guard activeSearchID == searchID, !Task.isCancelled else { return }
                    queueTrackerChecks(items)
                })
                guard activeSearchID == searchID, !Task.isCancelled else { return }
                queueTrackerChecks(items)
                await preparationTask?.value
            } catch is CancellationError {
                // A newer query or clearing the field superseded this search.
            } catch {
                guard activeSearchID == searchID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func cancelSearch() {
        activeSearchID = nil
        peerCounts.cancel()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isCheckingTrackers = false
    }

    private var trackerChecksAllowed: Bool {
        SearchPeerCountsStore.checksAllowed(
            proxyType: networkPreferences.proxyType,
            interface: networkPreferences.networkInterface,
            anonymous: networkPreferences.anonymousMode,
            blockedRanges: networkPreferences.blockedIPRanges
        )
    }

    // Apply the display cap after tracker ranking. Indexed counts may be
    // stale and must not exclude active swarms before they are checked.
    private var sortedResults: [TorrentItem] {
        searchPreferences.sortOrder.sorted(results, peerStates: peerCounts.states, limit: SearchMode.balanced.tuning.maxResults)
    }

    private func handlePaste(providers: [NSItemProvider]) {
        let identifiers: [UTType] = [.url, .text, .utf8PlainText]
        var handled = false

        for provider in providers {
            guard provider.hasItemConforming(toAny: identifiers) else { continue }
            handled = true

            if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    processPastedURL(url)
                }
                continue
            }

            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let string = object as? String else { return }
                    processPastedString(string)
                }
            }
        }

        if !handled, let clipboardString = fallbackClipboardText() {
            processPastedString(clipboardString)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConforming(toAny: [UTType.fileURL]) }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let urlValue as URL:
                    url = urlValue
                case let nsURL as NSURL:
                    url = nsURL as URL
                default:
                    url = nil
                }

                guard let resolvedURL = url else { return }
                processDroppedTorrent(at: resolvedURL)
            }
        }
        return true
    }

    private func handlePotentialMagnet(from newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastHandledMagnet = nil
            return
        }

        guard DownloadsViewModel.isValidMagnetLink(trimmed) else { return }
        Task { @MainActor in
            addMagnets([trimmed])
        }
    }

    private func processPastedURL(_ url: URL) {
        guard url.scheme?.lowercased() == "magnet" else { return }
        Task { @MainActor in
            addMagnets([url.absoluteString])
        }
    }

    private func processPastedString(_ string: String) {
        let candidates = extractMagnetLinks(from: string)
        guard !candidates.isEmpty else { return }

        Task { @MainActor in
            addMagnets(candidates)
        }
    }

    private func processDroppedTorrent(at url: URL) {
        Task { @MainActor in
            guard url.pathExtension.lowercased() == "torrent" else { return }
            let result = await downloadsVM.addTorrentFile(at: url)
            switch result {
            case .added:
                break
            case .duplicate(let title):
                if let title {
                    errorMessage = "\"\(title)\" is already in your downloads queue."
                } else {
                    errorMessage = "This torrent is already in your downloads queue."
                }
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    private func extractMagnetLinks(from text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'"))
        let tokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var results: [String] = []

        for token in tokens {
            guard token.lowercased().hasPrefix("magnet:?") else { continue }
            if seen.insert(token).inserted {
                results.append(token)
            }
        }

        return results
    }

    private func fallbackClipboardText() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }

    @MainActor
    private func addMagnets(_ magnets: [String]) {
        var handledAny = false
        var duplicates: [String] = []
        var seen = Set<String>()

        for raw in magnets {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard DownloadsViewModel.isValidMagnetLink(trimmed) else { continue }
            guard seen.insert(trimmed).inserted else { continue }

            if downloadsVM.hasDownload(for: trimmed) {
                lastHandledMagnet = trimmed
                duplicates.append(trimmed)
                continue
            }

            downloadsVM.addMagnetLink(trimmed)
            lastHandledMagnet = trimmed
            handledAny = true
        }

        if handledAny {
            query = ""
            results = []
            hasSearched = false
        } else if !duplicates.isEmpty {
            query = ""
            let message: String
            if duplicates.count == 1, let magnet = duplicates.first {
                if let title = downloadsVM.downloads.first(where: { $0.torrent.magnetLink == magnet })?.title {
                    message = "\"\(title)\" is already in your downloads queue."
                } else {
                    message = "This torrent is already in your downloads queue."
                }
            } else {
                message = "These torrents are already in your downloads queue."
            }
            errorMessage = message
        }
    }

    private func handleSearchFieldPaste(_ raw: String) -> Bool {
        let magnets = extractMagnetLinks(from: raw)
        guard !magnets.isEmpty else { return false }
        Task { @MainActor in
            addMagnets(magnets)
        }
        return true
    }
}

private extension NSItemProvider {
    func hasItemConforming(toAny types: [UTType]) -> Bool {
        types.contains { hasItemConformingToTypeIdentifier($0.identifier) }
    }
}

private extension View {
    @ViewBuilder
    func hidden(_ shouldHide: Bool) -> some View {
        if shouldHide {
            self.hidden()
        } else {
            self
        }
    }
}

private extension SearchView {
    private var isDropHintCompact: Bool {
        !isDropTargeted && !results.isEmpty
    }

    private var dropHintInset: some View {
        dropHint
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .allowsHitTesting(false)
    }

    var dropHint: some View {
        let isDarkMode = colorScheme == .dark
        let isCompact = isDropHintCompact
        let fillGradient = LinearGradient(
            colors: isDarkMode
                ? [
                    Color(red: 54/255, green: 58/255, blue: 63/255).opacity(0.92),
                    Color(red: 27/255, green: 30/255, blue: 35/255).opacity(0.9)
                ]
                : [
                    Color(red: 244/255, green: 247/255, blue: 255/255),
                    Color(red: 228/255, green: 235/255, blue: 249/255)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        let borderGradient = LinearGradient(
            colors: [
                Color.accentColor.opacity(isDropTargeted ? 0.9 : (isCompact ? 0.4 : 0.6)),
                Color.accentColor.opacity(isDropTargeted ? 0.5 : (isCompact ? 0.18 : 0.25))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        let glowColor = Color.accentColor.opacity(isDropTargeted ? 0.4 : (isCompact ? 0.12 : 0.18))

        return ZStack {
            RoundedRectangle(cornerRadius: isCompact ? 16 : 22, style: .continuous)
                .fill(fillGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: isCompact ? 16 : 22, style: .continuous)
                        .stroke(borderGradient, lineWidth: isCompact ? 1.2 : 1.6)
                        .blur(radius: isDropTargeted ? 0 : 0.25)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isCompact ? 16 : 22, style: .continuous)
                        .stroke(Color.white.opacity(isDarkMode ? 0.05 : 0.35), lineWidth: isCompact ? 0.6 : 0.8)
                        .blendMode(.overlay)
                )
                .shadow(color: glowColor, radius: isDropTargeted ? 26 : (isCompact ? 10 : 16), x: 0, y: isDropTargeted ? 12 : (isCompact ? 6 : 8))

            VStack(spacing: isCompact ? 4 : 8) {
                Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                    .font(.system(size: isCompact ? 20 : 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(isDropTargeted ? 0.95 : (isCompact ? 0.7 : 0.8)))
                    .scaleEffect(isDropTargeted ? 1.05 : 1)

                if isCompact {
                    Text("Drop .torrent files to add them")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(isDarkMode ? 0.82 : 0.6))
                } else {
                    VStack(spacing: 4) {
                        Text("Drop a torrent file here")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.primary.opacity(isDarkMode ? 0.92 : 0.7))
                        Text("Drag .torrent files to add them to your queue.")
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, isCompact ? 16 : 20)
            .padding(.vertical, isCompact ? 10 : 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: isCompact ? 60 : 108)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isDropTargeted)
    }
}
