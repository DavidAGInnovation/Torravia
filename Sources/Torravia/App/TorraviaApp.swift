//
//  TorraviaApp.swift
//  Torravia
//
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TorraviaApp: App {
    @StateObject private var seedingPreferences: SeedingPreferencesStore
    @StateObject private var downloadsVM: DownloadsViewModel
    @StateObject private var searchPreferences: SearchPreferencesStore
    @StateObject private var downloadLocation: DownloadLocationStore
    @StateObject private var automation: DownloadAutomationStore
    @StateObject private var providerHealth: ProviderHealthStore

    init() {
        let preferences = SeedingPreferencesStore.shared
        let searchPrefs = SearchPreferencesStore.shared
        let location = DownloadLocationStore.shared
        let automationStore = DownloadAutomationStore.shared
        let healthStore = ProviderHealthStore.shared
        _seedingPreferences = StateObject(wrappedValue: preferences)
        _downloadsVM = StateObject(wrappedValue: DownloadsViewModel(preferences: preferences,
                                                                    downloadLocation: location))
        _searchPreferences = StateObject(wrappedValue: searchPrefs)
        _downloadLocation = StateObject(wrappedValue: location)
        _automation = StateObject(wrappedValue: automationStore)
        _providerHealth = StateObject(wrappedValue: healthStore)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloadsVM)
                .environmentObject(seedingPreferences)
                .environmentObject(searchPreferences)
                .environmentObject(downloadLocation)
                .environmentObject(automation)
                .environmentObject(providerHealth)
                .task {
                    providerHealth.checkAll()
                }
                // Make informational text selectable throughout the app,
                // including sheets and popovers presented from this window.
                .textSelection(.enabled)
        }
        .defaultSize(width: 800, height: 620)
        .commands { TorrentCreationCommands() }

        Window("Create Torrent", id: "torrent-creator") {
            TorrentCreatorView().environmentObject(downloadsVM)
        }
            .windowResizability(.contentSize)

        Window("Add Torrent for Seeding", id: "torrent-seeder") {
            TorrentSeederView().environmentObject(downloadsVM)
        }
            .windowResizability(.contentSize)

        Window("Edit Torrent", id: "torrent-editor") {
            TorrentCreatorView(isEditing: true).environmentObject(downloadsVM)
        }
            .windowResizability(.contentSize)

#if os(macOS)
        Settings {
            NativeSettingsWindow()
                .environmentObject(downloadsVM)
                .environmentObject(seedingPreferences)
                .environmentObject(searchPreferences)
                .environmentObject(downloadLocation)
                .environmentObject(automation)
                .environmentObject(providerHealth)
        }
        .windowResizability(.contentSize)
#endif
    }
}

#if os(macOS)
/// Applies the initial content size once, including a restored larger frame.
struct MainWindowSizeController: NSViewRepresentable {
    let contentSize: CGSize

    func makeNSView(context: Context) -> ControllerView { ControllerView(contentSize: contentSize) }
    func updateNSView(_ nsView: ControllerView, context: Context) {
        nsView.contentSize = contentSize
        nsView.applySizeIfNeeded()
    }

    final class ControllerView: NSView {
        var contentSize: CGSize
        private var didApplySize = false
        init(contentSize: CGSize) {
            self.contentSize = contentSize
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) {
            contentSize = .zero
            super.init(coder: coder)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySizeIfNeeded()
        }
        func applySizeIfNeeded() {
            guard !didApplySize, let window else { return }
            didApplySize = true
            let previousFrame = window.frame
            let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
            var frame = previousFrame
            frame.size = targetFrame.size
            frame.origin.y = previousFrame.maxY - frame.height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
#endif
