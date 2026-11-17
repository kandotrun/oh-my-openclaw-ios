import Foundation
import Testing
@preconcurrency import AVFoundation
@preconcurrency import Speech
@testable import OhMyOpenClawInput

// Models legacy Objective-C APIs delivering their non-Sendable completion
// blocks on arbitrary queues. No permission request, microphone, or recognizer
// task is started by these tests.
private final class CallbackDelivery: @unchecked Sendable {
    let invoke: () -> Void
    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }

    nonisolated static func dispatch(_ invoke: @escaping () -> Void) {
        let delivery = CallbackDelivery(invoke)
        DispatchQueue.global().async { delivery.invoke() }
    }

    nonisolated static func permission<Value>(
        _ callback: @escaping (Value) -> Void, value: Value
    ) {
        dispatch { callback(value) }
    }

    nonisolated static func recognition(
        _ callback: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void,
        error: (any Error)?
    ) {
        dispatch { callback(nil, error) }
    }

    nonisolated static func audio(
        _ callback: @escaping AVAudioNodeTapBlock,
        buffer: AVAudioPCMBuffer,
        time: AVAudioTime,
        finished: CheckedContinuation<Void, Never>
    ) {
        dispatch {
            callback(buffer, time)
            finished.resume()
        }
    }
}

@MainActor
struct DictationCallbackTests {
    @Test func speechPermissionCanArriveOffMainActor() async {
        for status in [SFSpeechRecognizerAuthorizationStatus.authorized, .denied, .restricted] {
            let allowed = await withCheckedContinuation { continuation in
                CallbackDelivery.permission(DictationCallbacks.speechAuthorization(continuation), value: status)
            }
            #expect(allowed == (status == .authorized))
        }
    }

    @Test func microphonePermissionCanArriveOffMainActor() async {
        for expected in [true, false] {
            let allowed = await withCheckedContinuation { continuation in
                CallbackDelivery.permission(DictationCallbacks.microphoneAuthorization(continuation), value: expected)
            }
            #expect(allowed == expected)
        }
    }

    @Test func recognitionReturnsOnlyValuesToMainActor() async {
        let update = await withCheckedContinuation { continuation in
            let callback = DictationCallbacks.recognition { update in
                MainActor.assertIsolated()
                continuation.resume(returning: update)
            }
            CallbackDelivery.recognition(callback, error: NSError(domain: "Test", code: 1))
        }
        #expect(update.text == nil)
        #expect(!update.isFinal)
        #expect(update.failed)
    }

    @Test func audioTapCanAppendSyntheticBufferOffMainActor() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let request = SFSpeechAudioBufferRecognitionRequest()
        let callback = DictationCallbacks.audioTap(for: request)
        await withCheckedContinuation { continuation in
            CallbackDelivery.audio(callback, buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000), finished: continuation)
        }
        request.endAudio()
    }
}
