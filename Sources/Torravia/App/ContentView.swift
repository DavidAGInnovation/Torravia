//
//  ContentView.swift
//  Torravia
//
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var seedingPreferences: SeedingPreferencesStore
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @EnvironmentObject private var searchPreferences: SearchPreferencesStore
    @EnvironmentObject private var downloadLocation: DownloadLocationStore
    @EnvironmentObject private var automation: DownloadAutomationStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        TabView {
            NavigationStack {
                SearchView()
                    .navigationTitle("Search")
#if os(macOS)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) { settingsButton }
                    }
#endif
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
                    .textSelection(.disabled)
            }

            NavigationStack {
                DownloadsView()
                    .navigationTitle("Transfers")
#if os(macOS)
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button("Create Torrent", systemImage: "doc.badge.plus") { openWindow(id: "torrent-creator") }
                            seedingMenu
                            settingsButton
                        }
                    }
#endif
            }
            .tabItem {
#if os(macOS)
                Image(nsImage: transfersTabImage(count: downloadsVM.downloadingCount))
                    .accessibilityLabel(downloadsVM.downloadingCount == 0 ? "Transfers"
                        : downloadsVM.downloadingCount == 1 ? "Transfers, 1 active download"
                        : "Transfers, \(downloadsVM.downloadingCount) active downloads")
#else
                Label("Transfers", systemImage: "arrow.down.circle")
#endif
            }
        }
        .textSelection(.enabled)
#if os(macOS)
        .overlay {
            MainWindowSizeController(contentSize: CGSize(width: 800, height: 620))
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
#endif
        .environmentObject(downloadsVM)
        .environmentObject(seedingPreferences)
        .environmentObject(searchPreferences)
        .environmentObject(downloadLocation)
        .environmentObject(automation)
        .environmentObject(ProviderHealthStore.shared)
    }
}

/// Empty-state presentation whose title and message live in one selectable
/// text view. Keeping the two strings together lets a drag selection continue
/// from the heading into the explanatory text below it.
struct SelectableEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.secondary)

                SelectableEmptyStateText(title: title, message: message)
                    .frame(width: min(560, max(1, geometry.size.width)))
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding()
    }
}

#if os(macOS)
private struct SelectableEmptyStateText: NSViewRepresentable {
    let title: String
    let message: String

    func makeNSView(context: Context) -> NSTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        applyText(to: textView)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        applyText(to: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 800)
        // SwiftUI probes several widths during layout. Measure a separate
        // document so a probe cannot change the displayed text container.
        let storage = NSTextStorage(attributedString: nsView.attributedString())
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height))
    }

    private func applyText(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        ))
        text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 24)]))
        text.append(NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
        SelectableDocument.update(textView, with: text)
    }
}

#else
private struct SelectableEmptyStateText: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
            Text(message)
                .font(.system(size: 20))
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
        }
    }
}
#endif

#if os(macOS)
private extension ContentView {
    var settingsButton: some View {
        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Adjust seeding and notification preferences")
        .controlCursor()
    }

    var seedingMenu: some View {
        Menu {
            Button("Add Torrent for Seeding…") { openWindow(id: "torrent-seeder") }
            Button("Edit Torrent…") { openWindow(id: "torrent-editor") }
            Divider()
            Button("Seed All Completed Torrents") {
                downloadsVM.setSeedingForAllCompleted(true)
            }
            .disabled(!downloadsVM.canStartSeedingAllCompleted)

            Button("Stop All Seeding") {
                downloadsVM.setSeedingForAllCompleted(false)
            }
            .disabled(!downloadsVM.canStopSeedingAll)
        } label: {
            Label("Seeding", systemImage: "arrow.up.circle")
        }
        .help("Seed a torrent or manage all seeding")
        .controlCursor()
    }
}
#endif

#if os(macOS)
/// macOS toolbar tabs ignore SwiftUI's badge modifier and custom label layouts.
/// A template image keeps the native tab control and its appearance/selection
/// tint while drawing the title and a count capsule together at Retina resolution.
private func transfersTabImage(count: Int) -> NSImage {
    let title = "Transfers" as NSString
    let number = String(count) as NSString
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.black
    ]
    let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.black
    ]
    let titleSize = title.size(withAttributes: titleAttributes)
    let numberSize = number.size(withAttributes: numberAttributes)
    let badgeWidth = max(18, ceil(numberSize.width) + 10)
    let badgeX = ceil(titleSize.width) + 6
    let height: CGFloat = 20
    let width = count > 0 ? badgeX + badgeWidth : ceil(titleSize.width)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        title.draw(at: NSPoint(x: 0, y: (height - titleSize.height) / 2), withAttributes: titleAttributes)
        guard count > 0 else { return true }
        NSColor.black.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: badgeX, y: 1, width: badgeWidth, height: 18),
                     xRadius: 9, yRadius: 9).fill()
        number.draw(at: NSPoint(x: badgeX + (badgeWidth - numberSize.width) / 2,
                               y: (height - numberSize.height) / 2), withAttributes: numberAttributes)
        return true
    }
    image.isTemplate = true
    return image
}
#endif

#Preview {
    ContentView()
        .environmentObject(SeedingPreferencesStore.shared)
        .environmentObject(SearchPreferencesStore.shared)
        .environmentObject(DownloadLocationStore.shared)
        .environmentObject(DownloadAutomationStore.shared)
        .environmentObject(DownloadsViewModel(preferences: SeedingPreferencesStore.shared,
                                              downloadLocation: DownloadLocationStore.shared))
}
