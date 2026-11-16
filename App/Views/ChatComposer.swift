import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import OhMyOpenClawCore

struct ChatComposer: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var photoPickerContextID: String?
    @State private var filePickerContextID: String?
    @State private var inputError: String?
    @State private var dictation = DictationController()
    @State private var dictationLastApplied = ""
    @FocusState private var fieldFocused: Bool

    private var isRunning: Bool { model.activity != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty { attachmentTray }
            modelPicker
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button("写真を選ぶ", systemImage: "photo") { photoPickerContextID = model.composerContextID; showPhotoPicker = true }
                    Button("ファイルを選ぶ", systemImage: "doc") { filePickerContextID = model.composerContextID; showFilePicker = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 40, height: 42)
                }
                .accessibilityLabel("添付する")

                TextField(placeholder, text: $model.draftText, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...7)
                    .padding(.vertical, 12)
                    .focused($fieldFocused)
                    .accessibilityIdentifier("composerField")
                    .onChange(of: model.draftText) { _, value in
                        if dictation.isRecording && value != dictationLastApplied { dictation.stop() }
                    }

                Button { toggleDictation() } label: {
                    Image(systemName: dictation.isRecording ? "waveform" : "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(dictation.isRecording ? .red : .secondary)
                        .frame(width: 36, height: 42)
                }
                .accessibilityLabel(dictation.isRecording ? "音声入力を終える" : "音声入力")

                if isRunning {
                    Button {
                        dictation.stop()
                        Task { await model.stop() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.07), in: Circle())
                    }
                    .accessibilityLabel("応答を停止")
                    .accessibilityIdentifier("stopButton")
                    .padding(.bottom, 3)
                } else {
                    Button {
                        dictation.stop()
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(model.canSend ? Color.white : Color.secondary)
                            .frame(width: 36, height: 36)
                            .background(model.canSend ? ChatTheme.accent : Color.primary.opacity(0.06), in: Circle())
                    }
                    .disabled(!model.canSend)
                    .accessibilityLabel("送信")
                    .accessibilityIdentifier("sendButton")
                    .padding(.bottom, 3)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 29))
            .overlay(RoundedRectangle(cornerRadius: 29).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))

            if dictation.isRecording {
                Text("オンデバイスで音声入力中。入力内容を編集すると終了します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            guard let contextID = photoPickerContextID else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw AttachmentLoader.Failure.invalidPhoto }
                    let loaded = try await Task.detached(priority: .userInitiated) { try AttachmentLoader.photo(data: data) }.value
                    guard model.composerContextID == contextID else { inputError = "会話が切り替わったため、写真の添付を中断しました。もう一度選んでください。"; return }
                    model.addAttachment(data: loaded.data, fileName: loaded.fileName, mimeType: loaded.mimeType)
                } catch { inputError = error.localizedDescription }
                photo = nil
                photoPickerContextID = nil
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let contextID = filePickerContextID else { return }
            Task {
                defer { filePickerContextID = nil }
                do {
                    let urls = try result.get()
                    for url in urls {
                        let loaded = try await Task.detached(priority: .userInitiated) { try AttachmentLoader.file(url: url) }.value
                        guard model.composerContextID == contextID else { inputError = "会話が切り替わったため、添付を中断しました。もう一度選んでください。"; return }
                        model.addAttachment(data: loaded.data, fileName: loaded.fileName, mimeType: loaded.mimeType)
                    }
                } catch {
                    if (error as NSError).code != NSUserCancelledError { inputError = error.localizedDescription }
                }
            }
        }
        .onChange(of: model.composerContextID) { _, _ in dictation.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { dictation.stop() } }
        .onDisappear { dictation.stop() }
        .alert("入力を確認してください", isPresented: Binding(get: { inputError != nil || dictation.errorMessage != nil }, set: { if !$0 { inputError = nil; dictation.errorMessage = nil } })) {
            Button("OK", role: .cancel) { inputError = nil; dictation.errorMessage = nil }
        } message: { Text(inputError ?? dictation.errorMessage ?? "") }
    }

    private var placeholder: String {
        if model.selectedSession?.isMain == true { return "メッセージ" }
        if let title = model.selectedSession?.title, !title.isEmpty, title != "新しいサイドチャット" { return "\(title)のメッセージ" }
        return "新しいサイドチャットのメッセージ"
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                            .foregroundStyle(ChatTheme.accent)
                        Text(attachment.fileName).font(.caption).lineLimit(1).frame(maxWidth: 140)
                        Button { model.removeAttachment(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 28, height: 32)
                        }
                        .accessibilityLabel("\(attachment.fileName)を取り除く")
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 5)
                    .padding(.vertical, 4)
                    .background(ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var modelPicker: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Gateway の既定") { Task { await model.setModel(nil) } }
                ForEach(model.models) { option in
                    Button { Task { await model.setModel(option.id) } } label: {
                        if option.id == model.selectedModelID { Label(option.name, systemImage: "checkmark") }
                        else { Text(option.name) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.models.first(where: { $0.id == model.selectedModelID })?.name ?? "既定のモデル").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .disabled(isRunning)
            if !model.thinkingLevels.isEmpty {
                Menu {
                    Button("既定の思考レベル") { Task { await model.setThinking(nil) } }
                    ForEach(model.thinkingLevels) { level in
                        Button { Task { await model.setThinking(level.id) } } label: {
                            if level.id == model.selectedThinkingLevel { Label(level.label, systemImage: "checkmark") }
                            else { Text(level.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                        Text(model.thinkingLevels.first(where: { $0.id == model.selectedThinkingLevel })?.label ?? "既定")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .disabled(isRunning)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private func toggleDictation() {
        if dictation.isRecording { dictation.stop(); return }
        let contextID = model.composerContextID
        let original = model.draftText
        dictationLastApplied = original
        fieldFocused = false
        Task {
            await dictation.start { text in
                guard model.composerContextID == contextID, model.draftText == dictationLastApplied else { dictation.stop(); return }
                let next = original + (original.isEmpty || original.hasSuffix(" ") || original.hasSuffix("\n") ? "" : " ") + text
                dictationLastApplied = next
                model.draftText = next
            }
        }
    }
}
