import SwiftUI
import OhMyOpenClawCore

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = false
    @State private var sidebarCollapsed = false
    @State private var showSettings = false
    @State private var showConnection = false
    @State private var search = ""
    @State private var renaming: ChatSession?
    @State private var renameText = ""

    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88) }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = ChatLayout(width: geometry.size.width, sidebarAvailable: !model.sessions.isEmpty, drawerOpen: drawerOpen, sidebarCollapsed: sidebarCollapsed)
                ZStack(alignment: .leading) {
                    ChatTheme.canvas.ignoresSafeArea()
                    if layout.sidebarVisible {
                        drawer(width: layout.sidebarWidth)
                    }
                    Group {
                        if model.sessions.isEmpty { OnboardingView(model: model) }
                        else {
                            ChatScreen(model: model, sidebarVisible: layout.sidebarVisible, openMenu: {
                                if layout.isWide { withAnimation(animation) { sidebarCollapsed.toggle() } }
                                else { setDrawer(!drawerOpen) }
                            }, openSettings: { showSettings = true })
                        }
                    }
                    .frame(width: layout.chatWidth, height: geometry.size.height)
                    .background(ChatTheme.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: layout.overlaysChat && !reduceMotion ? 26 : 0))
                    .overlay {
                        if layout.overlaysChat {
                            Color.black.opacity(0.08)
                                .contentShape(Rectangle())
                                .onTapGesture { setDrawer(false) }
                                .accessibilityLabel("サイドバーを閉じる")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .offset(x: layout.chatOffset)
                    .simultaneousGesture(DragGesture(minimumDistance: 22).onEnded { value in
                        guard !layout.isWide else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                        if drawerOpen && value.translation.width < -65 { setDrawer(false) }
                        else if !drawerOpen && value.startLocation.x < 30 && value.translation.width > 65 && !model.sessions.isEmpty { setDrawer(true) }
                    })
                }
                .clipped()
                .onChange(of: layout.isWide) { _, _ in drawerOpen = false }
            }
            .toolbar(model.sessions.isEmpty ? .hidden : .visible, for: .navigationBar)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.agentName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                GatewaySelector(model: model, addGateway: {
                    setDrawer(false); showConnection = true
                }, didSelect: { setDrawer(false) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredSessions.filter(\.isMain)) { session in sessionRow(session) }
                    HStack {
                        Text("サイドチャット")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button {
                            setDrawer(false)
                            Task { await model.newSideChat() }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 20, height: 20)
                        }
                        .chatGlassButton()
                        .buttonBorderShape(.circle)
                        .controlSize(.regular)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("新しいサイドチャット")
                        .accessibilityIdentifier("newChatButton")
                    }
                    .padding(.leading, 12)
                    .padding(.top, 18)
                    ForEach(filteredSessions.filter { !$0.isMain }) { session in sessionRow(session) }
                    if filteredSessions.isEmpty || (!search.isEmpty && !filteredSessions.contains(where: { !$0.isMain })) {
                        Text(filteredSessions.isEmpty ? "一致する会話がありません" : "一致するサイドチャットがありません")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            ChatGlassGroup {
                HStack(spacing: 10) {
                    Button { setDrawer(false); showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 20, height: 20)
                    }
                    .chatGlassButton()
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("設定")
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("検索", text: $search)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .chatGlassSurface(cornerRadius: 22)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
        .frame(width: width, alignment: .leading)
    }

    private var filteredSessions: [ChatSession] {
        model.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        let isSelected = session.id == model.selectedSession?.id
        return Button {
            setDrawer(false)
            Task { await model.selectSession(session) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: session.isMain ? "bubble.left.and.bubble.right" : "bubble.left")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Text(session.isMain ? "メインチャット" : session.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? ChatTheme.secondaryCanvas : Color.clear, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !session.isMain {
                Button("名前を変更", systemImage: "pencil") { renameText = session.title; renaming = session }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(session.isMain ? "mainChatRow" : "sideChatRow")
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.agentName).font(.headline)
                        Text(model.isDemo ? "サンプルの会話を表示中" : "あなたの Gateway に接続")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("接続") {
                    Label(connectionLabel, systemImage: model.connectionState == .connected ? "checkmark.circle" : "network")
                    if let gateway = model.activeGateway {
                        LabeledContent("Gateway", value: gateway.label)
                    }
                    Button("再接続") { Task { await model.retryConnection() } }
                        .disabled(model.changingConnection || model.connectionState == .connecting)
                    Button("接続を切る", role: .destructive) { showSettings = false; Task { await model.disconnect() } }
                        .disabled(model.changingConnection)
                }
                Section("保存済みの Gateway") {
                    ForEach(model.savedGateways) { profile in
                        HStack(spacing: 12) {
                            Button {
                                showSettings = false
                                Task { await model.switchGateway(profile) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(profile.label).foregroundStyle(.primary)
                                        if model.activeGateway?.id == profile.id { Image(systemName: "checkmark").font(.caption) }
                                    }
                                    Text(profile.endpoint).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.changingConnection || model.connectionState == .connecting)
                            NavigationLink {
                                GatewayProfileSettings(model: model, profile: profile)
                            } label: {
                                Image(systemName: "pencil").accessibilityLabel("\(profile.label) の名前を変更")
                            }
                            .fixedSize()
                        }
                    }
                    Button("Gateway を追加", systemImage: "plus") { showSettings = false; showConnection = true }
                        .disabled(model.changingConnection || model.connectionState == .connecting)
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
