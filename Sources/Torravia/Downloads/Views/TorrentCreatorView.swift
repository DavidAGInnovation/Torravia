import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TorrentCreatorView: View {
    var isEditing = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @State private var source: URL?
    @State private var trackers = ""
    @State private var comment = ""
    @State private var isPrivate = false
    @State private var format: TorrentFormat = .hybrid
    @State private var pieceLength = 0
    @State private var progress = 0.0
    @State private var isWorking = false
    @State private var message = ""
    @State private var job: Task<Void, Never>?
    @State private var savedCreation: SavedCreation?
    @State private var hasStartedSeeding = false
    @State private var allowClose = false
    @State private var windowReference = WindowReference()
    @State private var draftID = UUID()

    private final class WindowReference { weak var window: NSWindow? }

    private struct CreationInput: Equatable, Sendable {
        let source: URL?
        let options: TorrentCreationOptions
    }

    private struct SavedCreation {
        let input: CreationInput
        let result: CreatedTorrent
        let output: URL

        var summary: String {
            var text = "Saved \(output.lastPathComponent) · \(result.fileCount) file(s)"
            if let hash = result.v1InfoHash { text += "\nv1 info hash: \(hash)" }
            if let hash = result.v2InfoHash { text += "\nv2 info hash: \(hash)" }
            return text
        }
    }

    private var currentInput: CreationInput {
        return CreationInput(source: source, options: TorrentCreationOptions(
            format: format, trackers: trackers.split(whereSeparator: \.isNewline).map(String.init),
            comment: comment, isPrivate: isPrivate, pieceLength: pieceLength))
    }

    private var hasUnsavedChanges: Bool {
        guard let savedCreation else {
            return source != nil || !comment.isEmpty || !trackers.isEmpty || isPrivate
        }
        return currentInput != savedCreation.input
    }

    private var canSave: Bool { source != nil || savedCreation != nil }

    private var requiresOriginalContent: Bool {
        guard let savedCreation else { return true }
        return currentInput.source != savedCreation.input.source || format != savedCreation.input.options.format
            || pieceLength != savedCreation.input.options.pieceLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Torrent" : "Create Torrent").font(.title2.bold())
            Text(isEditing
                 ? "Update a saved torrent’s sharing settings. Changes to its content, format, or piece size require the original files and create a new torrent to share."
                 : "Create a .torrent file to share a file or folder. Save it for later, or save and seed the selected content so others can download it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isEditing {
                HStack {
                    Text(savedCreation?.output.path ?? "Choose a .torrent file to edit")
                        .lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if savedCreation == nil { Button("Choose Torrent…", action: chooseTorrent) }
                }
            }
            HStack {
                Text(source?.path ?? (isEditing ? "Original content has not been located" : "Choose the content to share"))
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Choose…", action: chooseSource).disabled(isWorking || (isEditing && savedCreation == nil))
            }
            Form {
                Picker("Torrent format", selection: $format) {
                    ForEach(TorrentFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                Text(format.explanation).font(.caption).foregroundStyle(.secondary)
                TextField("Comment", text: $comment)
                Picker("Piece size", selection: $pieceLength) {
                    Text("Automatic").tag(0)
                    ForEach(TorrentCreationPreferences.pieceLengths.filter { $0 > 0 }.map { $0 / 1024 }, id: \.self) { size in
                        Text(size < 1024 ? "\(size) KiB" : "\(size / 1024) MiB").tag(size * 1024)
                    }
                }
                Toggle("Private torrent (requires a tracker)", isOn: $isPrivate)
            }.disabled(isWorking || (isEditing && savedCreation == nil))
            Text("Trackers — one HTTP, HTTPS, or UDP address per line").font(.caption)
            TextEditor(text: $trackers).font(.system(.body, design: .monospaced)).frame(height: 90).border(.separator)
                .disabled(isWorking || (isEditing && savedCreation == nil))
            if isWorking { ProgressView(value: progress); Text("Hashing content… \(Int(progress * 100))%").font(.caption) }
            if hasUnsavedChanges {
                Text(savedCreation == nil ? "Unsaved torrent" : "Unsaved changes — save your changes before seeding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let savedCreation {
                Text(savedCreation.summary).textSelection(.enabled).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !message.isEmpty {
                Text(message).textSelection(.enabled).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isWorking {
                    Button("Cancel") { job?.cancel() }
                } else if savedCreation != nil {
                    Button("Done", action: requestClose).keyboardShortcut(.cancelAction)
                    Button("Save As…") { save(seedAfterSaving: false, chooseDestination: true) }
                        .help("Save a separate copy of the torrent, including any edits.")
                    if hasUnsavedChanges {
                        Button("Save Changes") { save(seedAfterSaving: false, chooseDestination: false) }
                            .keyboardShortcut(.defaultAction)
                        Button("Save & Seed") { save(seedAfterSaving: true, chooseDestination: false) }
                            .disabled(source == nil)
                            .help("Save your changes and start sharing the selected content.")
                    } else {
                        Button("Start Seeding", action: startSeedingSavedTorrent)
                            .disabled(hasStartedSeeding || source == nil).keyboardShortcut(.defaultAction)
                    }
                } else if isEditing {
                    Button("Done", action: requestClose).keyboardShortcut(.cancelAction)
                } else {
                    Button("Create & Save…") { save(seedAfterSaving: false, chooseDestination: true) }
                        .disabled(source == nil).keyboardShortcut(.defaultAction)
                    Button("Create & Seed…") { save(seedAfterSaving: true, chooseDestination: true) }
                        .disabled(source == nil)
                        .help("Save the torrent and start sharing the selected content.")
                }
            }
        }.padding(24).frame(width: 560)
        .onAppear {
            resetDraft()
            if isEditing { DispatchQueue.main.async { chooseTorrent() } }
        }
        .onDisappear { job?.cancel(); resetDraft() }
        .onChange(of: format) { _, value in
            if !isEditing { UserDefaults.standard.set(value.rawValue, forKey: TorrentCreationPreferences.formatKey) }
        }
        .onChange(of: pieceLength) { _, value in
            if !isEditing { UserDefaults.standard.set(value, forKey: TorrentCreationPreferences.pieceLengthKey) }
        }
        .background(TorrentCreatorInitialFocus().frame(width: 0, height: 0))
        .background(TorrentCreatorWindowBridge(shouldClose: confirmClose, didClose: resetDraft,
                    attachWindow: { windowReference.window = $0 }).frame(width: 0, height: 0))
    }

    private func resetDraft() {
        job?.cancel(); job = nil
        draftID = UUID()
        source = nil; trackers = ""; comment = ""; isPrivate = false
        format = TorrentCreationPreferences.format(in: .standard)
        pieceLength = TorrentCreationPreferences.pieceLength(in: .standard)
        savedCreation = nil; message = ""; progress = 0; isWorking = false
        hasStartedSeeding = false; allowClose = false
    }

    private func requestClose() {
        if let window = windowReference.window { window.performClose(nil) }
        else if confirmClose() { dismiss() }
    }

    private func closeWithoutPrompt() {
        allowClose = true
        requestClose()
    }

    private func confirmClose() -> Bool {
        if allowClose { return true }
        if isWorking {
            let alert = NSAlert()
            alert.messageText = "Cancel torrent creation?"
            alert.informativeText = "Creation is still in progress. The last saved torrent will be kept."
            alert.addButton(withTitle: "Keep Working")
            alert.addButton(withTitle: "Cancel Creation")
            if alert.runModal() == .alertSecondButtonReturn { job?.cancel(); return true }
            return false
        }
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = savedCreation == nil ? "Save this torrent before closing?" : "Save changes before closing?"
        alert.informativeText = "Your unsaved changes will be lost if you discard them."
        alert.addButton(withTitle: savedCreation == nil ? "Create & Save…" : "Save Changes")
            .isEnabled = canSave
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(seedAfterSaving: false, chooseDestination: savedCreation == nil, closeAfterSaving: true)
            return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func chooseTorrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.prompt = "Edit Torrent"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let accessing = output.startAccessingSecurityScopedResource()
        defer { if accessing { output.stopAccessingSecurityScopedResource() } }
        do {
            let details = try TorrentMetadataEditor.read(data: Data(contentsOf: output))
            let options = details.options
            source = try? downloadsVM.torrentSourceStore.source(for: details.result.data)
            trackers = options.trackers.joined(separator: "\n"); comment = options.comment
            format = options.format; isPrivate = options.isPrivate; pieceLength = options.pieceLength
            savedCreation = SavedCreation(input: currentInput, result: details.result, output: output)
            message = source == nil
                ? "Trackers and comments can be edited now. Choose the original content before seeding or changing its format or piece size." : ""
        } catch { message = error.localizedDescription }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Content"
        panel.message = "Choose the original file or folder to share. For an existing .torrent file, use Add Torrent for Seeding."
        let delegate = TorrentCreationSourcePickerDelegate()
        panel.delegate = delegate
        if withExtendedLifetime(delegate, { panel.runModal() }) == .OK {
            guard let selected = panel.url else { return }
            // Locating missing originals does not itself change torrent metadata.
            if let savedCreation, savedCreation.input.source == nil {
                let accessing = selected.startAccessingSecurityScopedResource()
                defer { if accessing { selected.stopAccessingSecurityScopedResource() } }
                do {
                    let download = try DownloadsViewModel.originalSeedDownload(data: savedCreation.result.data,
                        fileName: savedCreation.output.lastPathComponent, source: selected, bookmark: nil)
                    guard let resolved = download.destinationURL else { throw TorrentCreationError.invalidSource }
                    source = resolved
                    self.savedCreation = SavedCreation(input: CreationInput(source: resolved,
                        options: savedCreation.input.options), result: savedCreation.result, output: savedCreation.output)
                    try downloadsVM.torrentSourceStore.remember(data: savedCreation.result.data, source: resolved)
                    message = ""
                } catch { message = error.localizedDescription }
            } else { source = selected; message = "" }
        }
    }

    private func save(seedAfterSaving: Bool, chooseDestination: Bool, closeAfterSaving: Bool = false) {
        let input = currentInput
        let operationDraftID = draftID
        let source = input.source
        // Keep the last successful save available if hashing, writing, or the save panel is cancelled.
        let previousSave = savedCreation
        isWorking = true; progress = 0; message = ""
        let needsOriginals = requiresOriginalContent
        let accessing = source?.startAccessingSecurityScopedResource() ?? false
        job = Task {
            defer {
                if draftID == operationDraftID { isWorking = false }
                if accessing { source?.stopAccessingSecurityScopedResource() }
            }
            do {
                let result: CreatedTorrent
                if let previousSave, previousSave.input == input {
                    result = previousSave.result
                } else if let previousSave, !needsOriginals {
                    // The saved input may use Automatic; the existing metadata has the resolved piece size.
                    var options = input.options
                    options.pieceLength = previousSave.result.pieceLength
                    result = try TorrentMetadataEditor.update(data: previousSave.result.data, options: options)
                } else {
                    guard let source else { throw TorrentCreationError.originalsRequired }
                    let worker = Task.detached(priority: .userInitiated) {
                        try TorrentCreator.create(source: source, options: input.options) { value in
                            Task { @MainActor in
                                if draftID == operationDraftID { progress = value }
                            }
                        }
                    }
                    result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                }
                try Task.checkCancellation()
                guard draftID == operationDraftID else { return }
                let output: URL
                if !chooseDestination, let previousSave {
                    output = previousSave.output
                } else {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
                    if let previousSave {
                        panel.title = "Save Torrent As"
                        panel.directoryURL = previousSave.output.deletingLastPathComponent()
                        let name = previousSave.input.source == source
                            ? previousSave.output.deletingPathExtension().lastPathComponent : result.name
                        panel.nameFieldStringValue = "\(name)-copy.torrent"
                    } else {
                        panel.nameFieldStringValue = "\(result.name).torrent"
                    }
                    guard panel.runModal() == .OK, let destination = panel.url else {
                        message = "Save cancelled."
                        return
                    }
                    output = destination
                }
                try Task.checkCancellation()
                let accessingOutput = output.startAccessingSecurityScopedResource()
                defer { if accessingOutput { output.stopAccessingSecurityScopedResource() } }
                try result.data.write(to: output, options: .atomic)
                savedCreation = SavedCreation(input: input, result: result, output: output)
                hasStartedSeeding = false
                if let source {
                    do { try downloadsVM.torrentSourceStore.remember(data: result.data, source: source) }
                    catch { message = "The torrent was saved, but its original location could not be remembered: \(error.localizedDescription)" }
                }
                if seedAfterSaving { startSeedingSavedTorrent() }
                else if closeAfterSaving { closeWithoutPrompt() }
            } catch is CancellationError {
                if draftID == operationDraftID { message = "Creation cancelled." }
            } catch {
                if draftID == operationDraftID { message = error.localizedDescription }
            }
        }
    }

    private func startSeedingSavedTorrent() {
        guard let savedCreation, !hasUnsavedChanges, !hasStartedSeeding,
              let source = savedCreation.input.source else { return }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        do {
            _ = try downloadsVM.seedOriginalTorrent(data: savedCreation.result.data,
                                                   fileName: savedCreation.output.lastPathComponent, source: source)
            hasStartedSeeding = true
            closeWithoutPrompt()
        } catch {
            message = "The torrent was saved, but seeding could not start: \(error.localizedDescription)"
        }
    }
}

private final class TorrentCreationSourcePickerDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.pathExtension.lowercased() != "torrent" ||
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard panel(sender, shouldEnable: url) else { throw TorrentCreationError.torrentMetadataSource }
    }
}

private struct TorrentCreatorInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialFocusView { InitialFocusView() }
    func updateNSView(_ nsView: InitialFocusView, context: Context) {}

    final class InitialFocusView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Prevent AppKit from choosing the first text field when opening the window.
            window.initialFirstResponder = self
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(window)
            }
        }
    }
}

struct TorrentCreationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Create Torrent…") { openWindow(id: "torrent-creator") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Edit Torrent…") { openWindow(id: "torrent-editor") }
            Button("Add Torrent for Seeding…") { openWindow(id: "torrent-seeder") }
        }
    }
}
