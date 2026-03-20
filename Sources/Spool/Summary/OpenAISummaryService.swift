import Foundation

struct SummaryResult {
    let markdown: String
    let title: String
}

enum OpenAISummaryError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenAI API key is missing."
        case .invalidResponse:
            "OpenAI returned an invalid summary response."
        case .requestFailed(let message):
            message
        }
    }
}

@MainActor
final class OpenAISummaryService {
    private let settings: AppSettings
    private let urlSession: URLSession

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.urlSession = session
    }

    func summarize(transcript: String, descriptor: SessionDescriptor) async throws -> SummaryResult {
        settings.loadSummaryAPIKeyIfNeeded()
        let apiKey = settings.summaryApiKey
        guard !apiKey.isEmpty else { throw OpenAISummaryError.missingAPIKey }

        let requestBody = ChatCompletionsRequest(
            model: settings.summaryModel,
            messages: [
                .init(
                    role: "developer",
                    text: Self.systemPrompt
                ),
                .init(
                    role: "user",
                    text: Self.userPrompt(
                        transcript: transcript,
                        startedAt: descriptor.startedAt,
                        callContext: descriptor.callContext
                    )
                )
            ],
            reasoningEffort: "minimal"
        )

        var request = URLRequest(url: URL(string: "\(settings.summaryEndpoint)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAISummaryError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? "Unknown OpenAI error."
            throw OpenAISummaryError.requestFailed("OpenAI summary request failed (\(http.statusCode)): \(responseText)")
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        let markdown = decoded.choices.first?.message.content?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        guard !markdown.isEmpty else { throw OpenAISummaryError.invalidResponse }

        let extractedTitle = Self.extractTitle(from: markdown)
        let title = SessionNamer.bestAvailableTitle(
            summaryTitle: extractedTitle,
            transcript: transcript,
            fallback: descriptor.title
        )
        return SummaryResult(markdown: markdown, title: title)
    }

    private static let systemPrompt = """
    You write grounded post-call summaries in Markdown.
    Use only facts supported by the transcript.
    If a detail is uncertain, say so.
    Do not invent names, owners, or decisions.
    Return only Markdown with YAML frontmatter followed by the body.
    Generate a concise descriptive call title based on the transcript.
    Do not use generic titles like "Untitled Call", "Post-Call Summary", or "Call Summary" unless the transcript is truly empty.
    Prefer a short topic-based title such as "Call Test Recording", "Pricing Follow-Up", or "Customer Research Intro".
    The body must include:
    - H1 title
    - Overview
    - Key Points
    - Decisions
    - Action Items
    - Open Questions
    - Notable Quotes
    """

    private static func userPrompt(transcript: String, startedAt: Date, callContext: CallContext?) -> String {
        var lines = [
            "Create a post-call summary for this transcript.",
            "",
            "Session started at: \(startedAt.ISO8601Format())"
        ]

        if let callContext {
            lines.append("Calendar event title: \(callContext.eventTitle)")
            lines.append("Calendar name: \(callContext.calendarName)")
            if !callContext.attendees.isEmpty {
                lines.append("Calendar attendees: \(callContext.attendees.map(\.label).joined(separator: ", "))")
            }
        }

        lines.append("")
        lines.append("Transcript:")
        lines.append(transcript)
        return lines.joined(separator: "\n")
    }

    private static func extractTitle(from markdown: String) -> String? {
        if let frontmatterTitle = extractFrontmatterTitle(from: markdown) {
            return frontmatterTitle
        }

        for line in markdown.split(separator: "\n") {
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func extractFrontmatterTitle(from markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return nil }

        for line in lines.dropFirst() {
            if line == "---" {
                break
            }

            if line.lowercased().hasPrefix("title:") {
                let rawValue = line.dropFirst("title:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        return nil
    }
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let reasoningEffort: String

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case reasoningEffort = "reasoning_effort"
    }
}

private struct ChatMessage: Encodable {
    let role: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case role
        case text = "content"
    }
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatChoiceMessage
}

private struct ChatChoiceMessage: Decodable {
    let content: String?
}
