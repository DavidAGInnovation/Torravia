import AppKit

@MainActor
enum AlternativeWebUIPanel {
    static func present(preferences: SeedingPreferencesStore, parent: NSWindow?, completion: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Browser Interface"
        panel.message = "Choose a trusted Torravia-compatible interface folder containing index.html."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                _ = try RemoteWebUIAssets(directory: url)
                preferences.remoteWebUIBookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                                      includingResourceValuesForKeys: nil, relativeTo: nil)
                completion()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Cannot use this browser interface"
                alert.informativeText = error.localizedDescription
                if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
            }
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: handle) }
        else { panel.begin(completionHandler: handle) }
    }
}
