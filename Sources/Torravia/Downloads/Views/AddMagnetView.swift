import TorraviaSearchCore
//
//  AddMagnetView.swift
//  Torravia
//
//  Magnet-link and .torrent-file import flow.
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct AddMagnetView: View {
    enum Payload {
        case magnet(String, String?)
        case torrent(URL)
    }

    @Binding var isPresented: Bool
    var onAdd: (Payload) -> Void

    @State private var magnetInput: String = ""
    @State private var invalidEntries: [String] = []
    @State private var validatedMagnets: [String] = []
    @State private var hasValidated: Bool = false
    @State private var droppedTorrents: [DroppedTorrent] = []
    @FocusState private var isFocused: Bool
#if os(macOS)
    @State private var isMagnetDropTargeted: Bool = false
    @State private var isTorrentDropTargeted: Bool = false
#endif

    private let editorInsets = EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
    private let placeholderOffset = CGSize(width: 5, height: 1)

    private var tokens: [String] {
        magnetInput
            .replacingOccurrences(of: ",", with: " ")
            .split { $0.isWhitespace || $0 == "\n" || $0 == "\r" || $0 == "\t" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var validDroppedTorrents: [DroppedTorrent] {
        droppedTorrents.filter { $0.metadata.infoHash != nil }
    }

    private var invalidDroppedTorrentCount: Int {
        droppedTorrents.count - validDroppedTorrents.count
    }

    private var isValidMagnet: Bool { !validatedMagnets.isEmpty || !validDroppedTorrents.isEmpty }

    private var hasInput: Bool {
        !magnetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !droppedTorrents.isEmpty
    }

    private var addButtonTitle: String { "Add" }

    private var canPasteFromClipboard: Bool {
        guard let value = ClipboardReader.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                header
                inputSection
                statusSection
                previewSection
                droppedTorrentsSection
                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#if os(macOS)
            .frame(minWidth: 440, idealWidth: 460, maxWidth: 540, minHeight: 400, idealHeight: 430)
#endif
            .navigationTitle("Add Torrent")
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addButtonTitle) {
                        addMagnets()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidMagnet)
                }
#endif
            }
            .onAppear { isFocused = true; runValidation() }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: validatedMagnets.count)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: invalidEntries.count)
            .textSelection(.enabled)
        }
    }

    private var header: some View {
        Label("Enter magnet links to import or drop .torrent files.", systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("Magnet Links", systemImage: "link")
                    .font(.headline)
                Spacer()
                Button(action: appendClipboard) {
                    Label("Paste Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(!canPasteFromClipboard)
                .help("Append any text magnet links currently on the clipboard")
            }

            ZStack(alignment: .topLeading) {
                backgroundChrome

                dropTarget
            }

            Text("Separate links with spaces, commas, or line breaks.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Group {
            if hasValidated && !invalidEntries.isEmpty {
                Label("\(invalidEntries.count) item\(invalidEntries.count == 1 ? "" : "s") ignored — ensure magnet links include xt=urn:btih…", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if invalidDroppedTorrentCount > 0 {
                Label("\(invalidDroppedTorrentCount) file\(invalidDroppedTorrentCount == 1 ? "" : "s") ignored — only valid .torrent files are supported.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if hasValidated && !validatedMagnets.isEmpty {
                Label("Looks good!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var previewSection: some View {
        if !validatedMagnets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview")
                    .font(.headline)
                ForEach(validatedMagnets.prefix(5), id: \.self) { magnet in
                    MagnetPreviewRow(magnet: magnet, title: displayTitle(for: magnet))
                }
                if validatedMagnets.count > 5 {
                    Text("…and \(validatedMagnets.count - 5) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
    }

    private var dropTarget: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $magnetInput)
                .background(Color.clear)
                .font(.callout.monospaced())
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .padding(.top, editorInsets.top)
                .padding(.bottom, editorInsets.bottom)
                .padding(.leading, editorInsets.leading)
                .padding(.trailing, editorInsets.trailing)
                .background(Color.clear)
                .frame(minHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isFocused ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 2)
                        .animation(.easeInOut(duration: 0.2), value: isFocused)
                )

            if magnetInput.isEmpty {
                Text("Paste one or more magnet links…")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, editorInsets.top)
                    .padding(.leading, editorInsets.leading)
                    .offset(x: placeholderOffset.width, y: placeholderOffset.height)
            }
        }
#if os(macOS)
        .onDrop(of: dropTypes, isTargeted: $isMagnetDropTargeted) { providers in
                handleFileDrops(providers: providers)
        }
#endif
    }

#if os(macOS)
    private var dropTypes: [UTType] {
        var types: [UTType] = [.fileURL]
        if let torrentType = UTType(filenameExtension: "torrent") {
            types.append(torrentType)
        }
        types.append(.item)
        return types
    }

    private var filePromiseTypeIdentifier: String {
        "com.apple.NSFilePromiseType"
    }

    private var backgroundChrome: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(dropBackground(isTargeted: isMagnetDropTargeted, hasItems: !droppedTorrents.isEmpty))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }

    private func dropBackground(isTargeted: Bool, hasItems: Bool) -> some ShapeStyle {
        if isTargeted {
            return AnyShapeStyle(Color.accentColor.opacity(0.25))
        } else if hasItems {
            return AnyShapeStyle(Color.white.opacity(0.12))
        } else {
            return AnyShapeStyle(Color.white.opacity(0.05))
        }
    }

    private var droppedTorrentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Label("Torrent Files", systemImage: "doc.badge.arrow.up")
                    if !droppedTorrents.isEmpty {
                        Text("\(droppedTorrents.count)")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.headline)
                Spacer()
                if !droppedTorrents.isEmpty {
                    Button(role: .destructive) {
                        droppedTorrents.removeAll()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.bordered)
                }
            }

            if droppedTorrents.isEmpty {
                Text("Drag and drop .torrent files here to import them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(droppedTorrents) { item in
                            DroppedTorrentRow(torrent: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 260)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
#if os(macOS)
            if invalidDroppedTorrentCount > 0 {
                Label("\(invalidDroppedTorrentCount) unsupported file\(invalidDroppedTorrentCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
#endif
#if os(macOS)
            HStack {
        Spacer()
        Button("Choose File…") {
            presentOpenPanel()
        }
        .buttonStyle(.borderedProminent)
            }
#endif
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(dropBackground(isTargeted: isTorrentDropTargeted, hasItems: !droppedTorrents.isEmpty))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isTorrentDropTargeted ? Color.accentColor.opacity(0.65) : Color.gray.opacity(0.25), lineWidth: isTorrentDropTargeted ? 2 : 1)
        )
        .onDrop(of: dropTypes, isTargeted: $isTorrentDropTargeted) { providers in
            handleFileDrops(providers: providers)
        }
    }
#endif

    private func handleInputChanged(_ newValue: String) {
        hasValidated = false
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validatedMagnets = []
            invalidEntries = []
        } else if !hasValidated {
            runValidation()
        }
    }

    private func addMagnets() {
        runValidation()
        let validMagnets = validatedMagnets
        let torrents = validDroppedTorrents

        guard !validMagnets.isEmpty || !torrents.isEmpty else { return }

        for link in validMagnets {
            onAdd(.magnet(link, nil))
        }

#if os(macOS)
        for item in torrents {
            onAdd(.torrent(item.url))
        }
        droppedTorrents.removeAll()
#endif

        isPresented = false
    }

    private func displayTitle(for magnet: String) -> String {
        guard let components = MagnetLink.components(magnet),
              let dn = components.queryItems?.first(where: { $0.name.lowercased() == "dn" })?.value,
              !dn.isEmpty else {
            return magnet
        }
        return dn
    }

    private func appendClipboard() {
        guard let clip = ClipboardReader.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty else { return }
        if magnetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            magnetInput = clip
        } else {
            magnetInput += magnetInput.hasSuffix("\n") ? clip : "\n" + clip
        }
        runValidation()
    }

    private func runValidation() {
        let entries = tokens
        let valid = entries.filter(DownloadsViewModel.isValidMagnetLink)
        let invalid = entries.filter { !DownloadsViewModel.isValidMagnetLink($0) }
        validatedMagnets = valid
        invalidEntries = invalid
        hasValidated = true
    }

    private enum ClipboardReader {
        static var string: String? {
#if os(macOS)
            NSPasteboard.general.string(forType: .string)
#endif
        }
    }

#if os(macOS)
    private func handleFileDrops(providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let fileURL = resolvedFileURL(from: item), fileURL.pathExtension.lowercased() == "torrent" else { return }
                    let name = resolvedFileName(from: item) ?? fileURL.lastPathComponent
                    ingestTorrentFile(from: fileURL, originalFilename: name)
                }
                continue
            }

            if let torrentType = UTType(filenameExtension: "torrent"), provider.hasItemConformingToTypeIdentifier(torrentType.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: torrentType.identifier) { data, _ in
                    guard let data else { return }
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("torrent")
                    do {
                        try data.write(to: tempURL, options: [.atomic])
                        let name = resolvedFileName(from: data as NSSecureCoding?) ?? tempURL.lastPathComponent
                        ingestTorrentFile(from: tempURL, originalFilename: name)
                    } catch {
                        print("Failed to import dropped torrent: \(error)")
                    }
                }
            }

            if provider.hasItemConformingToTypeIdentifier(filePromiseTypeIdentifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: filePromiseTypeIdentifier) { data, _ in
                    guard let data else { return }
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("torrent")
                    do {
                        try data.write(to: tempURL, options: [.atomic])
                        let name = resolvedFileName(from: data as NSSecureCoding?) ?? tempURL.lastPathComponent
                        ingestTorrentFile(from: tempURL, originalFilename: name)
                    } catch {
                        print("Failed to import promised torrent file: \(error)")
                    }
                }
            }
        }

        return handled
    }
#endif

    private func appendDroppedTorrent(url: URL, originalFilename: String, metadata: DroppedTorrent.Metadata) async {
        await MainActor.run {
            if let index = droppedTorrents.firstIndex(where: { $0.url == url }) {
                droppedTorrents[index].metadata = metadata
            } else {
                droppedTorrents.append(.init(url: url, originalFilename: originalFilename, metadata: metadata))
            }
        }
    }

    @MainActor
    private func presentOpenPanel() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select .torrent files to import"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                ingestTorrentFile(from: url, originalFilename: url.lastPathComponent)
            }
        }
#endif
    }

    private func ingestTorrentFile(from url: URL, originalFilename: String) {
        guard !droppedTorrents.contains(where: { $0.url == url }) else { return }
        Task.detached(priority: .userInitiated) {
#if os(macOS)
            let securityScoped = url.startAccessingSecurityScopedResource()
            defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
#endif
            let metadata: DroppedTorrent.Metadata
            do {
                let summary = try DownloadsViewModel.parseTorrentFile(at: url)
                metadata = DroppedTorrent.Metadata(
                    name: summary.name,
                    totalSize: summary.totalSize,
                    fileCount: summary.fileCount,
                    infoHash: summary.infoHash,
                    rawSize: summary.rawSize
                )
            } catch {
                let fallbackSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                metadata = DroppedTorrent.Metadata(name: url.deletingPathExtension().lastPathComponent, totalSize: nil, fileCount: nil, infoHash: nil, rawSize: fallbackSize)
            }
            await appendDroppedTorrent(url: url, originalFilename: originalFilename, metadata: metadata)
        }
    }

    private func resolvedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
        }
        return nil
    }

    private func resolvedFileName(from item: NSSecureCoding?) -> String? {
        if let url = resolvedFileURL(from: item) {
            return url.lastPathComponent
        }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           !string.isEmpty {
            return URL(fileURLWithPath: string).lastPathComponent
        }
        return nil
    }

    private struct MagnetPreviewRow: View {
        let magnet: String
        let title: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(magnet)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DroppedTorrent: Identifiable, Equatable {
    struct Metadata: Equatable {
        let name: String
        let totalSize: Int64?
        let fileCount: Int?
        let infoHash: String?
        let rawSize: Int
    }

    let id = UUID()
    let url: URL
    let originalFilename: String
    var metadata: Metadata
}

private struct DroppedTorrentRow: View {
    let torrent: DroppedTorrent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
                Text(torrent.metadata.name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 12) {
                if let size = torrent.metadata.totalSize {
                    Label(size.byteCountFormatted, systemImage: "internaldrive")
                } else {
                    Label("Torrent: \(torrent.metadata.rawSize.byteCountFormatted)", systemImage: "doc")
                }
                if let hash = torrent.metadata.infoHash {
                    Label(String(hash.prefix(8)) + "…", systemImage: "number")
                } else {
                    Label("Source: \(torrent.originalFilename)", systemImage: "doc.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thickMaterial)
        )
    }
}

#if os(macOS)
private enum TorrentMetadataLoader {
    static func load(from url: URL) async throws -> DroppedTorrent.Metadata {
        let summary = try DownloadsViewModel.parseTorrentFile(at: url)
        return DroppedTorrent.Metadata(
            name: summary.name,
            totalSize: summary.totalSize,
            fileCount: summary.fileCount,
            infoHash: summary.infoHash,
            rawSize: summary.rawSize
        )
    }
}
#endif
