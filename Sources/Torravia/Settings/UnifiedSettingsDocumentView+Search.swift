#if os(macOS)
import AppKit

extension UnifiedSettingsDocumentView {
    func buildSearch(_ storage: NSMutableAttributedString) {
        let states = TorrentSearchSite.defaultOrder.map { providerHealth.status(for: $0) }
        let online = states.filter(\.isOnline).count
        let offline = states.filter { $0.detail != nil }.count

        let summary: String
        if providerHealth.isChecking {
            summary = "Checking provider links…"
        } else {
            summary = "\(online) online · \(offline) unavailable"
        }
        let summaryColor: NSColor = offline == 0 ? .systemGreen : .systemOrange
        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.firstLineHeadIndent = 20
        summaryStyle.headIndent = 20
        summaryStyle.tailIndent = -160
        summaryStyle.minimumLineHeight = 22
        summaryStyle.paragraphSpacingBefore = 16
        let summaryStart = storage.length
        storage.append(NSAttributedString(string: "●  ", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: summaryColor, .paragraphStyle: summaryStyle
        ]))
        storage.append(NSAttributedString(string: summary + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: summaryStyle
        ]))
        let summaryRange = NSRange(location: summaryStart, length: storage.length - summaryStart)
        let refresh = button("Refresh") { [weak providerHealth] in
            providerHealth?.checkAll()
        }
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.imagePosition = .imageLeading
        refresh.toolTip = "Check provider links now"
        refresh.setAccessibilityLabel("Check provider links now")
        refresh.isEnabled = !providerHealth.isChecking
        place(refresh, at: summaryRange, x: 392, width: 96, height: 26, yOffset: 12)
        place(searchActionsMenu(), at: summaryRange, x: 496, width: 32, height: 26, yOffset: 12)

        let checkedStyle = NSMutableParagraphStyle()
        checkedStyle.firstLineHeadIndent = 34
        checkedStyle.headIndent = 34
        checkedStyle.minimumLineHeight = 18
        checkedStyle.paragraphSpacing = 26
        let checkedText = providerHealth.lastCheckedAt.map {
            "Last checked at \($0.formatted(date: .omitted, time: .shortened))"
        } ?? "Availability is checked automatically."
        let checkedRange = NSRange(location: storage.length, length: (checkedText as NSString).length + 1)
        storage.append(NSAttributedString(string: checkedText + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: checkedStyle
        ]))
        place(separator(), at: checkedRange, x: 20, width: 508, height: 1, yOffset: 28)

        let columnsStyle = NSMutableParagraphStyle()
        columnsStyle.firstLineHeadIndent = 20
        columnsStyle.headIndent = 20
        columnsStyle.tailIndent = -10
        columnsStyle.tabStops = [NSTextTab(type: .leftTabStopType, location: 388), NSTextTab(type: .leftTabStopType, location: 480)]
        columnsStyle.minimumLineHeight = 18
        columnsStyle.paragraphSpacingBefore = 8
        columnsStyle.paragraphSpacing = 14
        storage.append(NSAttributedString(string: "Provider\tStatus\tEnabled\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: columnsStyle
        ]))

        append("GENERAL", style: .caption, to: storage)
        for site in orderedSites(spanish: false) {
            providerRow(site, storage: storage)
        }
        let spanishSites = orderedSites(spanish: true)
        if !spanishSites.isEmpty {
            append("SPANISH", style: .caption, to: storage)
            for site in spanishSites { providerRow(site, storage: storage) }
        }
    }

    private func providerRow(_ site: TorrentSearchSite, storage: NSMutableAttributedString) {
        let health = providerHealth.status(for: site)
        let providerURL = providerHealth.providerLink(for: site)
        let sourceURL = providerHealth.sourceLink(for: site)
        let links: [ProviderLink]
        if let directoryURL = providerHealth.proxyDirectoryLink(for: site),
           let sourceURL, sourceURL != directoryURL {
            links = [
                ProviderLink(label: "Provider URL", url: directoryURL),
                ProviderLink(label: "Source URL", url: sourceURL)
            ]
        } else if let singleURL = sourceURL ?? providerURL {
            links = [ProviderLink(label: nil, url: singleURL)]
        } else {
            links = []
        }
        let layout = appendProviderText(site, links: links, health: health, to: storage)
        if let id = providerSelectionIDs[site] { selectionSections[id] = layout.range }

        let onlyEnabled = searchPreferences.enabledSites.count == 1 && searchPreferences.isEnabled(site)
        let control = switchControl(site.displayName, isOn: searchPreferences.isEnabled(site)) { [weak self] value in
            self?.searchPreferences.set(site, enabled: value)
            self?.refreshAfterAction()
        }
        control.controlSize = .mini
        control.isEnabled = !onlyEnabled
        place(control, at: layout.range, x: 488, width: 40, height: 18, yOffset: 0)
        // Anchor the divider to the last visible line, rather than the whole
        // row, so it stays centered in the gap before the next provider.
        place(separator(), at: NSRange(location: NSMaxRange(layout.dividerRange) - 2, length: 1), x: 20, width: 508, height: 1, yOffset: 31)
    }

    private func appendProviderText(
        _ site: TorrentSearchSite,
        links: [ProviderLink],
        health: ProviderHealthState,
        to storage: NSMutableAttributedString
    ) -> ProviderTextLayout {
        let start = storage.length
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 20
        paragraph.headIndent = 20
        paragraph.tailIndent = -184
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = 17

        let titleParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
        titleParagraph.tailIndent = -76
        titleParagraph.tabStops = [NSTextTab(type: .leftTabStopType, location: 388)]
        storage.append(NSAttributedString(string: site.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titleParagraph
        ]))
        let healthColor: NSColor
        switch health {
        case .online: healthColor = .systemGreen
        case .offline, .rateLimited: healthColor = .systemRed
        case .checking, .unknown: healthColor = .secondaryLabelColor
        }
        storage.append(NSAttributedString(string: "\t" + health.label + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: healthColor,
            .paragraphStyle: titleParagraph,
            .toolTip: health.detail ?? health.label
        ]))
        let descriptionStart = storage.length
        storage.append(NSAttributedString(
            string: site.description + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
        let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        var dividerRange = NSRange(location: descriptionStart, length: storage.length - descriptionStart)
        for index in 0..<2 {
            guard index < links.count else {
                storage.append(NSAttributedString(string: " \n", attributes: placeholderAttributes))
                continue
            }

            let link = links[index]
            let linkStart = storage.length
            storage.append(NSAttributedString(
                string: link.text + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5),
                    .foregroundColor: NSColor.linkColor,
                    .link: link.url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .paragraphStyle: paragraph
                ]
            ))
            dividerRange = NSRange(location: linkStart, length: storage.length - linkStart)
        }
        if links.count == 2 {
            storage.append(NSAttributedString(string: " \n", attributes: placeholderAttributes))
        }
        return ProviderTextLayout(
            range: NSRange(location: start, length: storage.length - start),
            dividerRange: dividerRange
        )
    }

    private func orderedSites(spanish: Bool) -> [TorrentSearchSite] {
        let spanishSites = Set(TorrentSearchSite.spanishSites)
        return TorrentSearchSite.defaultOrder.filter { spanish ? spanishSites.contains($0) : !spanishSites.contains($0) }
    }
}

#endif
