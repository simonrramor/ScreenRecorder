import AppKit
import SwiftUI

/// NSPanel that displays a composited screenshot at the exact screen
/// coordinates the user dragged over. The panel becomes key so it can catch
/// the ESC key for dismissal; `.nonactivatingPanel` keeps the underlying app
/// focused so the user never loses context.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TranslationOverlayController {
    private var panel: OverlayPanel?
    private var state: TranslationOverlayState?
    private var hostingView: NSHostingView<TranslationOverlayView>?
    private var localMonitor: Any?

    private var onRetryAction: (() -> Void)?
    private var onSaveAction: (() -> Void)?
    private var onCopyAction: (() -> Void)?

    /// Opens the overlay in the loading state at the given screen area.
    /// `area` uses CG global coordinates (top-left origin, main-screen basis),
    /// matching what `AreaSelectionWindowController` emits.
    func showLoading(area: CGRect, initialImage: NSImage, engineName: String?) {
        close()

        let s = TranslationOverlayState(image: initialImage)
        s.engineName = engineName
        self.state = s

        let view = TranslationOverlayView(
            state: s,
            onRetry: { [weak self] in self?.onRetryAction?() },
            onSave: { [weak self] in self?.onSaveAction?() },
            onCopy: { [weak self] in self?.onCopyAction?() },
            onClose: { [weak self] in self?.close() }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: area.size)

        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: area.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        // Let the user drag the overlay anywhere on screen — clicks on the
        // SwiftUI toolbar buttons are consumed by those buttons first, so
        // dragging only kicks in on empty image area.
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.panel = panel
        self.hostingView = hosting

        position(panel: panel, at: area)
        panel.makeKeyAndOrderFront(nil)

        installLocalEventMonitor()
    }

    /// Swaps the displayed image (typically the composited translation) and
    /// moves the overlay into the loaded state.
    func showLoaded(composited: NSImage) {
        state?.image = composited
        state?.phase = .loaded
    }

    /// Marks the overlay as failed and exposes a retry button.
    func showFailed(message: String, onRetry: @escaping () -> Void) {
        onRetryAction = onRetry
        state?.phase = .failed(message)
    }

    /// Sets the action that runs on the Save toolbar button and on Cmd+S.
    func setSaveAction(_ action: @escaping () -> Void) {
        onSaveAction = action
    }

    /// Sets the action that runs on the Copy toolbar button and on Cmd+C.
    func setCopyAction(_ action: @escaping () -> Void) {
        onCopyAction = action
    }

    func close() {
        removeLocalEventMonitor()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        state = nil
        hostingView = nil
        onRetryAction = nil
        onSaveAction = nil
        onCopyAction = nil
    }

    private func position(panel: NSPanel, at area: CGRect) {
        let cocoaRect = ScreenGeometry.cocoaRect(fromCGRect: area)
        panel.setFrame(NSRect(origin: cocoaRect.origin, size: area.size), display: true)
    }

    private func installLocalEventMonitor() {
        removeLocalEventMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            // ESC — dismiss
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            let cmd = event.modifierFlags.contains(.command)
            switch event.charactersIgnoringModifiers {
            case "c" where cmd:
                self.onCopyAction?()
                return nil
            case "s" where cmd:
                self.onSaveAction?()
                return nil
            default:
                return event
            }
        }
    }

    private func removeLocalEventMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
