import AppKit
import Foundation

@MainActor
final class AppShell: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let recordingController: RecordingController
    private let windowCoordinator: WindowCoordinator
    private let calendarService: GoogleCalendarService
    private let recordingIndicatorManager: RecordingIndicatorManager

    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private let menu = NSMenu()
    private var primaryActionItem: NSMenuItem?
    private var statusLineItem: NSMenuItem?
    private var openLatestSummaryItem: NSMenuItem?
    private var openLatestSessionFolderItem: NSMenuItem?
    private var actionsSeparatorItem: NSMenuItem?
    private var calendarMenuItems: [NSMenuItem] = []

    init(
        settings: AppSettings,
        recordingController: RecordingController,
        windowCoordinator: WindowCoordinator,
        calendarService: GoogleCalendarService,
        recordingIndicatorManager: RecordingIndicatorManager
    ) {
        self.settings = settings
        self.recordingController = recordingController
        self.windowCoordinator = windowCoordinator
        self.calendarService = calendarService
        self.recordingIndicatorManager = recordingIndicatorManager
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
        updateCalendarMenuItems()
        updateStatusIcon()
        updateRecordingIndicator()
    }

    private func updateRecordingIndicator() {
        recordingIndicatorManager.update(for: recordingController.state)
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

        let actionsSeparatorItem = NSMenuItem.separator()
        self.actionsSeparatorItem = actionsSeparatorItem
        menu.addItem(actionsSeparatorItem)

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
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.items.forEach { item in
            guard item !== settingsItem else { return }
            item.target = self
        }
        updateMenuItems()
        updateCalendarMenuItems()
    }

    private func updateMenuItems() {
        primaryActionItem?.title = recordingController.primaryActionTitle

        if let statusLine = recordingController.statusLine, !statusLine.isEmpty {
            statusLineItem?.title = statusLine
            statusLineItem?.isHidden = false
        } else {
            statusLineItem?.isHidden = true
        }

        let hasLatestSummary = recordingController.latestCompletedSession != nil
        openLatestSummaryItem?.isHidden = !hasLatestSummary
        openLatestSummaryItem?.isEnabled = hasLatestSummary

        let hasSessionFolder = recordingController.currentSession != nil || recordingController.latestCompletedSession != nil
        openLatestSessionFolderItem?.isHidden = !hasSessionFolder
        openLatestSessionFolderItem?.isEnabled = hasSessionFolder
    }

    private func updateCalendarMenuItems() {
        calendarMenuItems.forEach { menu.removeItem($0) }
        calendarMenuItems.removeAll()

        guard let anchor = actionsSeparatorItem, let insertionIndex = menu.items.firstIndex(of: anchor) else { return }

        let items = makeCalendarMenuItems()
        guard !items.isEmpty else { return }

        for (offset, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: insertionIndex + offset)
        }
        calendarMenuItems = items
    }

    private func makeCalendarMenuItems() -> [NSMenuItem] {
        guard settings.calendarIntegrationEnabled else { return [] }

        var items: [NSMenuItem] = []
        let status = calendarService.integrationStatus

        switch status {
        case .disabled:
            return []
        case .clientConfigurationRequired:
            items.append(disabledItem(title: "Add Google OAuth Client ID"))
            items.append(actionItem(title: "Open Calendar Settings", action: #selector(openSettings)))
            items.append(.separator())
            return items
        case .authRequired:
            items.append(disabledItem(title: "Connect Google Calendar"))
            items.append(actionItem(title: "Open Calendar Settings", action: #selector(openSettings)))
            items.append(.separator())
            return items
        case .loading(let message):
            items.append(disabledItem(title: message))
            items.append(.separator())
            return items
        case .error(let message):
            items.append(disabledItem(title: message))
            items.append(actionItem(title: "Open Calendar Settings", action: #selector(openSettings)))
            items.append(.separator())
            return items
        case .ready:
            break
        }

        if let snapshot = calendarService.agendaSnapshot, !snapshot.buckets.isEmpty {
            for bucket in snapshot.buckets {
                items.append(disabledItem(title: bucket.title))
                for event in bucket.events {
                    let item = actionItem(title: Self.menuLabel(for: event), action: #selector(handleAgendaSelection(_:)))
                    item.attributedTitle = Self.attributedMenuLabel(for: event)
                    item.representedObject = event
                    item.toolTip = event.primaryURL?.absoluteString ?? event.eventURL?.absoluteString
                    item.isEnabled = recordingController.canStartNewRecording
                    items.append(item)
                }
                items.append(.separator())
            }
        } else {
            items.append(disabledItem(title: "No upcoming events"))
            items.append(.separator())
        }

        return items
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func menuLabel(for event: CalendarAgendaEvent) -> String {
        "\(event.title)\n\(menuDetail(for: event))"
    }

    private static func attributedMenuLabel(for event: CalendarAgendaEvent) -> NSAttributedString {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let string = NSMutableAttributedString(string: event.title, attributes: titleAttributes)
        string.append(NSAttributedString(string: "\n\(menuDetail(for: event))", attributes: detailAttributes))
        return string
    }

    private static func menuDetail(for event: CalendarAgendaEvent) -> String {
        let detail: String
        if event.isAllDay {
            detail = "All day"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            detail = "\(formatter.string(from: event.startAt)) - \(formatter.string(from: event.endAt))"
        }
        return detail
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
        Task { @MainActor in
            await calendarService.refreshStatus(force: false)
            refreshMenu()
        }
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
    private func handleAgendaSelection(_ sender: NSMenuItem) {
        guard let event = sender.representedObject as? CalendarAgendaEvent else {
            return
        }

        Task { @MainActor in
            let didStart = await recordingController.startRecording(for: event)
            guard didStart, let url = event.primaryURL else {
                refreshMenu()
                return
            }

            NSWorkspace.shared.open(url)
            refreshMenu()
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
