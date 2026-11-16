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
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct AgentAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(ChatTheme.accent)
            .frame(width: size, height: size)
            .background(ChatTheme.accent.opacity(0.09), in: Circle())
            .accessibilityHidden(true)
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
