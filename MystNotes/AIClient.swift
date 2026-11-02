import Foundation

/// Why an AI request failed, in words fit to show as-is.
nonisolated enum AIError: Error, Equatable, LocalizedError {
    case noKey
    case unauthorized
    case rateLimited
    case modelUnavailable
    case offline
    case server(Int)
    case decoding
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your Featherless API key in Settings to use the AI Study Helper."
        case .unauthorized:
            return "Featherless didn't accept that key. Check it in Settings and try again."
        case .rateLimited:
            return "Featherless is asking us to slow down. Wait a moment and try again."
        case .modelUnavailable:
            return "That model isn't available right now. Pick another one in Settings."
        case .offline:
            return "You seem to be offline. Your notes are fine; try again when you're connected."
        case .server(let code):
            return "Featherless had a problem (\(code)). Try again in a little while."
        case .decoding:
            return "The answer came back in a shape we couldn't read. Try again."
        case .other(let message):
            return message
        }
    }

    /// Maps an HTTP status to an error; nil for success.
    static func from(status: Int) -> AIError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 404, 400: return .modelUnavailable
        case 429: return .rateLimited
        default: return .server(status)
        }
    }

    static func from(urlError: URLError) -> AIError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotFindHost, .cannotConnectToHost, .timedOut:
            return .offline
        default:
            return .other("The request couldn't be completed (\(urlError.localizedDescription)).")
        }
    }
}

/// Featherless.ai client (OpenAI-compatible). Only talks to the network when
/// a caller invokes it; never on its own. The key is never logged.
nonisolated struct AIClient {
    static let defaultModel = "Qwen/Qwen2.5-7B-Instruct"
    static let baseURL = URL(string: "https://api.featherless.ai/v1")!

    var apiKey: String?
    var model: String
    var session: URLSession
    var baseURL: URL

    init(apiKey: String? = Keychain.get(Keychain.Account.featherless),
         model: String = AIClient.defaultModel,
         session: URLSession = .shared,
         baseURL: URL = AIClient.baseURL) {
        self.apiKey = apiKey
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? AIClient.defaultModel : trimmed
        self.session = session
        self.baseURL = baseURL
    }

    struct Message: Codable, Equatable {
        var role: String
        var content: String
    }

    private struct RequestBody: Encodable {
        var model: String
        var messages: [Message]
        var max_tokens: Int
        var temperature: Double
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { var content: String? }
            var message: Msg
        }
        var choices: [Choice]
    }

    /// Builds the chat-completions request. Separate so tests can inspect it.
    func makeRequest(system: String, user: String, maxTokens: Int, temperature: Double = 0.4) throws -> URLRequest {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AIError.noKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = RequestBody(
            model: model,
            messages: [Message(role: "system", content: system), Message(role: "user", content: user)],
            max_tokens: maxTokens,
            temperature: temperature)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func complete(system: String, user: String, maxTokens: Int = 900) async throws -> String {
        let request = try makeRequest(system: system, user: user, maxTokens: maxTokens)
        let data = try await send(request)
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let text = decoded.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw AIError.decoding }
        return text
    }

    /// A one-token completion: checks the key and the chosen model together.
    func testConnection() async throws {
        _ = try await complete(system: "Reply with one word.", user: "Hi", maxTokens: 1)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, let error = AIError.from(status: http.statusCode) {
                throw error
            }
            return data
        } catch let error as AIError {
            throw error
        } catch let error as URLError {
            throw AIError.from(urlError: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIError.other("The request couldn't be completed.")
        }
    }
}

// MARK: - Prompts

nonisolated struct QuizItem: Codable, Equatable, Identifiable {
    var question: String
    var answer: String
    var id: String { question }
}

nonisolated enum StudyPrompts {
    static let contextLimit = 12_000
    static let truncationMarker = "\n\n[... middle of the notes omitted for length ...]\n\n"

    /// Keeps the start and the end when the text is over `limit`; the result,
    /// marker included, never exceeds `limit` characters.
    static func truncate(_ text: String, limit: Int = contextLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let budget = max(0, limit - truncationMarker.count)
        let head = budget * 2 / 3
        let tail = budget - head
        return String(trimmed.prefix(head)) + truncationMarker + String(trimmed.suffix(tail))
    }

    static func summarize(notes: String) -> (system: String, user: String) {
        ("You are a careful study assistant. Summarize the student's notes as a short bulleted list of the key points. Use only what the notes say. Be concise.",
         "Notes:\n\(truncate(notes))\n\nSummarize these notes.")
    }

    static func explain(notes: String) -> (system: String, user: String) {
        ("You are a patient tutor. Explain the material in the student's notes clearly, step by step, in plain language, with a short example where it helps. Use only what the notes cover.",
         "Notes:\n\(truncate(notes))\n\nExplain this like a tutor would.")
    }

    static func quiz(notes: String) -> (system: String, user: String) {
        ("You write study questions. Reply with ONLY a JSON array of at most 8 objects, each {\"question\": string, \"answer\": string}. No prose, no code fences.",
         "Notes:\n\(truncate(notes))\n\nWrite a quiz on these notes.")
    }

    static func ask(question: String, notes: String) -> (system: String, user: String) {
        ("You answer questions about the student's notes. Use the notes as context; if they don't contain the answer, say so briefly and then help as best you can.",
         "Notes:\n\(truncate(notes))\n\nQuestion: \(question)")
    }

    /// Pulls a `[{question, answer}]` array out of a reply that may carry
    /// prose or code fences around it. Capped at 8 items.
    static func parseQuiz(_ reply: String) -> [QuizItem] {
        let chars = Array(reply)
        var start = 0
        while start < chars.count {
            guard let open = chars[start...].firstIndex(of: "[") else { return [] }
            if let close = matchingBracket(chars, from: open) {
                let slice = String(chars[open...close])
                if let data = slice.data(using: .utf8),
                   let items = try? JSONDecoder().decode([QuizItem].self, from: data) {
                    return Array(items.filter { !$0.question.isEmpty }.prefix(8))
                }
            }
            start = open + 1
        }
        return []
    }

    /// Index of the `]` matching the `[` at `from`, ignoring brackets in strings.
    private static func matchingBracket(_ chars: [Character], from: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = from
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }
}
