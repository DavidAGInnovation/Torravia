import AppKit
import SwiftUI

/// Intercepts the close button and Command-W without losing SwiftUI's window delegate.
struct TorrentCreatorWindowBridge: NSViewRepresentable {
    let shouldClose: () -> Bool
    let didClose: () -> Void
    let attachWindow: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.coordinator = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.didClose = didClose
        context.coordinator.attachWindow = attachWindow
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    static func dismantleNSView(_ view: MarkerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class MarkerView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // SwiftUI finishes assigning its own delegate during window setup.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.coordinator?.attach(to: window)
            }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool = { true }
        var didClose: () -> Void = {}
        var attachWindow: (NSWindow) -> Void = { _ in }
        private weak var window: NSWindow?
        private weak var originalDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard self.window !== window || window.delegate !== self else { return }
            detach()
            self.window = window
            originalDelegate = window.delegate
            window.delegate = self
            attachWindow(window)
        }

        func detach() {
            if window?.delegate === self { window?.delegate = originalDelegate }
            window = nil
            originalDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            originalDelegate?.windowWillClose?(notification)
            // Avoid changing SwiftUI state while AppKit is closing its hosting view.
            DispatchQueue.main.async { [didClose] in didClose() }
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
