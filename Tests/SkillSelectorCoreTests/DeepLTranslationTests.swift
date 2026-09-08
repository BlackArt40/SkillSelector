import Foundation
import XCTest
@testable import SkillSelectorCore

final class DeepLTranslationTests: XCTestCase {

    // MARK: - Endpoint / key shape

    func testFreeKeysResolveToTheFreeEndpoint() {
        XCTAssertTrue(DeepLTranslationClient.isFreeKey("abc123:fx"))
        XCTAssertFalse(DeepLTranslationClient.isFreeKey("abc123"))
        XCTAssertEqual(
            DeepLTranslationClient.endpointHost(for: "abc123:fx"),
            DeepLTranslationClient.freeHost
        )
        XCTAssertEqual(
            DeepLTranslationClient.endpointHost(for: "abc123"),
            DeepLTranslationClient.proHost
        )
    }

    // MARK: - Stubbed transport

    /// Minimal URLProtocol stub: a static handler receives every request.
    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient(apiKey: String = "abc123:fx") -> DeepLTranslationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DeepLTranslationClient(apiKey: apiKey, session: URLSession(configuration: configuration))
    }

    private func httpResponse(status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private let sampleURL = URL(string: "https://api-free.deepl.com/v2/translate")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testTranslatePostsFormBodyAndReturnsFirstTranslation() async throws {
        StubURLProtocol.handler = { request in
            // Request shape assertions.
            XCTAssertEqual(request.url?.host, DeepLTranslationClient.freeHost)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "DeepL-Auth-Key abc123:fx"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("text="), body)
            XCTAssertTrue(body.contains("target_lang=ZH"), body)
            XCTAssertTrue(body.contains("source_lang=EN"), body)

            let payload = #"{"translations":[{"detected_source_language":"EN","text":"你好世界"}]}"#
            return (self.httpResponse(status: 200, url: self.sampleURL), Data(payload.utf8))
        }

        let translated = try await makeClient().translate(
            "Hello world", sourceLanguage: "en", targetLanguage: "zh"
        )
        XCTAssertEqual(translated, "你好世界")
    }

    func testNilSourceOmitsTheSourceLangParameter() async throws {
        StubURLProtocol.handler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("source_lang"), body)
            let payload = #"{"translations":[{"text":"你好"}]}"#
            return (self.httpResponse(status: 200, url: self.sampleURL), Data(payload.utf8))
        }
        let translated = try await makeClient().translate(
            "Hello", sourceLanguage: nil, targetLanguage: "zh"
        )
        XCTAssertEqual(translated, "你好")
    }

    func testErrorStatusesMapToTypedErrors() async {
        let cases: [(status: Int, expected: TranslationClientError)] = [
            (403, .invalidAPIKey),
            (456, .quotaExceeded),
            (429, .rateLimited),
            (500, .network("HTTP 500")),
        ]
        for sample in cases {
            StubURLProtocol.handler = { request in
                (self.httpResponse(status: sample.status, url: self.sampleURL), Data())
            }
            do {
                _ = try await makeClient().translate("Hello", sourceLanguage: nil, targetLanguage: "ZH")
                XCTFail("expected \(sample.expected) for HTTP \(sample.status)")
            } catch let error as TranslationClientError {
                XCTAssertEqual(error, sample.expected)
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    func testEmptyTranslationsYieldUnexpectedResponse() async {
        StubURLProtocol.handler = { request in
            (self.httpResponse(status: 200, url: self.sampleURL), Data(#"{"translations":[]}"#.utf8))
        }
        do {
            _ = try await makeClient().translate("Hello", sourceLanguage: nil, targetLanguage: "ZH")
            XCTFail("expected unexpectedResponse")
        } catch let error as TranslationClientError {
            XCTAssertEqual(error, .unexpectedResponse)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testTransportFailuresSurfaceAsNetworkErrors() async {
        StubURLProtocol.handler = nil // no handler → connection failure
        do {
            _ = try await makeClient().translate("Hello", sourceLanguage: nil, targetLanguage: "ZH")
            XCTFail("expected a network error")
        } catch let error as TranslationClientError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
