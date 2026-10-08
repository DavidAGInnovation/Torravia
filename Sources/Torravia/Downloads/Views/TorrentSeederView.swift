import TorraviaSearchCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TorrentSeederView: View {
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @State private var data: Data?
    @State private var fileName: String
    @State private var contentName = ""
    @State private var source: URL?
    @State private var isSourceValid = false
    @State private var isSingleFile = false
    @State private var message = ""
    @State private var added = false
    init(data: Data? = nil, fileName: String = "", source: URL? = nil) {
        _data = State(initialValue: data)
        _fileName = State(initialValue: fileName)
        _source = State(initialValue: source)
    }

    private var requiresFolder: Bool { data != nil && !isSingleFile }

    private var contentInstructions: String {
        guard data != nil else {
            return "Choose a torrent first, then select its original file or folder to share."
        }
        if isSingleFile {
            return "Select the original file or the folder containing it. Torravia looks for “\(contentName)” inside the selected folder."
        }
        return "Select the original folder to share. The files inside must match the torrent’s folder layout."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add Torrent for Seeding", systemImage: "arrow.up.circle").font(.title2.bold())
            Text("Share the original files with other peers. Torravia verifies their piece hashes before seeding.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Torrent file").font(.caption).foregroundStyle(.secondary)
                    Text(fileName.isEmpty ? "Choose a .torrent file" : fileName).lineLimit(2)
                }
                Spacer()
                Button("Choose Torrent…", action: chooseTorrent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(contentName.isEmpty ? "Original content" : "Original \(isSingleFile ? "file" : "folder"): “\(contentName)”")
                    .font(.headline)
                Text(contentInstructions)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(source?.path ?? (requiresFolder ? "No folder selected" : "No file or folder selected")).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button(requiresFolder ? "Choose Folder…" : "Choose File or Folder…", action: chooseSource).disabled(data == nil || added)
                }
            }
            Text("Your original files stay in place. Removing this torrent from Transfers keeps them on your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Start Seeding", action: startSeeding)
                    .disabled(data == nil || source == nil || !isSourceValid || added).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear { updateContentName() }
    }

    private func updateContentName() {
        isSourceValid = false
        contentName = data.flatMap { try? DownloadsViewModel.parseTorrentFile(data: $0)?.name } ?? ""
        if let data, case .dictionary(let root) = try? Bencode.decode(data: data),
           case .dictionary(let info) = root["info"],
           let layout = try? DownloadsViewModel.originalTorrentLayout(info: info) {
            isSingleFile = layout.isSingleFile
        } else { isSingleFile = false }
        if source == nil, let data {
            do {
                source = try downloadsVM.torrentSourceStore.source(for: data)
                if source != nil { message = "Using the remembered original content location." }
            } catch {
                message = "The remembered original content is unavailable. Choose its current file or folder."
            }
        }
        if source != nil { validateSource() }
    }

    @discardableResult
    private func validateSource() -> Bool {
        isSourceValid = false
        guard let data, let source else { return false }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        do {
            _ = try DownloadsViewModel.originalSeedDownload(data: data,
                fileName: fileName, source: source, bookmark: nil)
            isSourceValid = true
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func chooseTorrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            data = try Data(contentsOf: url)
            fileName = url.lastPathComponent
            source = nil
            isSourceValid = false
            added = false
            message = ""
            updateContentName()
        } catch { message = error.localizedDescription }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = isSingleFile
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = source?.deletingLastPathComponent()
        panel.message = isSingleFile ? "Choose “\(contentName)” or the folder containing it."
            : "Choose the original folder for “\(contentName)”."
        panel.prompt = isSingleFile ? "Choose Content" : "Choose Folder"
        if panel.runModal() == .OK, let selected = panel.url, let data {
            source = selected
            message = ""
            guard validateSource() else { return }
            do { try downloadsVM.torrentSourceStore.remember(data: data, source: selected) }
            catch let error as OriginalSeedingError { message = error.localizedDescription }
            catch { message = "The location could not be remembered: \(error.localizedDescription)" }
        }
    }

    private func startSeeding() {
        guard !added, isSourceValid, let data, let source, validateSource() else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        do {
            _ = try downloadsVM.seedOriginalTorrent(data: data, fileName: fileName, source: source)
            added = true
            message = "Added to Transfers. The original files are being verified; seeding starts when verification finishes."
        } catch {
            validateSource()
            message = error.localizedDescription
        }
    }
}
