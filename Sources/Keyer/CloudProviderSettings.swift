import Foundation
import Security
import WaveCore

actor RemoteTranscriptStore {
    private let baseURL = URL(string: "https://keyer.hellogafaro.net/api/records")!

    func sync(_ record: TranscriptArchiveRecord) async throws {
        guard let token = try ProviderKeychain(
            service: "com.keyer.app.server-credentials",
            account: "upload-token"
        ).read(), !token.isEmpty else {
            throw CloudProviderError.missingAPIKey
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(record)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 201 else {
            throw CloudProviderError.invalidResponse
        }
    }

    func syncMeeting(_ record: TranscriptArchiveRecord, audioURL: URL) async throws {
        try await sync(record)
        guard let token = try ProviderKeychain(
            service: "com.keyer.app.server-credentials",
            account: "upload-token"
        ).read(), !token.isEmpty else {
            throw CloudProviderError.missingAPIKey
        }
        let endpoint = baseURL
            .appendingPathComponent(record.id.uuidString.lowercased())
            .appendingPathComponent("audio")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: audioURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CloudProviderError.invalidResponse
        }
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

struct OpenRouterModelChoice: Identifiable, Equatable, Sendable {
    let name: String
    let identifier: String
    var id: String { identifier }
}

private actor OpenRouterModelCatalog {
    private struct Response: Decodable { let data: [Model] }
    private struct Model: Decodable {
        let id: String
        let name: String
    }

    func models(outputModality: String, apiKey: String) async throws -> [OpenRouterModelChoice] {
        var components = URLComponents(string: "https://openrouter.ai/api/v1/models")!
        components.queryItems = [URLQueryItem(name: "output_modalities", value: outputModality)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/g4f4r0/keyer", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Keyer", forHTTPHeaderField: "X-Title")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CloudProviderError.invalidResponse
        }
        return try JSONDecoder().decode(Response.self, from: data).data
            .map { OpenRouterModelChoice(name: $0.name, identifier: $0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class CloudProviderSettings: ObservableObject {
    static let defaultSpeechModel = "qwen/qwen3-asr-1.7b"
    static let defaultTextModel = "openai/gpt-5.6-luna"

    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var credentialMessage = ""
    @Published private(set) var speechModels: [OpenRouterModelChoice] = []
    @Published private(set) var textModels: [OpenRouterModelChoice] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelCatalogMessage = ""
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
    private let catalog = OpenRouterModelCatalog()

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
            await refreshModels()
        } catch {
            credentialMessage = "Couldn’t save the API key"
        }
    }

    func removeAPIKey() async {
        do {
            try keychain.remove()
            await configuration.setAPIKey(nil)
            hasAPIKey = false
            speechModels = []
            textModels = []
            modelCatalogMessage = ""
            credentialMessage = "API key removed"
        } catch {
            credentialMessage = "Couldn’t remove the API key"
        }
    }

    func refreshModels() async {
        guard hasAPIKey else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let snapshot = try await configuration.snapshot()
            let apiKey = snapshot.apiKey
            async let speech = catalog.models(outputModality: "transcription", apiKey: apiKey)
            async let text = catalog.models(outputModality: "text", apiKey: apiKey)
            speechModels = try await speech
            textModels = try await text
            modelCatalogMessage = ""
        } catch {
            modelCatalogMessage = "Couldn’t load the OpenRouter model catalog"
        }
    }

}

struct ProviderKeychain {
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
        ]
    }
}
