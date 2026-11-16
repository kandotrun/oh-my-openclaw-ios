import SwiftUI
import UIKit

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

private enum MarkdownBlock {
    case paragraph(String), heading(Int, String), bullet(String, String), quote(String), code(String, String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language = ""
        var fence: String?
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let activeFence = fence {
                if trimmed.hasPrefix(activeFence) { blocks.append(.code(language, code.joined(separator: "\n"))); code = []; fence = nil }
                else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                fence = String(trimmed.prefix(3))
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }), trimmed.distance(from: trimmed.startIndex, to: space) <= 6 {
                flushParagraph()
                blocks.append(.heading(trimmed.distance(from: trimmed.startIndex, to: space), String(trimmed[trimmed.index(after: space)...])))
            } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                blocks.append(.bullet("•", String(trimmed.dropFirst(2))))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                blocks.append(.bullet(marker, String(trimmed[range.upperBound...])))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else { paragraph.append(line) }
        }
        flushParagraph()
        if fence != nil { blocks.append(.code(language, code.joined(separator: "\n"))) }
        return blocks
    }
}
