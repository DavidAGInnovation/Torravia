import AppKit
import UniformTypeIdentifiers

@MainActor
enum RemoteCertificatePanel {
    static func present(preferences: SeedingPreferencesStore, parent: NSWindow?, completion: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import HTTPS Certificate"
        panel.message = "Choose a PKCS#12 certificate and private key. They will be saved in macOS Keychain."
        panel.prompt = "Import"
        panel.allowedContentTypes = [UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        password.placeholderString = "Certificate password"
        password.setAccessibilityLabel("Certificate password")
        password.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Certificate password:"), password])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        let importSelection: (NSApplication.ModalResponse) -> Void = { response in
            defer { password.stringValue = "" }
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 4 * 1024 * 1024 else { throw RemoteTLSError.invalidFile }
                let identity = try RemoteTLSIdentity.importPKCS12(Data(contentsOf: url), password: password.stringValue)
                // Resolve before replacing the working configuration.
                _ = try identity.protocolIdentity()
                preferences.remoteControlTLSIdentity = identity
                preferences.remoteControlUsesHTTPS = true
                completion()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Certificate could not be imported"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
            }
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: importSelection) }
        else { importSelection(panel.runModal()) }
    }
}
