import Foundation
import Observation
@preconcurrency import AVFoundation
@preconcurrency import Speech

@Observable
@MainActor
final class DictationController {
    private(set) var isRecording = false
    var errorMessage: String?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation = UUID()

    func start(onPartial: @escaping @MainActor (String) -> Void) async {
        guard !isRecording else { return }
        errorMessage = nil
        let session = UUID()
        generation = session
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard generation == session else { return }
        guard speechAllowed else { errorMessage = "音声入力を使うには、設定で音声認識を許可してください。"; return }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in continuation.resume(returning: allowed) }
        }
        guard generation == session else { return }
        guard microphoneAllowed else { errorMessage = "音声入力を使うには、設定でマイクを許可してください。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "この端末または言語ではオンデバイス音声入力を利用できません。キーボードで入力してください。"
            return
        }

        let audioEngine = AVAudioEngine()
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "マイクを利用できません。接続状態を確認してください。"])
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in recognitionRequest.append(buffer) }
            engine = audioEngine
            request = recognitionRequest
            isRecording = true
            recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == session, self.isRecording else { return }
                    if let text { onPartial(text) }
                    if finished || failed {
                        self.stop()
                        if failed && text == nil { self.errorMessage = "音声を認識できませんでした。マイクを押してもう一度試してください。" }
                    }
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stop()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        generation = UUID()
        isRecording = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
