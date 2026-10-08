//
//  DownloadsView.swift
//  Torravia
//
//

import SwiftUI
#if os(macOS)
import AppKit
import QuickLook
import UniformTypeIdentifiers
#endif

struct DownloadsView: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @State private var actionErrorMessage: String?
    @State private var pendingRemovals: [DownloadsViewModel.Download] = []
#if os(macOS)
    @State private var quickLookURL: URL?
#endif

    var body: some View {
        content
            .alert("Action Failed", isPresented: actionErrorBinding) {
                Button("OK") { actionErrorMessage = nil }
            } message: {
                Text(actionErrorMessage ?? "Unknown error")
            }
#if os(macOS)
            .quickLookPreview($quickLookURL)
#endif
            .textSelection(.enabled)
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { actionErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    actionErrorMessage = nil
                }
            }
        )
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(
            get: { !pendingRemovals.isEmpty },
            set: { newValue in
                if !newValue {
                    pendingRemovals.removeAll()
                }
            }
        )
    }

    private func requestRemoval(of download: DownloadsViewModel.Download) {
        guard !pendingRemovals.contains(where: { $0.id == download.id }) else { return }
        pendingRemovals.append(download)
    }

    private func removePendingDownloads(deleteFiles: Bool) {
        let removals = pendingRemovals
        pendingRemovals.removeAll()
        for download in removals {
            downloadsVM.cancel(download, deleteFiles: deleteFiles)
        }
    }

    private var content: some View {
        let activeDownloads = downloadsVM.activeDownloads
        return Group {
            if activeDownloads.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
#if os(macOS)
                    NativeDownloadsView(
                        downloads: activeDownloads,
                        downloadsVM: downloadsVM,
                        onPause: { downloadsVM.pause($0) },
                        onResume: { downloadsVM.resume($0) },
                        onForceStart: { downloadsVM.forceStart($0) },
                        onCancel: { requestRemoval(of: $0) },
                        onRedownload: { downloadsVM.redownload($0) },
                        onError: { actionErrorMessage = $0 },
                        onPreview: { quickLookURL = $0 },
                        onRelocate: { download, newURL, bookmarkData in
                            downloadsVM.updateDestination(for: download.id,
                                                          to: newURL,
                                                          bookmarkData: bookmarkData)
                        },
                        onSetSeeding: { download, enabled in
                            downloadsVM.setSeeding(enabled, for: download)
                        }
                    )
#else
                    queueSummary(activeDownloads)
                    List {
                        ForEach(activeDownloads) { download in
                            DownloadRow(download: download,
                                        onPause: { downloadsVM.pause(download) },
                                        onResume: { downloadsVM.resume(download) },
                                        onForceStart: { downloadsVM.forceStart(download) },
                                        onCancel: { requestRemoval(of: download) },
                                        onRedownload: { downloadsVM.redownload(download) },
                                        onError: { actionErrorMessage = $0 },
                                        onPreview: { url in quickLookURL = url },
                                        onRelocate: { newURL, bookmarkData in
                                            downloadsVM.updateDestination(for: download.id,
                                                                           to: newURL,
                                                                           bookmarkData: bookmarkData)
                                        },
                                        onSetSeeding: { enabled in downloadsVM.setSeeding(enabled, for: download) })
                    }
                    .onDelete { idxSet in
                            for idx in idxSet where idx < downloadsVM.activeDownloads.count {
                                requestRemoval(of: downloadsVM.activeDownloads[idx])
                            }
                        }
                    }
                    .listStyle(.inset)
#endif
                }
            }
        }
        .alert("Remove Download?", isPresented: removalAlertBinding) {
            Button("Remove Only") {
                removePendingDownloads(deleteFiles: false)
            }
            if pendingRemovals.contains(where: { !$0.isSeedOnly }) {
                Button("Delete Files", role: .destructive) {
                    removePendingDownloads(deleteFiles: true)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemovals.removeAll()
            }
        } message: {
            if !pendingRemovals.isEmpty && pendingRemovals.allSatisfy(\.isSeedOnly) {
                Text("Remove this torrent from Transfers? The original files will stay on your Mac.")
            } else if pendingRemovals.count == 1, let download = pendingRemovals.first {
                Text("Remove “\(download.title)” from the download list? You can keep its files or delete them from the drive.")
            } else {
                Text("Remove \(pendingRemovals.count) downloads from the list? You can keep their files or delete them from the drive.")
            }
        }
    }

    @ViewBuilder
    private func queueSummary(_ downloads: [DownloadsViewModel.Download]) -> some View {
        HStack(spacing: 14) {
            Label("\(downloads.filter { $0.status == .downloading }.count) downloading", systemImage: "arrow.down.circle")
            Label("\(downloads.filter { $0.status == .completed }.count) completed", systemImage: "checkmark.circle")
            Label("\(downloads.filter { $0.isSeeding }.count) seeding", systemImage: "arrow.up.circle")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptyState: some View {
        SelectableEmptyState(
            title: "No Transfers",
            systemImage: "arrow.down.circle",
            message: "Search for a torrent or add a magnet link to start downloading."
        )
    }
}


struct DownloadMetadataEditor: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    let downloadID: UUID
    @State private var category = ""
    @State private var tags = ""

    private var download: DownloadsViewModel.Download? {
        downloadsVM.downloads.first(where: { $0.id == downloadID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Organization")
                .font(.headline)
            TextField("Category (e.g. Movies, Linux)", text: $category)
                .textFieldStyle(.roundedBorder)
            TextField("Tags (comma-separated)", text: $tags)
                .textFieldStyle(.roundedBorder)
            Text("Categories and tags are persisted with the torrent and can be used to keep large queues organized.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save") {
                    let parsedTags = tags.split(separator: ",").map(String.init)
                    downloadsVM.updateMetadata(for: downloadID, category: category, tags: parsedTags)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .textSelection(.enabled)
        .onAppear {
            category = download?.category ?? ""
            tags = download?.tags.joined(separator: ", ") ?? ""
        }
    }
}

#if os(macOS)
private struct PeerInspectorScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Marker)?.configureScroller()
    }

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configureScroller() }
        }

        func configureScroller() {
            guard let scroll = enclosingScrollView else { return }
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .legacy
        }
    }
}
#endif

struct PeerInspectorView: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    let downloadID: UUID
    let title: String
    var maximumSize = CGSize(width: 480, height: 420)
    var onContentSizeChange: ((CGSize) -> Void)?
    @State private var contentHeight: CGFloat = 0
    @State private var isShowingDiscovery = false
    @State private var trackerURL = ""
    @State private var trackerTier = "0"
    @State private var webSeedURL = ""
    @State private var peerAddress = ""
    @State private var peerRequestTimedOut = false
    @State private var inspectionAttempt = 0
    @FocusState private var focusedField: InspectorField?

    private enum InspectorField: Hashable {
        case trackerURL
        case trackerTier
        case webSeedURL
        case peerAddress
    }

    enum DisplayState: Equatable {
        case loading, peers, empty, inactive, unavailable
    }

    static func displayState(download: DownloadsViewModel.Download?,
                             snapshot: WebTorrentSession.Event.PeerSnapshot?,
                             timedOut: Bool) -> DisplayState {
        guard let download, download.supportsLivePeerInspection else { return .inactive }
        if let snapshot {
            return download.numPeers > 0 && !snapshot.peers.isEmpty ? .peers : .empty
        }
        return timedOut ? .unavailable : .loading
    }

    private var requestsLiveDetails: Bool {
        download?.supportsLivePeerInspection == true
    }

    private var displayState: DisplayState {
        Self.displayState(download: download, snapshot: snapshot, timedOut: peerRequestTimedOut)
    }

    private var snapshot: WebTorrentSession.Event.PeerSnapshot? {
        downloadsVM.peerSnapshot(for: downloadID)
    }

    private var download: DownloadsViewModel.Download? {
        downloadsVM.downloads.first(where: { $0.id == downloadID })
    }

    private var connectedPeerCount: Int {
        downloadsVM.downloads.first(where: { $0.id == downloadID })?.numPeers
            ?? snapshot?.peers.count
            ?? 0
    }

    private var displayedPeers: [WebTorrentSession.Event.Peer] {
        guard let peers = snapshot?.peers else { return [] }
        return Array(peers.prefix(max(connectedPeerCount, 0)))
    }

    var body: some View {
        ScrollView {
            inspectorContent
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                    onContentSizeChange?(CGSize(width: maximumSize.width,
                                                height: min(height, maximumSize.height)))
                }
#if os(macOS)
                .background(PeerInspectorScrollIndicators())
#endif
        }
        .scrollIndicators(.visible)
        .frame(width: maximumSize.width,
               height: min(contentHeight > 0 ? contentHeight : maximumSize.height,
                           maximumSize.height))
        .textSelection(.enabled)
        .onAppear {
            focusedField = nil
            DispatchQueue.main.async { focusedField = nil }
        }
        .onDisappear {
            downloadsVM.setPeerInspectionEnabled(false, for: downloadID)
        }
        .task(id: "\(requestsLiveDetails)-\(inspectionAttempt)") {
            peerRequestTimedOut = false
            downloadsVM.setPeerInspectionEnabled(requestsLiveDetails, for: downloadID)
            guard requestsLiveDetails else { return }
            downloadsVM.refreshDiscovery(for: downloadID)
            downloadsVM.requestPieceAvailability(for: downloadID)
            do {
                try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            } catch { return }
            // Late snapshots replace the timeout state automatically.
            peerRequestTimedOut = snapshot == nil
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                } catch { return }
                downloadsVM.refreshDiscovery(for: downloadID)
                downloadsVM.requestPieceAvailability(for: downloadID)
            }
        }
    }

    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(download?.title ?? title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let originalTitle = download?.originalSearchTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original Search title").foregroundStyle(.secondary)
                    Text(originalTitle).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }

            if let download {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    if let detail = download.peerCountDetails.first {
                        GridRow {
                            Text(detail.label).foregroundStyle(.secondary)
                            Text(detail.value).monospacedDigit()
                        }
                    }
                    if let ratio = download.seedLeechRatioFormatted {
                        GridRow {
                            Text("Connected ratio").foregroundStyle(.secondary)
                            Text(ratio)
                        }
                    }
                }
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(availabilityDescription, systemImage: "square.stack.3d.up")
                if !sourceDescription.isEmpty {
                    Label(sourceDescription, systemImage: "point.3.connected.trianglepath.dotted")
                }
                if let discovery = downloadsVM.discoverySnapshot(for: downloadID) {
                    Label("\(discovery.trackers.count) trackers · \(discovery.webSeeds.count) Web seeds",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
                if let pieces = downloadsVM.pieceAvailability(for: downloadID), !pieces.isEmpty {
                    Label("\(pieces.filter { $0 > 0 }.count)/\(pieces.count) pieces available",
                          systemImage: "square.grid.3x3")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            if let download {
                DisclosureGroup("Discovery", isExpanded: $isShowingDiscovery) {
                    VStack(alignment: .leading, spacing: 12) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(Array(download.peerCountDetails.indices.dropFirst()), id: \.self) { index in
                                let detail = download.peerCountDetails[index]
                                GridRow {
                                    Text(detail.label).foregroundStyle(.secondary)
                                    Text(detail.value).monospacedDigit()
                                }
                            }
                        }
                        .font(.caption)
                        if requestsLiveDetails {
                            discoverySection
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }

            if requestsLiveDetails {
                HStack(spacing: 8) {
                    TextField("Peer IP:port", text: $peerAddress)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .peerAddress)
                    Button("Connect") {
                        downloadsVM.addPeer(peerAddress, for: downloadID)
                        peerAddress = ""
                    }
                    .disabled(peerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            switch displayState {
            case .peers:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedPeers) { peer in
                        peerRow(peer)
                        if peer.id != displayedPeers.last?.id { Divider() }
                    }
                }
            case .loading:
                ProgressView("Loading peer details…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .empty:
                inspectorMessage(
                    title: "No Connected Peers",
                    systemImage: "person.2.slash",
                    message: "Known peers remain available for connection attempts."
                )
            case .inactive:
                inspectorMessage(
                    title: download?.status == .completed ? "Seeding Off" : "Torrent Inactive",
                    systemImage: "person.2.slash",
                    message: download?.status == .completed
                        ? "This download is complete. Turn on seeding to view live peers."
                        : "Live peer details are available while downloading or seeding."
                )
            case .unavailable:
                VStack(spacing: 12) {
                    inspectorMessage(
                        title: "Peer Details Unavailable",
                        systemImage: "person.2.slash",
                        message: "The torrent engine hasn’t returned peer details. Try again."
                    )
                    Button("Retry") { inspectionAttempt += 1 }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inspectorMessage(title: String, systemImage: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func peerRow(_ peer: WebTorrentSession.Event.Peer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peerEndpoint(peer))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(peer.client)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(peer.transport) · \(peer.direction) · \(peer.sources.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Label("\(peer.downloadSpeed.transferRateFormatted)/s", systemImage: "arrow.down")
                    .foregroundStyle(.green)
                Label("\(peer.uploadSpeed.transferRateFormatted)/s", systemImage: "arrow.up")
                    .foregroundStyle(.orange)
                Text(peer.isSeed ? "Seed · 100%" : String(format: "%.1f%%", peer.progress * 100))
                    .foregroundStyle(.secondary)
                Button("Block") {
                    downloadsVM.banPeer(peer, for: downloadID)
                }
                .buttonStyle(.borderless)
                .help("Disconnect and permanently add this IP to the block list")
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
    }

    private var availabilityDescription: String {
        guard let availability = snapshot?.availability else { return "Availability —" }
        return String(format: "Availability %.3f", availability)
    }

    private func peerEndpoint(_ peer: WebTorrentSession.Event.Peer) -> String {
        peer.address.contains(":") ? "[\(peer.address)]:\(peer.port)" : "\(peer.address):\(peer.port)"
    }

    private var sourceDescription: String {
        guard let peers = snapshot?.peers else { return "" }
        let sources = Set(peers.flatMap(\.sources))
        return sources.sorted().joined(separator: ", ")
    }

    private func trackerSourceDescription(_ source: Int) -> String {
        var labels: [String] = []
        if source & 1 != 0 { labels.append("torrent") }
        if source & 2 != 0 { labels.append("client") }
        if source & 4 != 0 { labels.append("magnet") }
        if source & 8 != 0 { labels.append("exchange") }
        return labels.isEmpty ? "unknown source" : labels.joined(separator: ", ")
    }

    @ViewBuilder
    private var discoverySection: some View {
        if let discovery = downloadsVM.discoverySnapshot(for: downloadID) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Button {
                        downloadsVM.refreshDiscovery(for: downloadID)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh tracker and Web seed status")
                    Button {
                        downloadsVM.reannounce(for: downloadID)
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Reannounce to trackers, DHT, and local peers")
                }
                HStack(spacing: 6) {
                    TextField("Add tracker URL", text: $trackerURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .trackerURL)
                    TextField("Tier", text: $trackerTier)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .focused($focusedField, equals: .trackerTier)
                    Button("Add") {
                        downloadsVM.addTracker(trackerURL,
                                               tier: Int(trackerTier) ?? 0,
                                               for: downloadID)
                        trackerURL = ""
                    }
                    .disabled(trackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(spacing: 6) {
                    TextField("Add Web seed URL", text: $webSeedURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .webSeedURL)
                    Button("Add") {
                        downloadsVM.addWebSeed(webSeedURL, for: downloadID)
                        webSeedURL = ""
                    }
                    .disabled(webSeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if discovery.trackers.isEmpty && discovery.webSeeds.isEmpty {
                    Text("No trackers or Web seeds reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    let availableTrackers = discovery.trackers.filter { $0.state != "error" }
                    let unavailableTrackers = discovery.trackers.filter { $0.state == "error" }
                    ForEach(availableTrackers) { tracker in
                        trackerRow(tracker)
                    }
                    if !unavailableTrackers.isEmpty {
                        DisclosureGroup("Unavailable trackers (\(unavailableTrackers.count))") {
                            ForEach(unavailableTrackers) { tracker in
                                trackerRow(tracker)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if !discovery.webSeeds.isEmpty {
                        Text("Web seeds")
                            .font(.caption.weight(.semibold))
                            .padding(.top, 6)
                        ForEach(discovery.webSeeds, id: \.self) { seed in
                            HStack {
                                Text(seed)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Button(role: .destructive) {
                                    downloadsVM.removeWebSeed(seed, for: downloadID)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove Web seed")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func trackerRow(_ tracker: WebTorrentSession.Event.DiscoverySnapshot.Tracker) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tracker.state == "working" ? Color.green : tracker.state == "error" ? Color.red : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.url)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                let scrape = tracker.scrapeComplete.map { " · \($0) seeds / \(tracker.scrapeIncomplete ?? 0) leechers" } ?? ""
                Text("Tier \(tracker.tier) · \(tracker.state.capitalized) · \(tracker.fails) failures · \(trackerSourceDescription(tracker.source))" + scrape + (tracker.message.isEmpty ? "" : " · \(tracker.message)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive) {
                downloadsVM.removeTracker(tracker.url, for: downloadID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove tracker")
        }
    }
}

struct FileSelectionView: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    let downloadID: UUID

    var body: some View {
        let download = downloadsVM.downloads.first(where: { $0.id == downloadID })
        let inspection = downloadsVM.pieceInspection(for: downloadID)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Files to Download").font(.headline)
                Spacer()
                if let download {
                    Menu("Bulk actions") {
                        Button("Select all") { downloadsVM.setAllFilesSelected(true, for: download) }
                        Button("Skip all") { downloadsVM.setAllFilesSelected(false, for: download) }
                        Divider()
                        Button("Set all to Maximum") { downloadsVM.setAllFilePriorities(7, for: download) }
                        Button("Set all to Normal") { downloadsVM.setAllFilePriorities(4, for: download) }
                        Button("Set all to Low") { downloadsVM.setAllFilePriorities(1, for: download) }
                        Button("Skip all priorities") { downloadsVM.setAllFilePriorities(0, for: download) }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            if let download {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(download.files.enumerated()), id: \.offset) { index, file in
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { download.selectedFileIndices?.contains(index) ?? true },
                                    set: { downloadsVM.setFile(index, selected: $0, for: download) }
                                )) {
                                    HStack {
                                        Text(file.relativePath).lineLimit(2)
                                        Spacer()
                                        Text(file.length.byteCountFormatted).foregroundStyle(.secondary)
                                        if let detail = inspection?.files.first(where: { $0.index == index }) {
                                            Text(String(format: "%.1f%% · %.1f avail.", detail.progress * 100, detail.availability))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Button {
                                            promptToRename(file: file, index: index, download: download)
                                        } label: {
                                            Image(systemName: "pencil")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Rename this file")
                                    }
                                }
                                .toggleStyle(.checkbox)
                                Picker("Priority", selection: Binding(
                                    get: { downloadsVM.filePriority(at: index, for: download) },
                                    set: { downloadsVM.setFilePriority(index, priority: $0, for: download) }
                                )) {
                                    Text("Skip").tag(0)
                                    Text("Low").tag(1)
                                    Text("Normal").tag(4)
                                    Text("High").tag(6)
                                    Text("Maximum").tag(7)
                                }
                                .labelsHidden()
                                .frame(width: 112)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 620, height: 420)
        .textSelection(.enabled)
        .onAppear {
            downloadsVM.requestPieceInspection(for: downloadID)
        }
    }

    private func promptToRename(file: DownloadsViewModel.Download.FileEntry,
                                index: Int,
                                download: DownloadsViewModel.Download) {
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = file.relativePath
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: URL(fileURLWithPath: file.relativePath).lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        downloadsVM.renameFile(index, to: field.stringValue, for: download)
    }
}
