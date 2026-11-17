import SwiftUI
import UIKit
import ImageIO
import QuickLook
import UniformTypeIdentifiers
import OhMyOpenClawCore

struct ChatScreen: View {
    @Bindable var model: AppModel
    let sidebarVisible: Bool
    let openMenu: () -> Void
    let openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsBottom = true
    @State private var userScrolling = false
    @State private var nearBottom = true
    @State private var loadingOlder = false

    var body: some View {
        VStack(spacing: 0) {
            if model.activity != .idle || model.isDemo { statusHeader }
            connectionNotice
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if model.hasMoreHistory {
                                Button {
                                    let anchor = model.messages.first?.id
                                    let contextID = model.composerContextID
                                    followsBottom = false
                                    loadingOlder = true
                                    Task { @MainActor in
                                        await model.loadOlderHistory()
                                        loadingOlder = false
                                        guard model.composerContextID == contextID, let anchor else { return }
                                        await Task.yield()
                                        proxy.scrollTo(anchor, anchor: .top)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        if loadingOlder { ProgressView().controlSize(.small) }
                                        Text("以前のメッセージを読み込む")
                                    }
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .disabled(loadingOlder)
                            }
                            if model.messages.isEmpty { emptyConversation }
                            ForEach(model.messages) { message in
                                let target = model.selectedSession
                                MessageRow(message: message, contextID: model.composerContextID, loadAttachment: { attachment in
                                    guard let target else { throw GatewayFailure(code: "SESSION_CHANGED", message: "会話を開き直してください。") }
                                    return try await model.loadAttachment(attachment, session: target)
                                }, retry: { Task { await model.retryPending(message.id) } })
                                    .id(message.id)
                            }
                            ForEach(model.prompts) { prompt in
                                ApprovalCard(prompt: prompt, resolve: { answer in Task { await model.resolvePrompt(prompt, answer: answer) } })
                            }
                            if model.activity == .working || model.activity == .searching {
                                if model.messages.last?.role != .assistant || model.messages.last?.text.isEmpty == true {
                                    TypingIndicator().padding(.leading, 1)
                                }
                            }
                            Color.clear.frame(height: 1).id("conversationBottom")
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .defaultScrollAnchor(followsBottom ? .bottom : nil, for: .sizeChanges)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 90
                    } action: { _, value in
                        nearBottom = value
                        if userScrolling { followsBottom = value }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .idle && userScrolling { followsBottom = nearBottom }
                        userScrolling = phase == .interacting || phase == .decelerating
                    }
                    .task(id: model.selectedSessionKey) {
                        followsBottom = true
                        await Task.yield()
                        proxy.scrollTo("conversationBottom", anchor: .bottom)
                    }
                    .onChange(of: model.messages.last?.text) { _, _ in scrollIfFollowing(proxy) }
                    .onChange(of: model.messages.count) { _, _ in scrollIfFollowing(proxy) }
                    .onChange(of: model.prompts.count) { _, _ in scrollIfFollowing(proxy) }

                    if !followsBottom {
                        Button {
                            followsBottom = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("conversationBottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .chatGlassButton()
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.bottom, 8)
                        .accessibilityLabel("最新のメッセージへ")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(model: model)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background(ChatTheme.canvas)
        .navigationTitle(model.agentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(sidebarVisible ? "会話一覧を隠す" : "会話を開く", systemImage: sidebarVisible ? "sidebar.left" : "line.3.horizontal", action: openMenu)
                    .accessibilityIdentifier("menuButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("設定を開く", systemImage: "ellipsis", action: openSettings)
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 6) {
            ActivityPill(activity: model.activity, agentName: model.agentName)
            if model.isDemo {
                Text("デモ")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ChatTheme.secondaryCanvas, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var connectionNotice: some View {
        if let notice = model.notice, !notice.isEmpty {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(ChatTheme.secondaryCanvas)
        }
        if model.connectionState != .connected {
            Button { Task { await model.retryConnection() } } label: {
                HStack(spacing: 8) {
                    if model.connectionState == .connecting { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(model.connectionState == .connecting ? "再接続しています" : "接続を再開する")
                }
                .font(.footnote)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .chatGlassButton()
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .disabled(model.connectionState == .connecting)
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedSession?.isMain == true ? "会話の続きを、ここから。" : "新しいサイドチャット")
                .font(.title3.weight(.medium))
            Text(model.selectedSession?.isMain == true ? "メッセージを送って会話を始めましょう。" : "メインチャットとは別の会話です。気になったことを、気軽にどうぞ。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 72)
        .padding(.bottom, 42)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard followsBottom else { return }
        Task { @MainActor in
            await Task.yield()
            guard followsBottom else { return }
            proxy.scrollTo("conversationBottom", anchor: .bottom)
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let contextID: String
    let loadAttachment: @MainActor (ChatAttachment) async throws -> Data
    let retry: () -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 34) }
                VStack(alignment: .leading, spacing: 12) {
                    if !message.text.isEmpty {
                        if isUser { Text(message.text).font(.body).lineSpacing(4).textSelection(.enabled) }
                        else { MarkdownMessageView(text: message.text) }
                    }
                    ForEach(message.attachments) { attachment in
                        AttachmentPreview(attachment: attachment, load: { try await loadAttachment(attachment) })
                            .id(contextID + "|" + attachment.id)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
                .foregroundStyle(.primary)
                .background(isUser ? ChatTheme.accent.opacity(0.09) : ChatTheme.secondaryCanvas, in: RoundedRectangle(cornerRadius: 22))
                .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                .contextMenu {
                    if !message.text.isEmpty { Button("コピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
                }
                if !isUser { Spacer(minLength: 6) }
            }
            if isUser {
                switch message.delivery {
                case .pending: Label("送信中", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                case .uncertain:
                    Button(action: retry) { Label("送信を確認して再試行", systemImage: "arrow.clockwise") }
                        .font(.caption)
                        .frame(minHeight: 36)
                case .failed:
                    Button(action: retry) { Label("再試行", systemImage: "exclamationmark.circle") }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(minHeight: 36)
                default: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }
}

struct AttachmentPreview: View {
    let attachment: ChatAttachment
    let load: @MainActor () async throws -> Data
    @State private var loadedData: Data?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    @State private var temporaryDirectory: URL?
    @State private var loadingTask: Task<Void, Never>?

    private var availableData: Data { loadedData ?? attachment.data }
    private var isImage: Bool { attachment.mimeType.hasPrefix("image/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isImage, let image = thumbnail(availableData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(attachment.fileName)
            }
            Button(action: open) {
                HStack(spacing: 10) {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: isImage ? "photo" : "doc").font(.title3).foregroundStyle(ChatTheme.accent) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.fileName).font(.subheadline).lineLimit(2)
                        let size = availableData.isEmpty ? attachment.sizeBytes ?? 0 : availableData.count
                        if size > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        Text(loading ? "読み込み中…" : isImage ? "画像を開く" : "ファイルを開く")
                            .font(.caption)
                            .foregroundStyle(ChatTheme.accent)
                    }
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
                .padding(11)
                .background(ChatTheme.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityLabel("\(attachment.fileName)を開く")
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, url in if url == nil { removeTemporaryFile() } }
        .onDisappear {
            loadingTask?.cancel(); loadingTask = nil
            previewURL = nil; loadedData = nil; loading = false
            removeTemporaryFile()
        }
    }

    private func open() {
        guard !loading else { return }
        loading = true; errorMessage = nil
        loadingTask = Task { @MainActor in
            defer { if !Task.isCancelled { loading = false } }
            do {
                let data = try await load()
                try Task.checkCancellation()
                removeTemporaryFile()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenClaw-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                temporaryDirectory = directory
                let rawName = String(attachment.fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "attachment")
                var name = rawName.isEmpty || rawName == "." || rawName == ".." ? "attachment" : String(rawName.prefix(128)).replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\0", with: "_")
                if URL(fileURLWithPath: name).pathExtension.isEmpty, let suffix = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension { name += "." + suffix }
                let file = directory.appendingPathComponent(name)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                loadedData = data
                previewURL = file
            } catch is CancellationError { removeTemporaryFile() }
            catch {
                guard !Task.isCancelled else { removeTemporaryFile(); return }
                errorMessage = error.localizedDescription
                removeTemporaryFile()
            }
        }
    }

    private func removeTemporaryFile() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }

    private func thumbnail(_ data: Data) -> UIImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 0.5 : (animate ? 0.7 : 0.25))
                    .offset(y: reduceMotion ? 0 : (animate ? -2 : 1))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.14), value: animate)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 17)
        .background(ChatTheme.secondaryCanvas, in: Capsule())
        .accessibilityLabel("返信を待っています")
        .onAppear { animate = true }
    }
}

private struct ApprovalCard: View {
    let prompt: ApprovalPrompt
    let resolve: (String) -> Void
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(prompt.title, systemImage: "hand.raised")
                .font(.headline)
            Text(prompt.detail).font(.subheadline).textSelection(.enabled)
            if prompt.choices.isEmpty {
                if prompt.kind == "secret" {
                    SecureField("回答を入力", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("回答を入力", text: $answer, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
                Button("回答する") { let value = answer; answer = ""; resolve(value) }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { ForEach(prompt.choices, id: \.self) { choice in Button(choiceLabel(choice)) { resolve(choice) }.buttonStyle(.bordered) } }
                    VStack(alignment: .leading) { ForEach(prompt.choices, id: \.self) { choice in Button(choiceLabel(choice)) { resolve(choice) }.buttonStyle(.bordered) } }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ChatTheme.accent.opacity(0.18), lineWidth: 1))
    }

    private func choiceLabel(_ value: String) -> String {
        guard prompt.kind == "exec" || prompt.kind == "plugin" else { return value }
        switch value {
        case "allow-once": return "今回のみ許可"
        case "allow-always": return "常に許可"
        case "deny": return "拒否"
        default: return value
        }
    }
}
