#if os(macOS)
import AppKit

extension UnifiedSettingsDocumentView {
    private func target(_ action: @escaping () -> Void) -> ActionTarget {
        let value = ActionTarget(action)
        targets.append(value)
        return value
    }

    func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let value = PointingHandButton()
        value.title = title
        value.bezelStyle = .rounded
        value.controlSize = .regular
        let actionTarget = target(action)
        value.target = actionTarget
        value.action = #selector(ActionTarget.invoke(_:))
        return value
    }

    func symbolButton(_ symbolName: String, help: String, action: @escaping () -> Void) -> NSButton {
        let value = button("", action: action)
        value.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: help)
        value.imagePosition = .imageOnly
        value.toolTip = help
        value.setAccessibilityLabel(help)
        return value
    }

    func searchActionsMenu() -> NSPopUpButton {
        let value = PointingHandPopUpButton(frame: .zero, pullsDown: true)
        value.bezelStyle = .rounded
        value.controlSize = .regular
        value.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Provider actions")
        value.imagePosition = .imageOnly
        value.toolTip = "Provider actions"
        value.setAccessibilityLabel("Provider actions")

        let menu = NSMenu()
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.image = value.image
        menu.addItem(header)

        func addItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ActionTarget.invoke(_:)), keyEquivalent: "")
            let actionTarget = target(action)
            item.target = actionTarget
            item.isEnabled = enabled
            menu.addItem(item)
        }

        addItem("Select All", enabled: !searchPreferences.areAllSitesEnabled) { [weak self] in
            self?.searchPreferences.enableAllSites()
            self?.refreshAfterAction()
        }
        addItem("Keep One Enabled", enabled: searchPreferences.canReduceToSingleSite) { [weak self] in
            self?.searchPreferences.keepOnlyOneSiteEnabled()
            self?.refreshAfterAction()
        }
        menu.addItem(.separator())
        addItem("Restore Defaults", enabled: searchPreferences.enabledSites != TorrentSearchSite.defaultEnabled) { [weak self] in
            self?.searchPreferences.resetToDefaults()
            self?.refreshAfterAction()
        }
        value.menu = menu
        return value
    }

    func separator() -> NSBox {
        let value = NSBox()
        value.boxType = .separator
        return value
    }

    func switchControl(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> NSSwitch {
        let value = PointingHandSwitch()
        value.state = isOn ? .on : .off
        value.setAccessibilityLabel(title)
        let actionTarget = target { [weak value] in action(value?.state == .on) }
        value.target = actionTarget
        value.action = #selector(ActionTarget.invoke(_:))
        return value
    }

    func checkbox(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> NSButton {
        let value = PointingHandButton()
        value.setButtonType(.switch)
        value.title = ""
        value.state = isOn ? .on : .off
        value.setAccessibilityLabel(title)
        let actionTarget = target { [weak value] in action(value?.state == .on) }
        value.target = actionTarget
        value.action = #selector(ActionTarget.invoke(_:))
        return value
    }

    func popup(_ titles: [String], selected: String, action: @escaping (Int) -> Void) -> NSPopUpButton {
        let value = PointingHandPopUpButton()
        value.addItems(withTitles: titles)
        value.selectItem(withTitle: selected)
        let actionTarget = target { [weak value] in action(value?.indexOfSelectedItem ?? 0) }
        value.target = actionTarget
        value.action = #selector(ActionTarget.invoke(_:))
        return value
    }

    func textField(_ key: String, value: String = "", placeholder: String = "", secure: Bool = false) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField(string: value) : NSTextField(string: value)
        field.cell = secure ? SettingsSecureTextFieldCell(textCell: value) : SettingsTextFieldCell(textCell: value)
        field.placeholderString = placeholder
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.controlSize = .regular
        field.focusRingType = .exterior
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        if key == "rssFeed" { field.setAccessibilityLabel("RSS feed URL") }
        fields[key] = field
        return field
    }

    func editor(_ key: String, value: String) -> NSScrollView {
        let editor = SettingsEditorTextView()
        editor.string = value
        editor.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.identifier = NSUserInterfaceItemIdentifier(key)
        editor.setAccessibilityLabel(key == "additionalTrackers" ? "Additional trackers" : "Blocked IP ranges")
        editor.delegate = self
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 508, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        // Tracker URLs and IP ranges must retain exactly what was entered.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        let scroll = SettingsEditorScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = NSScroller.preferredScrollerStyle
        editors[key] = editor
        return scroll
    }

    func switchRow(_ title: String, isOn: Bool, to storage: NSMutableAttributedString, action: @escaping (Bool) -> Void) {
        let range = append(title, reserveControl: true, to: storage)
        place(switchControl(title, isOn: isOn, action: action), at: range, x: 488, width: 40, height: 22)
    }

    func pickerRow(_ title: String, titles: [String], selected: String, to storage: NSMutableAttributedString, action: @escaping (Int) -> Void) {
        let range = append(title, reserveControl: true, to: storage)
        let control = popup(titles, selected: selected, action: action)
        control.setAccessibilityLabel(title)
        control.toolTip = title
        place(control, at: range, x: 360, width: 168, height: 26)
    }

    func stepperRow(_ title: String, value: Int, range limits: ClosedRange<Int>, step: Int = 1, suffix: String = "", to storage: NSMutableAttributedString, action: @escaping (Int) -> Void) {
        let shown = value == 0 && suffix == " MB/s" ? "Unlimited" : "\(value)\(suffix)"
        let range = append("\(title): \(shown)", reserveControl: true, to: storage)
        let control = PointingHandStepper()
        control.minValue = Double(limits.lowerBound)
        control.maxValue = Double(limits.upperBound)
        control.increment = Double(step)
        control.integerValue = value
        control.setAccessibilityLabel(title)
        control.toolTip = title
        let actionTarget = target { [weak self, weak control] in
            action(control?.integerValue ?? value)
            self?.refreshAfterAction()
        }
        control.target = actionTarget
        control.action = #selector(ActionTarget.invoke(_:))
        place(control, at: range, x: 500, width: 28, height: 26)
    }
}

#endif
