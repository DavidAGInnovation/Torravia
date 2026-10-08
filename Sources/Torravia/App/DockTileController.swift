#if os(macOS)
import AppKit

@MainActor
final class DockTileController {
    struct Stats: Equatable {
        let downloadingCount: Int
        let downloadSpeed: Int64
        let uploadSpeed: Int64
    }

    static let shared = DockTileController()

    private var tileView: DockTileView?
    private var isInstalled = false
    private var baseIcon: NSImage? = NSApplication.shared.applicationIconImage

    private init() { }

    func update(with stats: Stats?) {
        installIfNeeded()
        guard let tileView else { return }

        let currentIcon = NSApplication.shared.applicationIconImage
        if baseIcon !== currentIcon {
            baseIcon = currentIcon
        }
        if tileView.iconImage !== baseIcon {
            tileView.iconImage = baseIcon
        }
        tileView.stats = stats
        let tile = NSApplication.shared.dockTile
        let size = tile.size
        if tileView.frame.size != size {
            tileView.frame = NSRect(origin: .zero, size: size)
        }
        tileView.needsDisplay = true
        tile.display()
    }

    private func installIfNeeded() {
        guard !isInstalled else { return }
        let tile = NSApplication.shared.dockTile
        let size = tile.size
        let view = DockTileView(frame: NSRect(origin: .zero, size: size))
        view.iconImage = baseIcon
        tile.contentView = view
        tile.display()
        tileView = view
        isInstalled = true
    }
}

private extension DockTileController {
    static func formattedSpeed(_ value: Int64) -> String {
        guard value > 0 else { return "0 B" }
        // Keep the Dock label compact so both rates remain readable at the
        // fixed Dock tile size. The arrows identify download versus upload.
        let units: [String] = ["B", "K", "M", "G", "T"]
        var speed = Double(value)
        var unitIndex = 0
        while speed >= 1000, unitIndex < units.count - 1 {
            speed /= 1000
            unitIndex += 1
        }
        let format: String
        if speed >= 100 || unitIndex == 0 {
            format = "%.0f"
        } else if speed >= 10 {
            format = "%.1f"
        } else {
            format = "%.2f"
        }
        return String(format: format, speed) + " " + units[unitIndex]
    }
}

private final class DockTileView: NSView {
    var iconImage: NSImage? {
        didSet { needsDisplay = true }
    }
    var stats: DockTileController.Stats? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        if let image = iconImage {
            // Application icons often include transparent canvas padding. A
            // small scale-up makes the Dock tile occupy the same visual area
            // as neighboring torrent clients without changing the source art.
            let iconScale: CGFloat = 1.10
            let iconSize = CGSize(width: bounds.width * iconScale, height: bounds.height * iconScale)
            let iconRect = NSRect(x: bounds.midX - iconSize.width / 2,
                                  y: bounds.midY - iconSize.height / 2,
                                  width: iconSize.width,
                                  height: iconSize.height)
            image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }

        guard let stats else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }

        if stats.downloadSpeed > 0 || stats.uploadSpeed > 0 {
            drawBottomOverlay(downloadSpeed: stats.downloadSpeed, uploadSpeed: stats.uploadSpeed)
        }
        drawDownloadingBadge(count: stats.downloadingCount)
    }

    private func drawBottomOverlay(downloadSpeed: Int64, uploadSpeed: Int64) {
        let inset = bounds.width * 0.04
        // Give each rate its own row so the values stay readable at Dock size.
        // Make the panel tall enough for the larger two-line typography at
        // Retina Dock sizes without clipping either rate.
        let height = max(50, bounds.height * 0.50)
        let rect = NSRect(x: bounds.minX + inset,
                          y: bounds.minY + inset,
                          width: bounds.width - (inset * 2),
                          height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        NSColor(calibratedWhite: 0.0, alpha: 0.72).setFill()
        path.fill()

        let availableWidth = max(rect.width - 8, 1)
        // The Dock tile is small, so the rates need strong visual weight to
        // remain readable beside the application icon.
        var fontSize = max(15, bounds.width * 0.20)
        let makeDisplayStrings: (CGFloat) -> (NSAttributedString, NSAttributedString) = { size in
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            let download = NSAttributedString(
                string: "↓ " + DockTileController.formattedSpeed(downloadSpeed),
                attributes: [.font: font, .foregroundColor: NSColor.systemGreen]
            )
            let upload = NSAttributedString(
                string: "↑ " + DockTileController.formattedSpeed(uploadSpeed),
                attributes: [.font: font, .foregroundColor: NSColor.systemOrange]
            )
            return (download, upload)
        }
        var displayStrings = makeDisplayStrings(fontSize)
        while max(displayStrings.0.size().width, displayStrings.1.size().width) > availableWidth && fontSize > 9 {
            fontSize -= 0.5
            displayStrings = makeDisplayStrings(fontSize)
        }

        let lineHeight = max(displayStrings.0.size().height, displayStrings.1.size().height)
        let lineSpacing = max(1, rect.height * 0.02)
        let totalTextHeight = (lineHeight * 2) + lineSpacing
        let firstLineY = rect.minY + (rect.height - totalTextHeight) / 2 + lineHeight + lineSpacing
        let secondLineY = firstLineY - lineHeight - lineSpacing

        func drawCentered(_ string: NSAttributedString, atY y: CGFloat) {
            let size = string.size()
            string.draw(in: NSRect(x: rect.midX - size.width / 2,
                                   y: y,
                                   width: size.width,
                                   height: lineHeight))
        }
        drawCentered(displayStrings.0, atY: firstLineY)
        drawCentered(displayStrings.1, atY: secondLineY)
    }

    private func drawDownloadingBadge(count: Int) {
        guard count > 0 else { return }
        let label = count > 99 ? "99+" : "\(count)"
        let fontSize = max(17, bounds.width * 0.28)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = .zero
                return shadow
            }()
        ]

        let textSize = (label as NSString).size(withAttributes: attributes)
        let horizontalPadding = max(12, bounds.width * 0.16)
        let verticalPadding = max(6, bounds.height * 0.08)
        let topInset = max(3, bounds.height * 0.03)
        let rightInset = max(3, bounds.width * 0.03)

        let badgeRect = NSRect(
            x: bounds.maxX - (textSize.width + horizontalPadding) - rightInset,
            y: bounds.maxY - (textSize.height + verticalPadding) - topInset,
            width: textSize.width + horizontalPadding,
            height: textSize.height + verticalPadding
        )

        let path = NSBezierPath(roundedRect: badgeRect, xRadius: badgeRect.height / 2, yRadius: badgeRect.height / 2)
        NSColor.systemBlue.withAlphaComponent(0.95).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = NSRect(
            x: badgeRect.minX,
            y: badgeRect.minY + (badgeRect.height - textSize.height) / 2,
            width: badgeRect.width,
            height: textSize.height
        )
        (label as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
#endif
