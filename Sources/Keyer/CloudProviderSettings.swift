import Foundation
import Security

struct CloudProviderSnapshot: Sendable {
    let apiKey: String
    let speechModel: String
    let textModel: String
}

actor CloudProviderConfiguration {
    private var apiKey: String?
    private var speechModel: String
    private var textModel: String

    init(apiKey: String?, speechModel: String, textModel: String) {
        self.apiKey = apiKey
        self.speechModel = speechModel
        self.textModel = textModel
    }

    func snapshot() throws -> CloudProviderSnapshot {
        guard let apiKey, !apiKey.isEmpty else { throw CloudProviderError.missingAPIKey }
        return CloudProviderSnapshot(
            apiKey: apiKey,
            speechModel: speechModel,
            textModel: textModel
        )
    }

    func hasAPIKey() -> Bool { apiKey?.isEmpty == false }
    func setAPIKey(_ value: String?) { apiKey = value }
    func setSpeechModel(_ value: String) { speechModel = value }
    func setTextModel(_ value: String) { textModel = value }
}

@MainActor
final class CloudProviderSettings: ObservableObject {
    static let defaultSpeechModel = "qwen/qwen3-asr-1.7b"
    static let defaultTextModel = "openai/gpt-5.6-luna"

    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var credentialMessage = ""
    @Published var speechModel: String {
        didSet {
            UserDefaults.standard.set(speechModel, forKey: "openrouter-speech-model")
            Task { await configuration.setSpeechModel(speechModel) }
        }
    }
    @Published var textModel: String {
        didSet {
            UserDefaults.standard.set(textModel, forKey: "openrouter-text-model")
            Task { await configuration.setTextModel(textModel) }
        }
    }

    let configuration: CloudProviderConfiguration
    private let keychain = ProviderKeychain()

    init() {
        let apiKey = try? keychain.read()
        let speechModel = UserDefaults.standard.string(forKey: "openrouter-speech-model")
            ?? Self.defaultSpeechModel
        let textModel = UserDefaults.standard.string(forKey: "openrouter-text-model")
            ?? Self.defaultTextModel
        self.speechModel = speechModel
        self.textModel = textModel
        hasAPIKey = apiKey?.isEmpty == false
        configuration = CloudProviderConfiguration(
            apiKey: apiKey,
            speechModel: speechModel,
            textModel: textModel
        )
    }

    func saveAPIKey(_ rawValue: String) async {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            credentialMessage = "Enter an API key"
            return
        }
        do {
            try keychain.save(value)
            await configuration.setAPIKey(value)
            hasAPIKey = true
            credentialMessage = "Saved securely"
        } catch {
            credentialMessage = "Couldn’t save the API key"
        }
    }

    func removeAPIKey() async {
        do {
            try keychain.remove()
            await configuration.setAPIKey(nil)
            hasAPIKey = false
            credentialMessage = "API key removed"
        } catch {
            credentialMessage = "Couldn’t remove the API key"
        }
    }

}

private struct ProviderKeychain {
    private let service: String
    private let account: String

    init(
        service: String = "com.keyer.app.provider-credentials",
        account: String = "openrouter-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func read() throws -> String? {
        try readItem()
    }

    private func readItem() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CloudProviderError.credentialStore(status)
        }
        return value
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let query = baseQuery()
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw CloudProviderError.credentialStore(insertStatus)
            }
        } else if status != errSecSuccess {
            throw CloudProviderError.credentialStore(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudProviderError.credentialStore(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ]
    }
}
