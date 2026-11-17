import Foundation
import Testing
@testable import OhMyOpenClawInput

@MainActor
@Test func recognitionPreservesPartialAndFinalSnapshotsFromABackgroundQueue() async {
    let updates = await withCheckedContinuation { continuation in
        var received: [DictationUpdate] = []
        let deliver = DictationCallbacks.recognitionUpdates { update in
            MainActor.assertIsolated()
            received.append(update)
            if update.isFinal { continuation.resume(returning: received) }
        }
        DispatchQueue.global().async {
            deliver(DictationUpdate(text: "今日", isFinal: false, failed: false))
            deliver(DictationUpdate(text: "今日は晴れ", isFinal: false, failed: false))
            deliver(DictationUpdate(text: "今日は晴れです", isFinal: true, failed: false))
        }
    }
    #expect(updates.map(\.text) == ["今日", "今日は晴れ", "今日は晴れです"])
    #expect(updates.map(\.isFinal) == [false, false, true])
    #expect(updates.allSatisfy { !$0.failed })
}
