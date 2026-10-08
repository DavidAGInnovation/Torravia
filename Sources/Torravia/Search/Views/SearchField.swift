//
//  SearchField.swift
//  Torravia
//
//  Native search field bridge used by the search screen.
//

import SwiftUI
import Foundation
#if os(macOS)
import AppKit

struct MacSearchField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onPaste: (String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.placeholderString = ""
        field.stringValue = text
        field.textColor = .labelColor
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = true

        if let cell = field.cell as? NSSearchFieldCell {
            cell.backgroundColor = .clear
            cell.textColor = .labelColor
            cell.placeholderAttributedString = nil
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }

        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self

        if field.stringValue != text {
            field.stringValue = text
        }

        if let cell = field.cell as? NSSearchFieldCell {
            cell.textColor = .labelColor
        }
        field.textColor = .labelColor

        let shouldFocus = isFocused.wrappedValue
        guard shouldFocus else { return }
        DispatchQueue.main.async {
            guard field.window?.firstResponder != field.currentEditor() else { return }
            field.window?.makeFirstResponder(field)
            context.coordinator.moveCaretToEnd(of: field)
        }
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacSearchField

        init(parent: MacSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                moveCaretToEnd(of: control)
                return true
            }
            if commandSelector == #selector(NSTextView.paste(_:)) {
                if let clip = NSPasteboard.general.string(forType: .string), parent.onPaste(clip) {
                    return true
                }
            }
            return false
        }

        func moveCaretToEnd(of control: NSControl) {
            DispatchQueue.main.async {
                guard
                    let window = control.window,
                    let editor = window.fieldEditor(false, for: control)
                else { return }
                let length = editor.string.count
                editor.selectedRange = NSRange(location: length, length: 0)
                DispatchQueue.main.async {
                    let length = editor.string.count
                    editor.selectedRange = NSRange(location: length, length: 0)
                }
            }
        }
    }
}
#endif
