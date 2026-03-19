import Foundation

@MainActor
final class SessionStorage {
    private let settings: AppSettings
    private let fileManager = FileManager.default

    init(settings: AppSettings) {
        self.settings = settings
    }

    func createSession(callContext: CallContext?) throws -> SessionDescriptor {
        guard let root = settings.outputRootURL else {
            throw SessionStorageError.missingOutputRoot
        }

        let now = Date()
        let title = SessionNamer.makeTitle(from: callContext?.eventTitle)
        let slug = SessionNamer.makeSlug(from: title)
        let folderURL = root
            .appending(path: SessionNamer.sessionFolderName(from: now, slug: slug), directoryHint: .isDirectory)

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let summaryName = SessionNamer.summaryFileName(from: now, slug: slug)
        let paths = SessionPaths(
            folderURL: folderURL,
            summaryURL: folderURL.appending(path: summaryName),
            sessionURL: folderURL.appending(path: "session.json"),
            eventsURL: folderURL.appending(path: "events.jsonl"),
            rawTranscriptURL: folderURL.appending(path: "transcript.raw.txt"),
            transcriptURL: folderURL.appending(path: "transcript.txt"),
            logsURL: folderURL.appending(path: "logs.txt")
        )

        let descriptor = SessionDescriptor(
            sessionID: UUID(),
            startedAt: now,
            title: title,
            slug: slug,
            callContext: callContext,
            paths: paths
        )

        let metadata = SessionMetadata(
            sessionID: descriptor.sessionID,
            title: descriptor.title,
            startedAt: descriptor.startedAt,
            endedAt: nil,
            status: .recording,
            summaryProvider: settings.summaryProvider.rawValue,
            summaryModel: settings.summaryModel,
            transcriptionLocale: settings.transcriptionLocale,
            callContext: descriptor.callContext,
            artifacts: SessionArtifacts(
                eventsJSONL: paths.eventsURL.lastPathComponent,
                transcriptRaw: paths.rawTranscriptURL.lastPathComponent,
                transcriptFinal: paths.transcriptURL.lastPathComponent,
                summaryMarkdown: paths.summaryURL.lastPathComponent
            )
        )

        try writeSession(metadata, to: paths.sessionURL)
        try writeInitialArtifacts(for: descriptor)
        return descriptor
    }

    func completeSession(_ descriptor: SessionDescriptor) throws {
        var metadata = try loadSession(at: descriptor.paths.sessionURL)
        metadata.status = .completed
        metadata.endedAt = Date()
        try writeSession(metadata, to: descriptor.paths.sessionURL)
    }

    func markSummaryFailed(_ descriptor: SessionDescriptor) throws {
        var metadata = try loadSession(at: descriptor.paths.sessionURL)
        metadata.status = .summaryFailed
        metadata.endedAt = Date()
        try writeSession(metadata, to: descriptor.paths.sessionURL)
    }

    func appendUtterance(_ utterance: Utterance, to descriptor: SessionDescriptor) throws {
        let event = UtteranceEvent(type: "utterance_final", speaker: utterance.speaker.rawValue, timestamp: utterance.timestamp, text: utterance.text)
        try appendLine(encoded: event, to: descriptor.paths.eventsURL)
        try appendText("[\(Self.timeFormatter.string(from: utterance.timestamp))] \(utterance.speaker.displayName): \(utterance.text)\n", to: descriptor.paths.rawTranscriptURL)
    }

    func finalizeTranscript(for descriptor: SessionDescriptor, utterances: [Utterance]) throws -> String {
        let transcript = Self.makeTranscriptText(
            title: descriptor.title,
            startedAt: descriptor.startedAt,
            callContext: descriptor.callContext,
            utterances: utterances
        )
        try transcript.write(to: descriptor.paths.transcriptURL, atomically: true, encoding: .utf8)
        return transcript
    }

    func writeSummary(_ markdown: String, for descriptor: SessionDescriptor) throws {
        try markdown.write(to: descriptor.paths.summaryURL, atomically: true, encoding: .utf8)
    }

    func appendLog(_ message: String, to descriptor: SessionDescriptor?) {
        guard let descriptor else { return }
        let line = "[\(Self.timeFormatter.string(from: Date()))] \(message)\n"
        try? appendText(line, to: descriptor.paths.logsURL)
    }

    func renameSession(_ descriptor: SessionDescriptor, summaryTitle: String) throws -> SessionDescriptor {
        let normalizedTitle = SessionNamer.normalizedSummaryTitle(summaryTitle)
        let normalizedSlug = SessionNamer.makeSlug(from: normalizedTitle)

        var updatedDescriptor = descriptor
        updatedDescriptor.title = normalizedTitle
        updatedDescriptor.slug = normalizedSlug

        let parentURL = descriptor.paths.folderURL.deletingLastPathComponent()
        let renamedFolderURL = parentURL.appending(path: SessionNamer.sessionFolderName(from: descriptor.startedAt, slug: normalizedSlug), directoryHint: .isDirectory)
        let folderDidChange = renamedFolderURL != descriptor.paths.folderURL

        if folderDidChange {
            try fileManager.moveItem(at: descriptor.paths.folderURL, to: renamedFolderURL)
        }

        let activeFolderURL = folderDidChange ? renamedFolderURL : descriptor.paths.folderURL
        let updatedPaths = SessionPaths(
            folderURL: activeFolderURL,
            summaryURL: activeFolderURL.appending(path: SessionNamer.summaryFileName(from: descriptor.startedAt, slug: normalizedSlug)),
            sessionURL: activeFolderURL.appending(path: "session.json"),
            eventsURL: activeFolderURL.appending(path: "events.jsonl"),
            rawTranscriptURL: activeFolderURL.appending(path: "transcript.raw.txt"),
            transcriptURL: activeFolderURL.appending(path: "transcript.txt"),
            logsURL: activeFolderURL.appending(path: "logs.txt")
        )
        updatedDescriptor.paths = updatedPaths

        let oldSummaryURL = activeFolderURL.appending(path: descriptor.paths.summaryURL.lastPathComponent)
        if oldSummaryURL != updatedPaths.summaryURL, fileManager.fileExists(atPath: oldSummaryURL.path) {
            try fileManager.moveItem(at: oldSummaryURL, to: updatedPaths.summaryURL)
        }

        try updateSessionMetadata(at: updatedPaths.sessionURL) { metadata in
            metadata.title = normalizedTitle
            metadata.callContext = updatedDescriptor.callContext
            metadata.artifacts.summaryMarkdown = updatedPaths.summaryURL.lastPathComponent
        }

        return updatedDescriptor
    }

    private func writeInitialArtifacts(for descriptor: SessionDescriptor) throws {
        try appendLine(encoded: SessionBoundaryEvent(type: "session_started", timestamp: descriptor.startedAt), to: descriptor.paths.eventsURL)
        if let callContext = descriptor.callContext {
            try appendLine(encoded: SessionCallContextEvent(type: "calendar_context", timestamp: descriptor.startedAt, callContext: callContext), to: descriptor.paths.eventsURL)
        }
        try "".write(to: descriptor.paths.rawTranscriptURL, atomically: true, encoding: .utf8)
        try "".write(to: descriptor.paths.transcriptURL, atomically: true, encoding: .utf8)
        try "".write(to: descriptor.paths.logsURL, atomically: true, encoding: .utf8)
    }

    private func loadSession(at url: URL) throws -> SessionMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.spool.decode(SessionMetadata.self, from: data)
    }

    private func writeSession(_ metadata: SessionMetadata, to url: URL) throws {
        let data = try JSONEncoder.spool.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func updateSessionMetadata(at url: URL, update: (inout SessionMetadata) -> Void) throws {
        var metadata = try loadSession(at: url)
        update(&metadata)
        try writeSession(metadata, to: url)
    }

    private func appendLine<T: Encodable>(encoded value: T, to url: URL) throws {
        let data = try JSONEncoder.spool.encode(value)
        guard let line = String(data: data, encoding: .utf8)?.appending("\n") else { return }
        try appendText(line, to: url)
    }

    private func appendText(_ text: String, to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func makeTranscriptText(title: String, startedAt: Date, callContext: CallContext?, utterances: [Utterance]) -> String {
        var headerLines = [
            "Spool",
            "Title: \(title)",
            "Date: \(dateFormatter.string(from: startedAt))"
        ]

        if let callContext {
            headerLines.append("Calendar Event: \(callContext.eventTitle)")
            headerLines.append("Calendar: \(callContext.calendarName)")
            if !callContext.attendees.isEmpty {
                headerLines.append("Attendees: \(callContext.attendees.map(\.label).joined(separator: ", "))")
            }
        }

        let header = headerLines.joined(separator: "\n") + "\n\n"

        let body = utterances
            .map { "\($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")

        return header + body + "\n"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct SessionBoundaryEvent: Encodable {
    let type: String
    let timestamp: Date
}

private struct SessionCallContextEvent: Encodable {
    let type: String
    let timestamp: Date
    let callContext: CallContext
}

private struct UtteranceEvent: Encodable {
    let type: String
    let speaker: String
    let timestamp: Date
    let text: String
}

enum SessionStorageError: LocalizedError {
    case missingOutputRoot

    var errorDescription: String? {
        switch self {
        case .missingOutputRoot:
            "Choose an output folder before starting a recording."
        }
    }
}

private extension Speaker {
    var displayName: String {
        switch self {
        case .you:
            "You"
        case .them:
            "Them"
        }
    }
}

enum SessionNamer {
    static func makeTitle(from contextHint: String?) -> String {
        let trimmed = contextHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled Call" : trimmed
    }

    static func makeSlug(from title: String) -> String {
        let lowered = title.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let collapsed = String(filtered).split(separator: " ").joined(separator: "-")
        return collapsed.isEmpty ? "untitled-call" : collapsed
    }

    static func normalizedSummaryTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "Post-Call Summary:",
            "Post Call Summary:",
            "Call Summary:",
            "Summary:"
        ]

        for prefix in prefixes {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let cleaned = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? "Untitled Call" : cleaned
            }
        }

        return trimmed.isEmpty ? "Untitled Call" : trimmed
    }

    static func bestAvailableTitle(summaryTitle: String?, transcript: String, fallback: String) -> String {
        if let summaryTitle {
            let normalized = normalizedSummaryTitle(summaryTitle)
            if !isGenericTitle(normalized) {
                return normalized
            }
        }

        if let transcriptTitle = titleFromTranscript(transcript), !isGenericTitle(transcriptTitle) {
            return transcriptTitle
        }

        return fallback
    }

    private static func titleFromTranscript(_ transcript: String) -> String? {
        let lines = transcript
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Spool") && !$0.hasPrefix("Title:") && !$0.hasPrefix("Date:") }

        guard let firstContentLine = lines.first else { return nil }
        let speakerStripped = firstContentLine.replacingOccurrences(of: #"^(You|Them):\s*"#, with: "", options: .regularExpression)
        let cleaned = speakerStripped
            .replacingOccurrences(of: #"[^A-Za-z0-9\s-]"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(5)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        return cleaned.capitalized
    }

    static func isGenericTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "untitled call"
            || normalized == "post-call summary"
            || normalized == "call summary"
            || normalized == "summary"
            || normalized == "post call summary"
    }

    static func sessionFolderName(from date: Date, slug: String) -> String {
        "\(formatter("yyyy-MM-dd_HH-mm-ss").string(from: date))_\(slug)"
    }

    static func summaryFileName(from date: Date, slug: String) -> String {
        "\(formatter("yyyy-MM-dd").string(from: date))_\(slug).md"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}

private extension JSONEncoder {
    static var spool: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var spool: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
