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
            ChatGlassGroup {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("写真を選ぶ", systemImage: "photo") { photo = nil; photoPickerContextID = model.composerContextID; showPhotoPicker = true }
                        Button("ファイルを選ぶ", systemImage: "doc") { filePickerContextID = model.composerContextID; showFilePicker = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.primary)
                    }
                    .chatGlassButton()
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("添付する")

                    TextField(placeholder, text: $model.draftText, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...7)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .focused($fieldFocused)
                        .chatGlassSurface(cornerRadius: 26)
                        .accessibilityIdentifier("composerField")
                        .onChange(of: model.draftText) { _, value in
                            if dictation.isRecording && value != dictationLastApplied { dictation.stop() }
                        }

                    if model.draftText.isEmpty || dictation.isRecording {
                        Button { toggleDictation() } label: {
                            Image(systemName: dictation.isRecording ? "waveform" : "mic")
                                .font(.system(size: 20))
                                .foregroundStyle(dictation.isRecording ? .red : .secondary)
                        }
                        .chatGlassButton()
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(dictation.isRecording ? "音声入力を終える" : "音声入力")
                    }

                    if isRunning {
                        Button {
                            dictation.stop()
                            Task { await model.stop() }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                        .chatGlassButton()
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("応答を停止")
                        .accessibilityIdentifier("stopButton")
                    } else {
                        Button {
                            dictation.stop()
                            Task { await model.send() }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .chatGlassButton(prominent: true)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!model.canSend)
                        .accessibilityLabel("送信")
                        .accessibilityIdentifier("sendButton")
                    }
                }
            }

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
                defer {
                    if photo == item, photoPickerContextID == contextID {
                        photo = nil
                        photoPickerContextID = nil
                    }
                }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw AttachmentLoader.Failure.invalidPhoto }
                    let loaded = try await Task.detached(priority: .userInitiated) { try AttachmentLoader.photo(data: data) }.value
                    guard model.composerContextID == contextID else { inputError = "会話が切り替わったため、写真の添付を中断しました。もう一度選んでください。"; return }
                    model.addAttachment(data: loaded.data, fileName: loaded.fileName, mimeType: loaded.mimeType)
                } catch { inputError = error.localizedDescription }
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
            HStack(alignment: .center, spacing: 8) {
                ForEach(model.attachments) { attachment in
                    if attachment.mimeType.hasPrefix("image/") {
                        AttachmentThumbnail(data: attachment.data, fileName: attachment.fileName, presentation: .draft)
                            .overlay(alignment: .topTrailing) {
                                removeImageButton(attachment)
                            }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "doc").foregroundStyle(ChatTheme.accent)
                            Text(attachment.fileName).font(.caption).lineLimit(1).frame(maxWidth: 140)
                            removeAttachmentButton(attachment)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 2)
                        .padding(.vertical, 4)
                        .background(ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func removeImageButton(_ attachment: ChatAttachment) -> some View {
        Button { model.removeAttachment(attachment.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .chatGlassSurface(cornerRadius: 11)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(attachment.fileName)を取り除く")
    }

    private func removeAttachmentButton(_ attachment: ChatAttachment) -> some View {
        Button { model.removeAttachment(attachment.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .chatGlassButton()
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("\(attachment.fileName)を取り除く")
    }

    private var modelPicker: some View {
        ChatGlassGroup {
            HStack(spacing: 8) {
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
                .chatGlassButton()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
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
                    .chatGlassButton()
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(isRunning)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
