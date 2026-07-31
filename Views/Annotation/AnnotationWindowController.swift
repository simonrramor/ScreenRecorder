import AppKit
import SwiftUI

@MainActor
class AnnotationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var appState: AppState?
    private var escapeMonitor: Any?

    func openAnnotationWindow(image: NSImage, appState: AppState) {
        if window != nil {
            closeWindow()
        }

        self.appState = appState

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let maxWidth = screenFrame.width * 0.85
        let maxHeight = screenFrame.height * 0.85
        let toolbarHeight: CGFloat = 52

        let imageSize = image.size
        let availableHeight = maxHeight - toolbarHeight
        let widthRatio = maxWidth / imageSize.width
        let heightRatio = availableHeight / imageSize.height
        let scale = min(widthRatio, heightRatio, 1.0)

        let windowWidth = max(imageSize.width * scale, 600)
        let windowHeight = imageSize.height * scale + toolbarHeight

        let origin = CGPoint(
            x: screenFrame.midX - windowWidth / 2,
            y: screenFrame.midY - windowHeight / 2
        )

        let contentRect = NSRect(origin: origin, size: CGSize(width: windowWidth, height: windowHeight))

        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Annotate Screenshot"
        win.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        win.minSize = NSSize(width: 400, height: 300)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = .floating

        let editorView = AnnotationEditorView(
            image: image,
            annotationState: Binding(
                get: { [weak appState] in appState?.annotationState ?? AnnotationState() },
                set: { [weak appState] in appState?.annotationState = $0 }
            ),
            onSave: { [weak appState] annotatedImage in
                guard let appState = appState else { return }
                Task { await appState.saveAnnotatedScreenshot(annotatedImage) }
            },
            onSaveOriginal: { [weak appState] in
                guard let appState = appState else { return }
                Task { await appState.saveScreenshotWithoutAnnotation() }
            },
            onCancel: { [weak self, weak appState] in
                self?.closeWindow()
                appState?.showAnnotationEditor = false
                appState?.annotationImage = nil
            }
        )
        .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: editorView)
        hosting.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        hosting.autoresizingMask = [.width, .height]

        win.contentView = hosting
        window = win

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closeWindow()
                return nil
            }
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()

        DispatchQueue.main.async {
            win.level = .normal
        }
    }

    func closeWindow() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let win = window {
            win.close()
            window = nil
        }
        appState?.showAnnotationEditor = false
        appState?.annotationImage = nil
    }

    var isOpen: Bool {
        window?.isVisible == true
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.window = nil
            self?.appState?.showAnnotationEditor = false
            self?.appState?.annotationImage = nil
        }
    }
}
