import Foundation

/// Protocol for the description-translation backends. Cloud providers are
/// strictly opt-in (design decision on the macOS 12 fallback path): the
/// app ships with none configured and makes no translation request until
/// the user stores an API key in Settings.
public protocol TranslationProviding: Sendable {
    /// Translates `text` into `targetLanguage` (an ISO code like "ZH").
    /// `sourceLanguage` may be nil for server-side auto-detection.
    func translate(
        _ text: String,
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> String
}

/// Errors from the translation backends. Carries no user-facing copy —
/// the app layer maps these to localized strings (Core holds no L10n).
public enum TranslationClientError: Error, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case quotaExceeded
    case rateLimited
    case network(String)
    case unexpectedResponse
}

/// DeepL Translation API client. Free-tier keys (suffixed `:fx`) hit
/// `api-free.deepl.com`; everything else hits the pro endpoint. Requests
/// are form-encoded POSTs, exactly as DeepL's reference documents them.
public struct DeepLTranslationClient: TranslationProviding {
    public static let freeHost = "api-free.deepl.com"
    public static let proHost = "api.deepl.com"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Free keys end with ":fx" and resolve to the free endpoint.
    public static func isFreeKey(_ key: String) -> Bool {
        key.hasSuffix(":fx")
    }

    public static func endpointHost(for apiKey: String) -> String {
        isFreeKey(apiKey) ? freeHost : proHost
    }

    public func translate(
        _ text: String,
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> String {
        var request = URLRequest(
            url: URL(string: "https://\(Self.endpointHost(for: apiKey))/v2/translate")!
        )
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        var queryItems = [URLQueryItem(name: "text", value: text)]
        if let source = sourceLanguage {
            queryItems.append(URLQueryItem(name: "source_lang", value: source.uppercased()))
        }
        queryItems.append(URLQueryItem(name: "target_lang", value: targetLanguage.uppercased()))
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranslationClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranslationClientError.network("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 403:
            throw TranslationClientError.invalidAPIKey
        case 456:
            throw TranslationClientError.quotaExceeded
        case 429:
            throw TranslationClientError.rateLimited
        default:
            throw TranslationClientError.network("HTTP \(http.statusCode)")
        }

        struct Payload: Decodable {
            struct Item: Decodable { let text: String }
            let translations: [Item]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let translated = payload.translations.first?.text,
              !translated.isEmpty
        else {
            throw TranslationClientError.unexpectedResponse
        }
        return translated
    }
}
