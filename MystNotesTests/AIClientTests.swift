import XCTest
@testable import Mystnotes

final class AIClientTests: XCTestCase {

    func testMakeRequest_buildsURLHeadersAndBody() throws {
        let client = AIClient(apiKey: "sk-test", model: "Qwen/Qwen2.5-7B-Instruct")
        let request = try client.makeRequest(system: "sys", user: "hello", maxTokens: 123)
        XCTAssertEqual(request.url?.absoluteString, "https://api.featherless.ai/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 60)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "Qwen/Qwen2.5-7B-Instruct")
        XCTAssertEqual(json["max_tokens"] as? Int, 123)
        XCTAssertNotNil(json["temperature"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"], "hello")
    }

    func testMakeRequest_withoutKey_throwsNoKey() {
        let client = AIClient(apiKey: nil)
        XCTAssertThrowsError(try client.makeRequest(system: "s", user: "u", maxTokens: 1)) {
            XCTAssertEqual($0 as? AIError, .noKey)
        }
        let blank = AIClient(apiKey: "  ")
        XCTAssertThrowsError(try blank.makeRequest(system: "s", user: "u", maxTokens: 1))
    }

    func testSpeechRequest_headersAndBody() throws {
        let client = SpeechClient(apiKey: "xi-key", voiceID: "abc")
        let request = try client.makeRequest(text: "Hi")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "xi-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/mpeg")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(json["text"], "Hi")
        XCTAssertEqual(json["model_id"], "eleven_multilingual_v2")
    }

    func testSpeechChunks_respectLimitAndKeepEverything() {
        let sentence = "This is a sentence. "
        let text = String(repeating: sentence, count: 400)
        let chunks = SpeechClient.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= SpeechClient.maxCharacters })
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " ").count,
                       text.split(separator: " ").count)
    }

    func testParseQuiz_extractsFromMessyText() {
        let reply = """
        Sure! Here is your quiz:
        ```json
        [{"question": "What is [x]?", "answer": "A placeholder"},
         {"question": "2+2?", "answer": "4"}]
        ```
        Hope that helps!
        """
        let items = StudyPrompts.parseQuiz(reply)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].question, "What is [x]?")
        XCTAssertEqual(items[1].answer, "4")
    }

    func testParseQuiz_garbageGivesEmpty_andCapsAtEight() {
        XCTAssertTrue(StudyPrompts.parseQuiz("no json here [oops").isEmpty)
        let many = (0..<12).map { "{\"question\":\"q\($0)\",\"answer\":\"a\"}" }.joined(separator: ",")
        XCTAssertEqual(StudyPrompts.parseQuiz("[\(many)]").count, 8)
    }

    func testTruncate_keepsStartAndEnd_underCap() {
        let text = "START" + String(repeating: "x", count: 50_000) + "END"
        let out = StudyPrompts.truncate(text)
        XCTAssertLessThanOrEqual(out.count, StudyPrompts.contextLimit)
        XCTAssertTrue(out.hasPrefix("START"))
        XCTAssertTrue(out.hasSuffix("END"))
        XCTAssertTrue(out.contains("omitted"))
        XCTAssertEqual(StudyPrompts.truncate("short"), "short")
    }

    func testErrorMapping_fromStatusCodes() {
        XCTAssertNil(AIError.from(status: 200))
        XCTAssertEqual(AIError.from(status: 401), .unauthorized)
        XCTAssertEqual(AIError.from(status: 429), .rateLimited)
        XCTAssertEqual(AIError.from(status: 404), .modelUnavailable)
        XCTAssertEqual(AIError.from(status: 503), .server(503))
        XCTAssertEqual(AIError.from(urlError: URLError(.notConnectedToInternet)), .offline)
        XCTAssertNotNil(AIError.unauthorized.errorDescription)
    }

    func testComplete_decodesStubbedResponse_andMapsStatus() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let client = AIClient(apiKey: "k", session: session)

        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"choices":[{"message":{"content":" Hi there "}}]}"#.utf8)
        let text = try await client.complete(system: "s", user: "u")
        XCTAssertEqual(text, "Hi there")

        StubProtocol.status = 401
        do {
            _ = try await client.complete(system: "s", user: "u")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? AIError, .unauthorized)
        }

        StubProtocol.status = 200
        StubProtocol.body = Data("not json".utf8)
        do {
            _ = try await client.complete(system: "s", user: "u")
            XCTFail("expected decoding")
        } catch {
            XCTAssertEqual(error as? AIError, .decoding)
        }
    }
}

nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
