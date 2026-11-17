import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

struct DictationUpdate: Sendable {
    let text: String?
    let isFinal: Bool
    let failed: Bool
}

// These SDK callbacks may execute on permission, speech, or real-time audio
// queues. Form them outside the controller's MainActor isolation so Swift 6
// does not insert a main-executor assertion at callback entry.
enum DictationCallbacks {
    nonisolated static func speechAuthorization(
        _ continuation: CheckedContinuation<Bool, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { status in continuation.resume(returning: status == .authorized) }
    }

    nonisolated static func microphoneAuthorization(
        _ continuation: CheckedContinuation<Bool, Never>
    ) -> @Sendable (Bool) -> Void {
        { allowed in continuation.resume(returning: allowed) }
    }

    nonisolated static func audioTap(
        for request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
        // Append on the audio queue; never transfer a live audio buffer to UI.
        { buffer, _ in request.append(buffer) }
    }

    nonisolated static func recognition(
        onUpdate: @escaping @MainActor @Sendable (DictationUpdate) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        let deliver = recognitionUpdates(onUpdate: onUpdate)
        return { result, error in
            let update = DictationUpdate(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal == true,
                failed: error != nil
            )
            deliver(update)
        }
    }

    nonisolated static func recognitionUpdates(
        onUpdate: @escaping @MainActor @Sendable (DictationUpdate) -> Void
    ) -> @Sendable (DictationUpdate) -> Void {
        { update in
            // Keep partial/final callback order when crossing from the SDK queue.
            DispatchQueue.main.async { onUpdate(update) }
        }
    }
}
