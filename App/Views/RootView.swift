import SwiftUI
import OhMyOpenClawCore

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = false
    @State private var showSettings = false
    @State private var showConnection = false
    @State private var search = ""
    @State private var renaming: ChatSession?
    @State private var renameText = ""

    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88) }

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(330.0, geometry.size.width * 0.84)
            ZStack(alignment: .leading) {
                ChatTheme.secondaryCanvas.ignoresSafeArea()
                if !model.sessions.isEmpty && drawerOpen {
                    drawer(width: drawerWidth)
                        .opacity(drawerOpen ? 1 : 0)
                        .accessibilityHidden(!drawerOpen)
                }
                Group {
                    if model.sessions.isEmpty { OnboardingView(model: model) }
                    else {
                        ChatScreen(model: model, openMenu: { setDrawer(true) }, openSettings: { showSettings = true })
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(ChatTheme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: drawerOpen && !reduceMotion ? 26 : 0))
                .overlay {
                    if drawerOpen {
                        Color.black.opacity(0.08)
                            .contentShape(Rectangle())
                            .onTapGesture { setDrawer(false) }
                            .accessibilityLabel("サイドバーを閉じる")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .offset(x: drawerOpen ? drawerWidth : 0)
                .simultaneousGesture(DragGesture(minimumDistance: 22).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                    if drawerOpen && value.translation.width < -65 { setDrawer(false) }
                    else if !drawerOpen && value.startLocation.x < 30 && value.translation.width > 65 && !model.sessions.isEmpty { setDrawer(true) }
                })
            }
            .clipped()
        }
        .tint(ChatTheme.accent)
        .sheet(isPresented: $showSettings) {
            settings
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                OnboardingView(model: model)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showConnection = false } } }
            }
        }
        .onChange(of: model.connectionState) { _, state in if state == .connected { showConnection = false } }
        .alert("会話の名前", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $renameText)
            Button("保存") {
                guard let session = renaming else { return }
                let title = renameText
                renaming = nil
                Task { await model.renameSession(session, title: title) }
            }
            Button("キャンセル", role: .cancel) { renaming = nil }
        }
        .alert("確認してください", isPresented: Binding(get: { model.errorMessage != nil && !model.sessions.isEmpty && !showConnection }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func setDrawer(_ open: Bool) { withAnimation(animation) { drawerOpen = open } }

    private func drawer(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                AgentAvatar(size: 42)
                Text(model.agentName).font(.title.weight(.semibold))
                if model.isDemo { Text("デモ").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            }
            .padding(.top, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredSessions.filter(\.isMain)) { session in sessionRow(session) }
                    if !filteredSessions.filter({ !$0.isMain }).isEmpty {
                        Text("サイドチャット")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                    }
                    ForEach(filteredSessions.filter { !$0.isMain }) { session in sessionRow(session) }
                    if filteredSessions.isEmpty { Text("一致する会話がありません").font(.footnote).foregroundStyle(.secondary).padding(.vertical) }
                }
            }

            HStack(spacing: 12) {
                Button { setDrawer(false); showSettings = true } label: {
                    Image(systemName: "gearshape").font(.title3).frame(width: 40, height: 44)
                }
                .accessibilityLabel("設定")
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("検索", text: $search).font(.subheadline)
                }
                .padding(.horizontal, 11)
                .frame(minHeight: 42)
                .background(ChatTheme.canvas.opacity(0.65), in: Capsule())
                Button {
                    setDrawer(false)
                    Task { await model.newSideChat() }
                } label: { Image(systemName: "square.and.pencil").font(.title3).frame(width: 40, height: 44) }
                .accessibilityLabel("新しいサイドチャット")
                .accessibilityIdentifier("newChatButton")
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .frame(width: width, alignment: .leading)
    }

    private var filteredSessions: [ChatSession] {
        model.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        Button {
            setDrawer(false)
            Task { await model.selectSession(session) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: session.isMain ? "bubble.left.and.bubble.right" : "bubble.left")
                    .font(.body)
                    .frame(width: 23)
                    .foregroundStyle(session.key == model.selectedSessionKey ? ChatTheme.accent : .secondary)
                Text(session.isMain ? "メインチャット" : session.title)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.key == model.selectedSessionKey ? ChatTheme.canvas : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !session.isMain {
                Button("名前を変更", systemImage: "pencil") { renameText = session.title; renaming = session }
            }
        }
        .accessibilityIdentifier(session.isMain ? "mainChatRow" : "sideChatRow")
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) { AgentAvatar(size: 42); VStack(alignment: .leading, spacing: 3) { Text(model.agentName).font(.headline); Text(model.isDemo ? "サンプルの会話を表示中" : "あなたの Gateway に接続").font(.footnote).foregroundStyle(.secondary) } }
                }
                Section("接続") {
                    Label(connectionLabel, systemImage: model.connectionState == .connected ? "checkmark.circle" : "network")
                    Button("接続を変更") { showSettings = false; showConnection = true }
                    Button("接続を切る", role: .destructive) { showSettings = false; Task { await model.disconnect() } }
                }
                Section("このアプリ") {
                    LabeledContent("バージョン", value: "0.1")
                    Text("チャットに集中するための、独立した OpenClaw クライアントです。プッシュ通知には対応していません。アプリを開くと会話を再同期します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showSettings = false } } }
        }
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .connected: model.isDemo ? "デモモード" : "接続済み"
        case .connecting: "再接続中"
        case .pairing: "端末の承認待ち"
        case .failed: "接続を確認してください"
        case .disconnected: "未接続"
        }
    }
}
