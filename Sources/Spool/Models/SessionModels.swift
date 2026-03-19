import Foundation

enum Speaker: String, Codable, Sendable {
    case you
    case them
}

struct Utterance: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let speaker: Speaker
    let timestamp: Date

    init(id: UUID = UUID(), text: String, speaker: Speaker, timestamp: Date = .now) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

enum RecordingState: String {
    case idle
    case checkingPermissions
    case ready
    case recording
    case stopping
    case finalizingTranscript
    case summarizing
    case completed
    case failed
}

enum SessionStatus: String, Codable {
    case recording
    case interrupted
    case completed
    case summaryFailed = "summary_failed"
}

struct SessionPaths: Codable {
    var folderURL: URL
    var summaryURL: URL
    var sessionURL: URL
    var eventsURL: URL
    var rawTranscriptURL: URL
    var transcriptURL: URL
    var logsURL: URL
}

struct SessionDescriptor: Codable {
    let sessionID: UUID
    let startedAt: Date
    var title: String
    var slug: String
    var callContext: CallContext?
    var paths: SessionPaths
}

struct SessionMetadata: Codable {
    let sessionID: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var status: SessionStatus
    let summaryProvider: String
    let summaryModel: String
    let transcriptionLocale: String
    var callContext: CallContext?
    var artifacts: SessionArtifacts
}

struct SessionArtifacts: Codable {
    var eventsJSONL: String
    var transcriptRaw: String
    var transcriptFinal: String
    var summaryMarkdown: String
}
