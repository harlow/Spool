import AppKit
import Foundation

@MainActor
final class AppShell: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let recordingController: RecordingController
    private let windowCoordinator: WindowCoordinator

    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private let menu = NSMenu()
    private var primaryActionItem: NSMenuItem?
    private var statusLineItem: NSMenuItem?
    private var sessionLineItem: NSMenuItem?
    private var openLatestSummaryItem: NSMenuItem?
    private var openLatestSessionFolderItem: NSMenuItem?

    init(settings: AppSettings, recordingController: RecordingController, windowCoordinator: WindowCoordinator) {
        self.settings = settings
        self.recordingController = recordingController
        self.windowCoordinator = windowCoordinator
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "recordingtape", accessibilityDescription: "Spool")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Spool"
        buildMenu()
        item.menu = menu
        statusItem = item

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenu()
            }
        }
    }

    private func refreshMenu() {
        updateMenuItems()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch recordingController.state {
        case .idle, .ready, .completed:
            symbolName = "recordingtape"
        case .recording:
            symbolName = "recordingtape.circle.fill"
        case .stopping, .finalizingTranscript, .summarizing:
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
        case .failed:
            symbolName = "exclamationmark.triangle.fill"
        case .checkingPermissions:
            symbolName = "hand.raised.circle.fill"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Spool")
            ?? NSImage(systemSymbolName: "recordingtape", accessibilityDescription: "Spool")
        image?.isTemplate = true
        button.image = image
    }

    private func buildMenu() {
        menu.delegate = self

        let primaryActionItem = NSMenuItem(title: "", action: #selector(handlePrimaryAction), keyEquivalent: "")
        primaryActionItem.target = self
        self.primaryActionItem = primaryActionItem
        menu.addItem(primaryActionItem)

        let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        self.statusLineItem = statusLineItem
        menu.addItem(statusLineItem)

        let sessionLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sessionLineItem.isEnabled = false
        self.sessionLineItem = sessionLineItem
        menu.addItem(sessionLineItem)

        menu.addItem(.separator())
        let openLatestSummaryItem = NSMenuItem(title: "Open Latest Summary", action: #selector(openLatestSummary), keyEquivalent: "")
        openLatestSummaryItem.target = self
        self.openLatestSummaryItem = openLatestSummaryItem
        menu.addItem(openLatestSummaryItem)

        let openLatestSessionFolderItem = NSMenuItem(title: "Open Latest Session Folder", action: #selector(openLatestSessionFolder), keyEquivalent: "")
        openLatestSessionFolderItem.target = self
        self.openLatestSessionFolderItem = openLatestSessionFolderItem
        menu.addItem(openLatestSessionFolderItem)

        menu.addItem(withTitle: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        updateMenuItems()
    }

    private func updateMenuItems() {
        primaryActionItem?.title = recordingController.primaryActionTitle

        if let statusLine = recordingController.statusLine, !statusLine.isEmpty {
            statusLineItem?.title = statusLine
            statusLineItem?.isHidden = false
        } else {
            statusLineItem?.isHidden = true
        }

        if let sessionLine = recordingController.currentSessionPathLine, !sessionLine.isEmpty {
            sessionLineItem?.title = sessionLine
            sessionLineItem?.isHidden = false
        } else {
            sessionLineItem?.isHidden = true
        }

        openLatestSummaryItem?.isEnabled = recordingController.latestCompletedSession != nil
        openLatestSessionFolderItem?.isEnabled = recordingController.currentSession != nil || recordingController.latestCompletedSession != nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    @objc
    private func handlePrimaryAction() {
        Task { @MainActor in
            await recordingController.performPrimaryAction()
            refreshMenu()
        }
    }

    @objc
    private func openLatestSummary() {
        recordingController.openLatestSummary()
    }

    @objc
    private func openLatestSessionFolder() {
        recordingController.openLatestSessionFolder()
    }

    @objc
    private func openOutputFolder() {
        guard let root = settings.outputRootURL else {
            windowCoordinator.showSettings()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    @objc
    private func openSettings() {
        windowCoordinator.showSettings()
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
