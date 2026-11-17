import SwiftUI
import UIKit
import OhMyOpenClawCore

/// Block layout stays native while Foundation handles inline Markdown and links.
/// Code is always literal and never evaluated or loaded into a web view.
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): inline(text)
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 3)
                case .bullet(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(marker).foregroundStyle(.secondary)
                        inline(text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .quote(let text):
                    HStack(alignment: .top, spacing: 11) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.3)).frame(width: 3)
                        inline(text).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let source): CodeBlockView(language: language, source: source)
                }
            }
        }
        .font(.body)
        .lineSpacing(4)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }

    private func inline(_ string: String) -> Text {
        let value = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return value.map(Text.init) ?? Text(string)
    }
}

private struct CodeBlockView: View {
    let language: String
    let source: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "コード" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                } label: {
                    Label(copied ? "コピー済み" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("コードをコピー")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().opacity(0.5)
            ScrollView(.horizontal) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(3)
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(ChatTheme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}
