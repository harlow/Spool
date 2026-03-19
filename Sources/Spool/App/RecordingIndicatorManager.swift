import AppKit
import SwiftUI

final class RecordingIndicatorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .utilityWindow
    }
}

@MainActor
final class RecordingIndicatorManager {
    private let isEnabled = false
    private var panel: RecordingIndicatorPanel?
    private let panelSize = NSSize(width: 54, height: 128)
    private let screenInset: CGFloat = 24

    func update(for state: RecordingState) {
        guard isEnabled else {
            hide()
            return
        }

        guard shouldShow(for: state) else {
            hide()
            return
        }

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: RecordingIndicatorView(state: state))
        reposition(panel)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }

        self.panel = panel
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }

    private func shouldShow(for state: RecordingState) -> Bool {
        state == .recording
    }

    private func makePanel() -> RecordingIndicatorPanel {
        let panel = RecordingIndicatorPanel(contentRect: defaultFrame())
        panel.contentView = NSHostingView(rootView: RecordingIndicatorView(state: .idle))
        return panel
    }

    private func reposition(_ panel: RecordingIndicatorPanel) {
        panel.setFrame(defaultFrame(), display: true)
    }

    private func defaultFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: visibleFrame.maxX - panelSize.width - screenInset,
            y: visibleFrame.midY - (panelSize.height / 2)
        )
        return NSRect(origin: origin, size: panelSize)
    }
}
