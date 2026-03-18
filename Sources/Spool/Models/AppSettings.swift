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
        summaryApiKey = ""
    }

    var outputRootURL: URL? {
        guard !outputRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: outputRootPath, isDirectory: true)
    }

    var needsOnboarding: Bool {
        outputRootPath.isEmpty || (summaryProvider.requiresAPIKey && !hasStoredSummaryAPIKey())
    }

    var isSummaryAPIKeyMissing: Bool {
        summaryProvider.requiresAPIKey && !hasStoredSummaryAPIKey()
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

    private enum Keys {
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
    }
}

enum KeychainHelper {
    private static let service = "Spool"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func exists(key: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
