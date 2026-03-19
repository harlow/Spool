import AppKit
import Foundation
import LocalAuthentication
import Observation
import Security

enum SummaryProvider: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .ollama:
            "Ollama"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            "gpt-5-nano"
        case .anthropic:
            "claude-3-7-sonnet-latest"
        case .ollama:
            "qwen3:8b"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openAI:
            "https://api.openai.com/v1"
        case .anthropic:
            "https://api.anthropic.com"
        case .ollama:
            "http://localhost:11434"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic:
            true
        case .ollama:
            false
        }
    }

    var endpointLabel: String {
        switch self {
        case .openAI:
            "Base URL"
        case .anthropic:
            "Base URL"
        case .ollama:
            "Ollama URL"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .openAI:
            "OpenAI API Key"
        case .anthropic:
            "Anthropic API Key"
        case .ollama:
            "API Key"
        }
    }
}

enum ShortcutBinding: String, CaseIterable, Identifiable {
    case commandShiftR
    case optionShiftR
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commandShiftR:
            "Command-Shift-R"
        case .optionShiftR:
            "Option-Shift-R"
        case .none:
            "Not Set"
        }
    }

    var menuLabel: String? {
        switch self {
        case .commandShiftR:
            "Cmd-Shift-R"
        case .optionShiftR:
            "Option-Shift-R"
        case .none:
            nil
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    private let googleOAuthConfiguration = GoogleOAuthConfiguration.load()

    var outputRootPath: String {
        didSet { defaults.set(outputRootPath, forKey: Keys.outputRootPath) }
    }

    var transcriptionLocale: String {
        didSet { defaults.set(transcriptionLocale, forKey: Keys.transcriptionLocale) }
    }

    var summaryProvider: SummaryProvider {
        didSet {
            defaults.set(summaryProvider.rawValue, forKey: Keys.summaryProvider)
            applySummaryProviderDefaultsIfNeeded(oldValue: oldValue)
        }
    }

    var summaryModel: String {
        didSet { defaults.set(summaryModel, forKey: Keys.summaryModel) }
    }

    var summaryEndpoint: String {
        didSet { defaults.set(summaryEndpoint, forKey: Keys.summaryEndpoint) }
    }

    var openSummaryOnCompletion: Bool {
        didSet { defaults.set(openSummaryOnCompletion, forKey: Keys.openSummaryOnCompletion) }
    }

    var openSessionFolderOnCompletion: Bool {
        didSet { defaults.set(openSessionFolderOnCompletion, forKey: Keys.openSessionFolderOnCompletion) }
    }

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    var preferredHotkey: ShortcutBinding {
        didSet { defaults.set(preferredHotkey.rawValue, forKey: Keys.preferredHotkey) }
    }

    var calendarIntegrationEnabled: Bool {
        didSet { defaults.set(calendarIntegrationEnabled, forKey: Keys.calendarIntegrationEnabled) }
    }

    var selectedGoogleCalendarID: String {
        didSet { defaults.set(selectedGoogleCalendarID, forKey: Keys.selectedGoogleCalendarID) }
    }

    var selectedGoogleCalendarName: String {
        didSet { defaults.set(selectedGoogleCalendarName, forKey: Keys.selectedGoogleCalendarName) }
    }

    var googleCalendarTokenExpiry: Int {
        didSet { defaults.set(googleCalendarTokenExpiry, forKey: Keys.googleCalendarTokenExpiry) }
    }

    var googleCalendarAccountEmail: String {
        didSet { defaults.set(googleCalendarAccountEmail, forKey: Keys.googleCalendarAccountEmail) }
    }

    var googleCalendarAccountName: String {
        didSet { defaults.set(googleCalendarAccountName, forKey: Keys.googleCalendarAccountName) }
    }

    var summaryApiKey: String {
        didSet { KeychainHelper.save(key: Keys.summaryApiKey, value: summaryApiKey) }
    }

    private let defaults = UserDefaults.standard

    init() {
        let storedProvider = SummaryProvider(rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "") ?? .openAI
        let storedModel = defaults.string(forKey: Keys.summaryModel)
        let storedEndpoint = defaults.string(forKey: Keys.summaryEndpoint)
        outputRootPath = defaults.string(forKey: Keys.outputRootPath) ?? ""
        transcriptionLocale = defaults.string(forKey: Keys.transcriptionLocale) ?? "en-US"
        summaryProvider = storedProvider
        summaryModel = AppSettings.migratedSummaryModel(storedModel, for: storedProvider)
        summaryEndpoint = AppSettings.migratedSummaryEndpoint(storedEndpoint, for: storedProvider)
        openSummaryOnCompletion = defaults.object(forKey: Keys.openSummaryOnCompletion) as? Bool ?? true
        openSessionFolderOnCompletion = defaults.bool(forKey: Keys.openSessionFolderOnCompletion)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        preferredHotkey = ShortcutBinding(rawValue: defaults.string(forKey: Keys.preferredHotkey) ?? "") ?? .none
        calendarIntegrationEnabled = defaults.bool(forKey: Keys.calendarIntegrationEnabled)
        selectedGoogleCalendarID = defaults.string(forKey: Keys.selectedGoogleCalendarID) ?? ""
        selectedGoogleCalendarName = defaults.string(forKey: Keys.selectedGoogleCalendarName) ?? ""
        googleCalendarTokenExpiry = defaults.integer(forKey: Keys.googleCalendarTokenExpiry)
        googleCalendarAccountEmail = defaults.string(forKey: Keys.googleCalendarAccountEmail) ?? ""
        googleCalendarAccountName = defaults.string(forKey: Keys.googleCalendarAccountName) ?? ""
        summaryApiKey = ""
    }

    var googleCalendarClientID: String {
        googleOAuthConfiguration.clientID
    }

    var googleCalendarClientSecret: String {
        googleOAuthConfiguration.clientSecret
    }

    var outputRootURL: URL? {
        guard !outputRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: outputRootPath, isDirectory: true)
    }

    var needsOnboarding: Bool {
        outputRootPath.isEmpty
    }

    var isSummaryAPIKeyMissing: Bool {
        summaryProvider.requiresAPIKey && summaryApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summaryConfigurationSummary: String {
        switch summaryProvider {
        case .ollama:
            return "\(summaryProvider.displayName) at \(summaryEndpoint)"
        case .openAI, .anthropic:
            let keyState = summaryApiKey.isEmpty ? "API key missing" : "API key saved"
            return "\(summaryProvider.displayName), \(summaryModel), \(keyState), \(summaryEndpoint)"
        }
    }

    func chooseOutputRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Output Folder"

        if panel.runModal() == .OK, let url = panel.url {
            outputRootPath = url.path
        }
    }

    func loadSummaryAPIKeyIfNeeded() {
        guard summaryApiKey.isEmpty else { return }
        summaryApiKey = KeychainHelper.load(key: Keys.summaryApiKey) ?? ""
    }

    func preloadSecretsForLaunch() {
        _ = KeychainHelper.load(key: Keys.summaryApiKey)
    }

    func hasStoredSummaryAPIKey() -> Bool {
        KeychainHelper.exists(key: Keys.summaryApiKey)
    }

    private func applySummaryProviderDefaultsIfNeeded(oldValue: SummaryProvider) {
        if summaryModel.isEmpty || summaryModel == oldValue.defaultModel {
            summaryModel = summaryProvider.defaultModel
        }

        if summaryEndpoint.isEmpty || summaryEndpoint == oldValue.defaultEndpoint {
            summaryEndpoint = summaryProvider.defaultEndpoint
        }
    }

    private static func migratedSummaryModel(_ storedModel: String?, for provider: SummaryProvider) -> String {
        guard let storedModel, !storedModel.isEmpty else {
            return provider.defaultModel
        }

        switch provider {
        case .openAI:
            return storedModel == SummaryProvider.ollama.defaultModel ? provider.defaultModel : storedModel
        case .anthropic:
            return storedModel == SummaryProvider.ollama.defaultModel ? provider.defaultModel : storedModel
        case .ollama:
            return storedModel
        }
    }

    private static func migratedSummaryEndpoint(_ storedEndpoint: String?, for provider: SummaryProvider) -> String {
        guard let storedEndpoint, !storedEndpoint.isEmpty else {
            return provider.defaultEndpoint
        }

        switch provider {
        case .openAI:
            return storedEndpoint == SummaryProvider.ollama.defaultEndpoint ? provider.defaultEndpoint : storedEndpoint
        case .anthropic:
            return storedEndpoint == SummaryProvider.ollama.defaultEndpoint ? provider.defaultEndpoint : storedEndpoint
        case .ollama:
            return storedEndpoint
        }
    }

    enum Keys {
        static let outputRootPath = "outputRootPath"
        static let transcriptionLocale = "transcriptionLocale"
        static let summaryProvider = "summaryProvider"
        static let summaryModel = "summaryModel"
        static let summaryEndpoint = "summaryEndpoint"
        static let summaryApiKey = "summaryApiKey"
        static let openSummaryOnCompletion = "openSummaryOnCompletion"
        static let openSessionFolderOnCompletion = "openSessionFolderOnCompletion"
        static let launchAtLogin = "launchAtLogin"
        static let preferredHotkey = "preferredHotkey"
        static let calendarIntegrationEnabled = "calendarIntegrationEnabled"
        static let selectedGoogleCalendarID = "selectedGoogleCalendarID"
        static let selectedGoogleCalendarName = "selectedGoogleCalendarName"
        static let googleCalendarRefreshToken = "googleCalendarRefreshToken"
        static let googleCalendarAccessToken = "googleCalendarAccessToken"
        static let googleCalendarIDToken = "googleCalendarIDToken"
        static let googleCalendarClientSecret = "googleCalendarClientSecret"
        static let googleCalendarTokenExpiry = "googleCalendarTokenExpiry"
        static let googleCalendarAccountEmail = "googleCalendarAccountEmail"
        static let googleCalendarAccountName = "googleCalendarAccountName"
    }
}

private struct GoogleOAuthConfiguration {
    let clientID: String
    let clientSecret: String

    static func load(bundle: Bundle = .main) -> GoogleOAuthConfiguration {
        if let configuration = loadFromBundle(bundle: bundle) {
            return configuration
        }

        let environment = ProcessInfo.processInfo.environment
        return GoogleOAuthConfiguration(
            clientID: environment["GOOGLE_CALENDAR_CLIENT_ID"] ?? "",
            clientSecret: environment["GOOGLE_CALENDAR_CLIENT_SECRET"] ?? ""
        )
    }

    private static func loadFromBundle(bundle: Bundle) -> GoogleOAuthConfiguration? {
        guard
            let url = bundle.url(forResource: "GoogleOAuthConfig", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        return GoogleOAuthConfiguration(
            clientID: plist["GOOGLE_CALENDAR_CLIENT_ID"] as? String ?? "",
            clientSecret: plist["GOOGLE_CALENDAR_CLIENT_SECRET"] as? String ?? ""
        )
    }
}

private struct DeveloperConfiguration {
    let useLocalSecretStore: Bool
    let summaryAPIKey: String

    static func load(bundle: Bundle = .main) -> DeveloperConfiguration {
        if let configuration = loadFromBundle(bundle: bundle) {
            return configuration
        }

        let environment = ProcessInfo.processInfo.environment
        return DeveloperConfiguration(
            useLocalSecretStore: Self.parseBool(environment["SPOOL_USE_LOCAL_SECRET_STORE"]),
            summaryAPIKey: environment["SPOOL_SUMMARY_API_KEY"] ?? environment["OPENAI_API_KEY"] ?? ""
        )
    }

    private static func loadFromBundle(bundle: Bundle) -> DeveloperConfiguration? {
        guard
            let url = bundle.url(forResource: "DeveloperConfig", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        return DeveloperConfiguration(
            useLocalSecretStore: parseBool(plist["SPOOL_USE_LOCAL_SECRET_STORE"]),
            summaryAPIKey: plist["SPOOL_SUMMARY_API_KEY"] as? String ?? plist["OPENAI_API_KEY"] as? String ?? ""
        )
    }

    private static func parseBool(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            return ["1", "true", "yes", "on"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }
}

@MainActor
enum KeychainHelper {
    private static let service = "Spool"
    private static let envelopeAccount = "_spoolSecrets"
    private static let developerConfiguration = DeveloperConfiguration.load()
    private static let localSecretsURL: URL = {
        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Spool", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "DeveloperSecrets.plist")
    }()
    private static var cachedEnvelope: [String: String]?

    static func save(key: String, value: String) {
        if developerConfiguration.useLocalSecretStore {
            saveToLocalStore(key: key, value: value)
            return
        }

        var secrets = cachedEnvelope ?? loadEnvelopeFromKeychain()
        secrets[key] = value
        saveEnvelopeToKeychain(secrets)
    }

    static func load(key: String) -> String? {
        if developerConfiguration.useLocalSecretStore {
            if let stored = loadFromLocalStore(key: key), !stored.isEmpty {
                return stored
            }
            if key == AppSettings.Keys.summaryApiKey {
                let bundled = developerConfiguration.summaryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return bundled.isEmpty ? nil : bundled
            }
            return nil
        }

        return (cachedEnvelope ?? loadEnvelopeFromKeychain())[key]
    }

    static func exists(key: String) -> Bool {
        if developerConfiguration.useLocalSecretStore {
            if let stored = loadFromLocalStore(key: key), !stored.isEmpty {
                return true
            }
            if key == AppSettings.Keys.summaryApiKey {
                return !developerConfiguration.summaryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }

        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: envelopeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func delete(key: String) {
        if developerConfiguration.useLocalSecretStore {
            deleteFromLocalStore(key: key)
            return
        }

        var secrets = cachedEnvelope ?? loadEnvelopeFromKeychain()
        secrets.removeValue(forKey: key)
        if secrets.isEmpty {
            deleteEnvelopeFromKeychain()
        } else {
            saveEnvelopeToKeychain(secrets)
        }
    }

    private static func loadEnvelopeFromKeychain() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: envelopeAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return [:] }

        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            return [:]
        }

        cachedEnvelope = plist
        return plist
    }

    private static func saveEnvelopeToKeychain(_ secrets: [String: String]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: secrets, format: .xml, options: 0) else {
            return
        }

        deleteEnvelopeFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: envelopeAccount,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
        cachedEnvelope = secrets
    }

    private static func deleteEnvelopeFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: envelopeAccount,
        ]
        SecItemDelete(query as CFDictionary)
        cachedEnvelope = [:]
    }

    private static func loadFromLocalStore(key: String) -> String? {
        localSecrets()[key]
    }

    private static func saveToLocalStore(key: String, value: String) {
        var secrets = localSecrets()
        secrets[key] = value
        writeLocalSecrets(secrets)
    }

    private static func deleteFromLocalStore(key: String) {
        var secrets = localSecrets()
        secrets.removeValue(forKey: key)
        writeLocalSecrets(secrets)
    }

    private static func localSecrets() -> [String: String] {
        guard
            let data = try? Data(contentsOf: localSecretsURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else {
            return [:]
        }
        return plist
    }

    private static func writeLocalSecrets(_ secrets: [String: String]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: secrets, format: .xml, options: 0) else {
            return
        }
        try? data.write(to: localSecretsURL, options: .atomic)
    }
}
