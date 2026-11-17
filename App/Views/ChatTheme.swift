import SwiftUI
import OhMyOpenClawCore

enum ChatTheme {
    static let accent = Color(red: 0.16, green: 0.40, blue: 0.87)
    static let canvas = Color(uiColor: .systemBackground)
    static let secondaryCanvas = Color(uiColor: .secondarySystemBackground)
    static let ink = Color.primary
}

struct QuietIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
        }
        .chatGlassButton()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
    }
}

struct ActivityPill: View {
    let activity: ActivityState
    let agentName: String

    private var description: String {
        switch activity {
        case .idle: ""
        case .working: "\(agentName) は動作中です"
        case .searching: "検索中"
        case .responding: "\(agentName) は応答中です"
        case .waitingForApproval: "確認を待っています"
        }
    }

    private var symbol: String {
        switch activity {
        case .idle, .working: "sparkle"
        case .searching: "magnifyingglass"
        case .responding: "text.bubble"
        case .waitingForApproval: "hand.raised"
        }
    }

    var body: some View {
        if activity != .idle {
            Label(description, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(ChatTheme.secondaryCanvas, in: Capsule())
                .accessibilityIdentifier("activityPill")
        }
    }
}
