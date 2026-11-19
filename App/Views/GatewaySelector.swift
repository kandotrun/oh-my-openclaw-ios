import SwiftUI

/// The selection is derived from AppModel's published endpoint, never local optimistic state.
struct GatewaySelector: View {
    @Bindable var model: AppModel
    var addGateway: () -> Void
    var didSelect: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(model.savedGateways) { profile in
                Button {
                    didSelect()
                    Task { await model.switchGateway(profile) }
                } label: {
                    if model.activeGateway?.id == profile.id {
                        Label(profile.label, systemImage: "checkmark")
                    } else { Text(profile.label) }
                    Text(profile.endpoint)
                }
            }
            if !model.savedGateways.isEmpty { Divider() }
            Button("Gateway を追加", systemImage: "plus", action: addGateway)
        } label: {
            HStack(spacing: 5) {
                Text(model.isDemo ? "デモ" : model.activeGateway?.label ?? "Gateway")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.medium))
        }
        .chatGlassButton()
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(model.changingConnection || model.connectionState == .connecting)
        .accessibilityLabel("Gateway を選択")
        .accessibilityValue(model.isDemo ? "デモ" : model.activeGateway?.label ?? "未接続")
        .accessibilityIdentifier("gatewaySelector")
    }
}

struct GatewayProfileSettings: View {
    @Bindable var model: AppModel
    let endpoint: String
    @State private var alias: String
    @State private var confirmingDeletion = false
    @State private var deleting = false
    @State private var deletionError: String?
    @Environment(\.dismiss) private var dismiss

    private var profile: SavedGateway? { model.savedGateways.first { $0.endpoint == endpoint } }

    init(model: AppModel, profile: SavedGateway) {
        self.model = model
        endpoint = profile.endpoint
        _alias = State(initialValue: profile.alias ?? "")
    }

    var body: some View {
        Form {
            Section("表示名") {
                TextField("ホスト名を使う", text: $alias)
                    .accessibilityIdentifier("gatewayAlias")
                Text("この端末で表示する名前です。空欄にするとホスト名を使います。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Gateway URL") {
                Text(endpoint).font(.footnote).textSelection(.enabled)
            }
            Section {
                Button("Gateway を削除", role: .destructive) { confirmingDeletion = true }
                    .disabled(profile == nil || model.changingConnection || model.connectionState == .connecting || deleting)
                    .accessibilityIdentifier("deleteGateway")
            } footer: {
                if let deletionError { Text(deletionError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Gateway を編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    guard let profile else { return }
                    model.renameGateway(profile, alias: alias)
                    dismiss()
                }
                .disabled(profile == nil || deleting)
            }
        }
        .alert("Gateway を削除しますか？", isPresented: $confirmingDeletion, presenting: profile) { profile in
            Button("削除", role: .destructive) {
                deletionError = nil
                deleting = true
                Task {
                    let removed = await model.deleteGateway(profile)
                    deleting = false
                    if removed { dismiss() }
                    else { deletionError = model.notice ?? "Gateway を削除できませんでした。もう一度お試しください。" }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { profile in
            Text("「\(profile.label)」の接続先と認証情報をこの端末から削除します。")
        }
    }
}
