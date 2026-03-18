import Foundation

@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let recordingController: RecordingController
    let windowCoordinator: WindowCoordinator
    let appShell: AppShell

    private init() {
        let settings = AppSettings()
        let recordingController = RecordingController(settings: settings)
        let windowCoordinator = WindowCoordinator(settings: settings, recordingController: recordingController)
        let appShell = AppShell(settings: settings, recordingController: recordingController, windowCoordinator: windowCoordinator)

        recordingController.onSetupRequired = { [weak windowCoordinator] in
            windowCoordinator?.showSettings()
        }

        self.settings = settings
        self.recordingController = recordingController
        self.windowCoordinator = windowCoordinator
        self.appShell = appShell
    }
}
