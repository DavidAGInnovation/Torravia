#if os(macOS)
import AppKit
import SwiftUI

struct UnifiedSettingsPane: NSViewRepresentable {
    let category: SettingsCategory
    let preferences: SeedingPreferencesStore
    let searchPreferences: SearchPreferencesStore
    let downloadLocation: DownloadLocationStore
    let downloadsVM: DownloadsViewModel
    let automation: DownloadAutomationStore
    let providerHealth: ProviderHealthStore

    func makeNSView(context: Context) -> UnifiedSettingsDocumentView {
        UnifiedSettingsDocumentView(
            category: category,
            preferences: preferences,
            searchPreferences: searchPreferences,
            downloadLocation: downloadLocation,
            downloadsVM: downloadsVM,
            automation: automation,
            providerHealth: providerHealth
        )
    }

    func updateNSView(_ nsView: UnifiedSettingsDocumentView, context: Context) {}
}

#endif
