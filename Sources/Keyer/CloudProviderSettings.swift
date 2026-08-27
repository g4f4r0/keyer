import Foundation
import Security

@MainActor
final class PortableSettingsSync: NSObject {
    static let shared = PortableSettingsSync()

    static let portableKeys: Set<String> = [
        "clean-up-spoken-text",
        "hold-shortcut",
        "openrouter-speech-model",
        "openrouter-text-model",
        "show-dock-icon",
        "show-meeting-controls",
        "show-menu-bar-icon",
        "suggest-meetings",
    ]

    var onExternalChange: ((Set<String>) -> Void)?

    private let cloud = NSUbiquitousKeyValueStore.default
    private let local = UserDefaults.standard
    private var isApplyingCloudChange = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: local
        )
    }

    func bootstrap() {
        cloud.synchronize()
        var changed = Set<String>()
        isApplyingCloudChange = true
        for key in Self.portableKeys {
            if let value = cloud.object(forKey: key) {
                local.set(value, forKey: key)
                changed.insert(key)
            }
        }
        isApplyingCloudChange = false
        mirrorLocalValuesToCloud()
        if !changed.isEmpty { onExternalChange?(changed) }
    }

    @objc private func cloudDidChange(_ notification: Notification) {
        let changedKeys = Set(
            (notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? [])
                .filter(Self.portableKeys.contains)
        )
        guard !changedKeys.isEmpty else { return }
        isApplyingCloudChange = true
        for key in changedKeys {
            if let value = cloud.object(forKey: key) {
                local.set(value, forKey: key)
            } else {
                local.removeObject(forKey: key)
            }
        }
        isApplyingCloudChange = false
        onExternalChange?(changedKeys)
    }

    @objc private func localDidChange(_ notification: Notification) {
        guard !isApplyingCloudChange else { return }
        mirrorLocalValuesToCloud()
    }

    private func mirrorLocalValuesToCloud() {
        for key in Self.portableKeys {
            guard let value = local.object(forKey: key) else { continue }
            if !propertyListValuesEqual(value, cloud.object(forKey: key)) {
                cloud.set(value, forKey: key)
            }
        }
        cloud.synchronize()
    }

    private func propertyListValuesEqual(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }
}

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

    func verifySynchronizableKeychain() throws -> Bool {
        let probe = ProviderKeychain(
            service: "com.keyer.app.sync-probe",
            account: UUID().uuidString
        )
        let expected = UUID().uuidString
        defer { try? probe.remove() }
        try probe.save(expected)
        return try probe.read() == expected
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
        if let value = try read(synchronizable: true) { return value }
        guard let legacyValue = try read(synchronizable: false) else { return nil }
        try save(legacyValue)
        try remove(synchronizable: false)
        return legacyValue
    }

    private func read(synchronizable: Bool) throws -> String? {
        var query = baseQuery(synchronizable: synchronizable)
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
        let query = baseQuery(synchronizable: true)
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
        try remove(synchronizable: true)
        try remove(synchronizable: false)
    }

    private func remove(synchronizable: Bool) throws {
        let status = SecItemDelete(baseQuery(synchronizable: synchronizable) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudProviderError.credentialStore(status)
        }
    }

    private func baseQuery(synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ]
    }
}
