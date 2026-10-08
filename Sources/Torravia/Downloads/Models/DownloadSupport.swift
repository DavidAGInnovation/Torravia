//
//  DownloadSupport.swift
//  Torravia
//
//  Shared storage and feed primitives used by the download model.
//

import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

struct RSSFeedItem {
    let title: String
    let link: String?
    let enclosure: String?
    let guid: String?
}

struct RSSFeedState {
    var etag: String?
    var lastModified: String?
    var lastPolledAt: Date?
    var lastError: String?
    var itemCount: Int = 0
    var importedCount: Int = 0
}

final class RSSFeedParser: NSObject, XMLParserDelegate {
    private var items: [RSSFeedItem] = []
    private var currentElement = ""
    private var currentText = ""
    private var title = ""
    private var link: String?
    private var enclosure: String?
    private var guid: String?
    private var insideItem = false

    static func parse(data: Data) -> [RSSFeedItem] {
        let parserDelegate = RSSFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else { return [] }
        return parserDelegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""
        if currentElement == "item" || currentElement == "entry" {
            insideItem = true
            title = ""
            link = nil
            enclosure = nil
            guid = nil
        } else if insideItem, currentElement == "enclosure" {
            enclosure = attributeDict["url"]
        } else if insideItem, currentElement == "link",
                  let href = attributeDict["href"], !href.isEmpty {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideItem {
            switch element {
            case "title": title = value
            case "link": if link == nil, !value.isEmpty { link = value }
            case "guid", "id": if guid == nil, !value.isEmpty { guid = value }
            default: break
            }
        }
        if element == "item" || element == "entry" {
            if !title.isEmpty {
                items.append(RSSFeedItem(title: title, link: link, enclosure: enclosure, guid: guid))
            }
            insideItem = false
        }
        currentElement = ""
        currentText = ""
    }
}

@MainActor
final class DownloadLocationStore: ObservableObject {
    static let shared = DownloadLocationStore()

    @Published private(set) var locationURL: URL?

    private let defaults: UserDefaults
    private static let bookmarkKey = "downloads.location.bookmark"
    private var scopedURL: URL?

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.locationURL = nil
        resolveStoredLocation()
    }

    var displayName: String {
        locationURL?.path ?? "~/Downloads"
    }

    static var systemDownloadsURL: URL {
        let homeDownloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        if FileManager.default.fileExists(atPath: homeDownloads.path) {
            return homeDownloads
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? homeDownloads
    }

    func chooseLocation() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Download Location"
        panel.message = "New downloads will be saved in this folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = locationURL ?? Self.systemDownloadsURL
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setLocation(url)
        }
#endif
    }

    func resetToSystemDownloads() {
        stopScopedAccess()
        defaults.removeObject(forKey: Self.bookmarkKey)
        locationURL = nil
    }

    @discardableResult
    func setLocation(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let accessed = standardized.startAccessingSecurityScopedResource()
        defer {
            if !accessed { stopScopedAccess() }
        }

        do {
            let bookmark = try standardized.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil)
            stopScopedAccess()
            if accessed { scopedURL = standardized }
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            locationURL = standardized
            return true
        } catch {
            print("[DownloadLocationStore] Failed to persist download location: \(error)")
            return false
        }
    }

    private func resolveStoredLocation() {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            guard url.isFileURL else { return }
            let standardized = url.standardizedFileURL
            if standardized.startAccessingSecurityScopedResource() {
                scopedURL = standardized
                locationURL = standardized
                if isStale { _ = setLocation(standardized) }
            }
        } catch {
            print("[DownloadLocationStore] Failed to resolve stored location: \(error)")
            defaults.removeObject(forKey: Self.bookmarkKey)
        }
    }

    private func stopScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
