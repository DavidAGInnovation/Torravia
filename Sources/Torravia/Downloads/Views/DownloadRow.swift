import TorraviaSearchCore
//
//  DownloadRow.swift
//  Torravia
//
//  Download list row UI and macOS file/share actions.
//

import SwiftUI
#if os(macOS)
import AppKit
import QuickLook
import UniformTypeIdentifiers
#endif

#if os(macOS)
private struct DownloadRowControlsOnlyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var downloadRowControlsOnly: Bool {
        get { self[DownloadRowControlsOnlyKey.self] }
        set { self[DownloadRowControlsOnlyKey.self] = newValue }
    }
}

extension View {
    func downloadRowControlsOnly() -> some View {
        environment(\.downloadRowControlsOnly, true)
    }
}
#endif

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

extension DownloadsView {
#if os(macOS)
    static func revealInFinder(download: DownloadsViewModel.Download) {
        DispatchQueue.main.async {
            guard let targetURL = finderTargetURL(for: download) else { return }

            let scoped = targetURL.startAccessingSecurityScopedResource()
            defer { if scoped { targetURL.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let parent = targetURL.deletingLastPathComponent().path
                    NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: parent)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                }
            } else {
                let parent = targetURL.deletingLastPathComponent().path
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parent)
            }
        }
    }

    static func finderTargetURL(for download: DownloadsViewModel.Download) -> URL? {
        if let file = download.previewCandidateURLs.first, file.isFileURL {
            return file
        }
        if let destination = download.destinationURL, destination.isFileURL {
            return destination
        }
        if let source = download.torrent.sourceURL, source.isFileURL {
            return source
        }
        return nil
    }

    static func relocateDownload(download: DownloadsViewModel.Download,
                                 currentURL: URL,
                                 completion: @escaping (URL, Data?) -> Void,
                                 onError: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.prompt = "Move"
        panel.message = "Choose a new location for \(download.title)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentURL.deletingLastPathComponent()

        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer {
                if scoped { destination.stopAccessingSecurityScopedResource() }
            }
            let fileManager = FileManager.default
            let newURL = destination.appendingPathComponent(currentURL.lastPathComponent)
            guard newURL != currentURL else {
                DispatchQueue.main.async { completion(newURL, nil) }
                return
            }
            do {
                if fileManager.fileExists(atPath: newURL.path) {
                    let alert = NSAlert()
                    alert.messageText = "Replace existing item?"
                    alert.informativeText = "An item named \(newURL.lastPathComponent) already exists in that folder. Replacing it will permanently remove the existing item."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Replace")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    try fileManager.removeItem(at: newURL)
                }
                try fileManager.moveItem(at: currentURL, to: newURL)
                let bookmark = try? destination.bookmarkData(options: [.withSecurityScope],
                                                              includingResourceValuesForKeys: nil,
                                                              relativeTo: nil)
                DispatchQueue.main.async { completion(newURL, bookmark) }
            } catch {
                DispatchQueue.main.async {
                    onError("Couldn’t move \"\(download.title)\": \(error.localizedDescription)")
                }
            }
        }
    }

    static func firstPreviewURL(for download: DownloadsViewModel.Download) -> URL? {
        for url in download.previewCandidateURLs {
            if isPreviewable(url: url) {
                return url
            }
        }
        return nil
    }

    static func exportTorrent(download: DownloadsViewModel.Download,
                              data: Data,
                              onError: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            if #available(macOS 11.0, *) {
                if let torrentType = UTType(filenameExtension: "torrent") {
                    panel.allowedContentTypes = [torrentType]
                }
            } else {
                panel.allowedFileTypes = ["torrent"]
            }
            panel.nameFieldStringValue = download.preferredTorrentFileName
            panel.isExtensionHidden = false
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: [.atomic])
                } catch {
                    onError("Couldn’t export \"\(download.preferredTorrentFileName)\": \(error.localizedDescription)")
                }
            }
        }
    }

    static func copyMagnetLink(download: DownloadsViewModel.Download) {
        let magnet = download.magnetLink
        guard !magnet.isEmpty else { return }
        copyToPasteboard(magnet)
    }

    static func copyTorrentName(download: DownloadsViewModel.Download) {
        copyToPasteboard(download.title)
    }

    private static func copyToPasteboard(_ value: String) {
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    private static func isPreviewable(url: URL) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        if let values = try? url.resourceValues(forKeys: [.isReadableKey]), values.isReadable == false {
            return false
        }
        return true
    }
#endif
}

struct DownloadRow: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
#if os(macOS)
    @Environment(\.downloadRowControlsOnly) private var controlsOnly
#endif
    let download: DownloadsViewModel.Download
    // Reserve stable slots for live rates so the peer-inspector popover's
    // anchor does not move when a value changes unit or digit count.
    private let transferRateSlotWidth: CGFloat = 80
    var onPause: () -> Void
    var onResume: () -> Void
    var onForceStart: () -> Void
    var onCancel: () -> Void
    var onRedownload: () -> Void
    var onError: (String) -> Void = { _ in }
    @State private var isShowingPeerInspector = false
    @State private var isShowingFileSelection = false
    @State private var isShowingMetadataEditor = false
    @State private var isShowingSeedingLimits = false
#if os(macOS)
    var onPreview: (URL) -> Void
    var onRelocate: (URL, Data?) -> Void
    var onSetSeeding: (Bool) -> Void = { _ in }
    @State private var isExportingTorrent = false
#endif

    var body: some View {
#if os(macOS)
        if controlsOnly {
            controlsOnlyBody
        } else {
            completeRowBody
        }
#else
        completeRowBody
#endif
    }

    private var completeRowBody: some View {
        let model = currentDownload
        let progress = model.displayProgress
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: model.isSeeding ? "arrow.up.circle.fill" : model.status.systemImage)
                    .foregroundStyle(.secondary)
                Text(model.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
            }

            HStack(spacing: 12) {
                Label(model.compactSeederDescription, systemImage: "arrow.up.circle")
                    .foregroundStyle(.green)
                    .help(model.seederCountHelp)

                Label(model.compactLeecherDescription, systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                    .help(model.leecherCountHelp)

                if model.hasResolvedSize {
                    Label(model.resolvedSizeBytes.byteCountFormatted, systemImage: "internaldrive")
                }
                if !model.category.isEmpty {
                    Label(model.category, systemImage: "folder")
                }
                if model.isForceStarted {
                    Label("Forced", systemImage: "bolt.fill")
                        .foregroundStyle(.blue)
                        .help("This torrent bypasses the automatic queue")
                }
                ForEach(model.tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)")
                        .foregroundStyle(.blue)
                }
                if let policy = model.seedingPolicyDescription {
                    Label(policy, systemImage: "arrow.up.arrow.down")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ZStack(alignment: .trailing) {
                progressBar(progress: progress, model: model)
                Text(String(format: "%.1f%%", model.displayProgressPercentage))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }

            if model.isRestoringProgress && (model.status == .downloading || model.status == .queued) {
                Text(model.activityStatusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(model.status == .failed ? .red : .orange)
            }

            let showsTransferMetrics = (model.status == .downloading && !model.isRestoringProgress && model.displayProgress < 1) || model.isSeeding

            HStack(alignment: .top, spacing: 12) {
                seedingStatusControl

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if showsTransferMetrics {
                            Label("\(model.speedBytesPerSec.transferRateFormatted)/s", systemImage: "arrow.down")
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .frame(width: transferRateSlotWidth, alignment: .leading)
                                .help("Current download speed")
                            Label("\(model.uploadSpeedBytesPerSec.transferRateFormatted)/s", systemImage: "arrow.up")
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .frame(width: transferRateSlotWidth, alignment: .leading)
                                .help("Current upload speed")
                        }
                        peerInspectorButton(for: model)
                    }
                    if let eta = model.etaSeconds, model.status != .completed {
                        Label("ETA: \(eta.timeSpanFormatted)", systemImage: "clock")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if model.isSeeding, model.uploadedBytes > 0 {
                    Label("Uploaded \(model.uploadedBytes.byteCountFormatted)", systemImage: "arrow.up")
                }
                Spacer()
                controlButtons
                    .textSelection(.disabled)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
        .contextMenu {
            downloadActions(for: model)
        }
        .popover(isPresented: $isShowingFileSelection) {
            FileSelectionView(downloadID: model.id)
                .environmentObject(downloadsVM)
        }
        .popover(isPresented: $isShowingMetadataEditor) {
            DownloadMetadataEditor(downloadID: model.id)
                .environmentObject(downloadsVM)
        }
        .popover(isPresented: $isShowingSeedingLimits) {
            SeedingLimitsEditor(download: model)
                .environmentObject(downloadsVM)
        }
    }

#if os(macOS)
    /// AppKit places these native controls beside the selectable details.
    private var controlsOnlyBody: some View {
        let model = currentDownload
        return controlButtons
        .textSelection(.disabled)
        .font(.body)
        .controlSize(.large)
        .buttonStyle(.bordered)
        .fixedSize()
        .contextMenu {
            downloadActions(for: model)
        }
        .popover(isPresented: $isShowingFileSelection) {
            FileSelectionView(downloadID: model.id)
                .environmentObject(downloadsVM)
        }
        .popover(isPresented: $isShowingMetadataEditor) {
            DownloadMetadataEditor(downloadID: model.id)
                .environmentObject(downloadsVM)
        }
        .popover(isPresented: $isShowingSeedingLimits) {
            SeedingLimitsEditor(download: model)
                .environmentObject(downloadsVM)
        }
    }
#endif

    @ViewBuilder
    private func peerInspectorButton(for model: DownloadsViewModel.Download) -> some View {
        Button("Details…") {
            isShowingPeerInspector = true
        }
        .buttonStyle(.borderless)
        .textSelection(.disabled)
        .help("Show torrent names, connected peers, and discovery details")
        .popover(isPresented: $isShowingPeerInspector) {
            PeerInspectorView(downloadID: model.id, title: model.title)
                .environmentObject(downloadsVM)
        }
    }

    @ViewBuilder
    private func downloadActions(for model: DownloadsViewModel.Download) -> some View {
        Button("Edit Category & Tags…") { isShowingMetadataEditor = true }
        Button("Seeding Limits…") { isShowingSeedingLimits = true }
        Menu("Share ratio") {
            Button("Unlimited") {
                downloadsVM.setShareRatioPolicy(for: model.id, limit: nil,
                    action: model.seedingTimeLimitMinutes != nil || model.inactiveSeedingTimeLimitMinutes != nil ? model.shareRatioAction : .none)
            }
            ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { limit in
                Menu(String(format: "%.1f×", limit)) {
                    ForEach(DownloadsViewModel.Download.ShareRatioAction.allCases) { action in
                        Button(action.title) {
                            downloadsVM.setShareRatioPolicy(for: model.id, limit: limit, action: action)
                        }
                    }
                }
            }
        }
        if model.status != .completed {
            Button(model.isSequentialDownload ? "Disable Sequential Download" : "Download Sequentially") {
                downloadsVM.setSequentialDownload(!model.isSequentialDownload, for: model)
            }
            if model.files.count > 1 {
                Button("Choose Files…") { isShowingFileSelection = true }
            }
            Menu("Download limit") {
                Button("Unlimited") { downloadsVM.setTorrentLimits(for: model, downloadLimit: 0) }
                Button("1 MB/s") { downloadsVM.setTorrentLimits(for: model, downloadLimit: 1_000_000) }
                Button("5 MB/s") { downloadsVM.setTorrentLimits(for: model, downloadLimit: 5_000_000) }
                Button("10 MB/s") { downloadsVM.setTorrentLimits(for: model, downloadLimit: 10_000_000) }
            }
            Menu("Upload limit") {
                Button("Unlimited") { downloadsVM.setTorrentLimits(for: model, uploadLimit: 0) }
                Button("512 KB/s") { downloadsVM.setTorrentLimits(for: model, uploadLimit: 512_000) }
                Button("1 MB/s") { downloadsVM.setTorrentLimits(for: model, uploadLimit: 1_000_000) }
                Button("5 MB/s") { downloadsVM.setTorrentLimits(for: model, uploadLimit: 5_000_000) }
            }
            Menu("Upload slots") {
                Button("1 slot") { downloadsVM.setTorrentLimits(for: model, maxUploads: 1) }
                Button("4 slots") { downloadsVM.setTorrentLimits(for: model, maxUploads: 4) }
                Button("8 slots") { downloadsVM.setTorrentLimits(for: model, maxUploads: 8) }
                Button("20 slots") { downloadsVM.setTorrentLimits(for: model, maxUploads: 20) }
            }
            Button(model.firstLastPiecePriority ? "Disable First/Last Piece Priority" : "Prioritize First/Last Piece") {
                downloadsVM.setFirstLastPiecePriority(!model.firstLastPiecePriority, for: model)
            }
            Divider()
            Menu("Queue priority") {
                Button("Normal") { downloadsVM.setQueuePriority(0, for: model) }
                Button("Top") { downloadsVM.setQueuePriority(1, for: model) }
                Button("Bottom") { downloadsVM.setQueuePriority(-1, for: model) }
            }
            Button("Move Up in Queue") { downloadsVM.moveUp(model) }
            Button("Move Down in Queue") { downloadsVM.moveDown(model) }
            Button("Move to Top of Queue") { downloadsVM.moveToTop(model) }
            Button("Move to Bottom of Queue") { downloadsVM.moveToBottom(model) }
            Button("Verify Existing Data") { downloadsVM.forceRecheck(model) }
        }
    }

    @ViewBuilder
    private var seedingStatusControl: some View {
#if os(macOS)
        let model = currentDownload
        if model.status == .completed {
            HStack(spacing: 5) {
                Toggle("Seeding", isOn: Binding(
                    get: { model.isSeeding },
                    set: { newValue in
                        guard newValue != model.isSeeding else { return }
                        onSetSeeding(newValue)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .textSelection(.disabled)
                .controlSize(.small)
                SelectableLabel(text: model.isSeeding
                    ? model.seedingDurationFormatted.map { "Seeding \($0)" } ?? "Seeding"
                    : "Seeding Off")
            }
        } else if model.isSeeding, let duration = model.seedingDurationFormatted {
            SelectableLabel(text: "Seeding \(duration)")
        }
#endif
    }

    @ViewBuilder
    private var controlButtons: some View {
        let model = currentDownload
        switch model.status {
        case .downloading:
            HStack(spacing: 8) {
#if os(macOS)
                shareMenu(for: model)
                locationControls(for: model)
#endif
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                }
                .accessibilityLabel("Pause")

                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Cancel")
            }
        case .paused:
            HStack(spacing: 8) {
#if os(macOS)
                locationControls(for: model)
#endif
                Button(action: onResume) {
                    Image(systemName: "play.fill")
                }
                .accessibilityLabel("Resume")

                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Cancel")
            }
        case .queued:
            HStack(spacing: 8) {
#if os(macOS)
                locationControls(for: model)
#endif
                ProgressView()
                    .progressViewStyle(.circular)
#if os(macOS)
                    .controlSize(.small)
#endif
                    .frame(width: 16, height: 16)
                Button(action: onForceStart) {
                    Image(systemName: "play.fill")
                }
                .accessibilityLabel("Start Now")
                .help("Start now, bypassing the download queue")
                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel("Cancel")
            }
        case .completed:
            HStack(spacing: 8) {
                if model.canRedownload {
                    Button {
                        onRedownload()
                    } label: {
                        if controlsOnly { Image(systemName: "arrow.clockwise.circle") }
                        else { Label("Re-download", systemImage: "arrow.clockwise.circle") }
                    }
                    .accessibilityLabel("Re-download")
                }
#if os(macOS)
                if let previewURL = previewURL {
                    Button {
                        onPreview(previewURL)
                    } label: {
                        if controlsOnly { Image(systemName: "eye") }
                        else { Label("Preview", systemImage: "eye") }
                    }
                    .accessibilityLabel("Preview")
                    .help("Preview")
                }
                shareMenu(for: model)
                locationControls(for: model)
#endif
                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove")
            }
        case .failed:
            HStack(spacing: 8) {
#if os(macOS)
                locationControls(for: model)
#endif
                Button(action: onResume) {
                    if controlsOnly { Image(systemName: "arrow.clockwise") }
                    else { Text("Retry") }
                }
                .accessibilityLabel("Retry")
                Button(role: .destructive, action: onCancel) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove")
            }
        }
    }

#if os(macOS)
    @ViewBuilder
    private func locationControls(for model: DownloadsViewModel.Download) -> some View {
        Group {
            let finderURL = DownloadsView.finderTargetURL(for: model)
            Button {
                DownloadsView.revealInFinder(download: model)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(finderURL == nil)
            .help(finderURL == nil ? "No file location is available yet" : "Show the download location in Finder")

            Button {
                guard let destinationURL = model.destinationURL else { return }
                DownloadsView.relocateDownload(download: model,
                                               currentURL: destinationURL,
                                               completion: { newLocation, bookmarkData in
                    onRelocate(newLocation, bookmarkData)
                },
                                               onError: onError)
            } label: {
                Label("Move…", systemImage: "arrow.up.right.square")
            }
            .disabled(model.destinationURL == nil || model.status == .downloading || model.status == .queued)
            .help(model.status == .downloading || model.status == .queued
                  ? "Pause the download before moving its files"
                  : "Move the download to another folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
#endif

    private var currentDownload: DownloadsViewModel.Download {
        downloadsVM.downloads.first(where: { $0.id == download.id }) ?? download
    }

#if os(macOS)
    private func shareMenu(for model: DownloadsViewModel.Download) -> some View {
        Menu {
            Button("Export Torrent") {
                exportTorrentForCurrentDownload(model)
            }
            .disabled(isExportingTorrent)
            Button("Copy Magnet Link") {
                DownloadsView.copyMagnetLink(download: model)
            }
            Button("Copy Torrent Name") {
                DownloadsView.copyTorrentName(download: model)
            }
        } label: {
            shareMenuLabel
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .hideMenuIndicatorIfSupported()
        .help("Share options")
        .accessibilityLabel("Share options")
        .controlSize(.large)
    }

    private func exportTorrentForCurrentDownload(_ model: DownloadsViewModel.Download) {
        if let data = exportableTorrentData {
            DownloadsView.exportTorrent(download: model, data: data, onError: onError)
            return
        }
        isExportingTorrent = true
        Task(priority: .userInitiated) {
            let data = await downloadsVM.resolveTorrentData(for: model.id)
            await MainActor.run {
                self.isExportingTorrent = false
                guard let data else {
                    self.onError("Couldn’t export \"\(model.preferredTorrentFileName)\" because its torrent metadata is unavailable.")
                    return
                }
                let latest = self.downloadsVM.downloads.first(where: { $0.id == model.id }) ?? model
                DownloadsView.exportTorrent(download: latest, data: data, onError: self.onError)
            }
        }
    }

    private var shareMenuLabel: some View {
        Group {
            if isExportingTorrent {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: 17, height: 14)
    }
#endif

#if os(macOS)
    private var previewURL: URL? {
        let download = currentDownload
        guard download.files.count <= 1 else { return nil }
        return DownloadsView.firstPreviewURL(for: download)
    }

    private var exportableTorrentData: Data? {
        let download = currentDownload
        if let data = download.torrentData {
            return data
        }
        if let source = download.torrent.sourceURL,
           source.isFileURL,
           let data = try? Data(contentsOf: source) {
            return data
        }
        return nil
    }
#endif

    @ViewBuilder
    private func progressBar(progress: Double, model: DownloadsViewModel.Download) -> some View {
        if model.status == .completed {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: width)
                }
            }
            .frame(height: 6)
        } else {
            ProgressView(value: progress)
                .tint(model.isSeeding ? .green : .blue)
                .animation(.default, value: progress)
        }
    }
}
