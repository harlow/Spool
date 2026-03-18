import Foundation
import Observation

@Observable
@MainActor
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""
    var onAppend: ((Utterance) -> Void)?

    func append(_ utterance: Utterance) {
        utterances.append(utterance)
        onAppend?(utterance)
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
    }
}
