import SwiftUI
import AppKit

/// A clean, native Markdown renderer for AI assistant responses in RawView.
/// Handles fenced code blocks (with syntax language header & copy button),
/// headings (#, ##, ###), blockquotes (>), lists (-, *, 1.), dividers (---),
/// and inline markdown (bold, italic, inline code, links).
public struct AIMarkdownView: View {
    let content: String
    var isError: Bool = false

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public var body: some View {
        let blocks = parseMarkdownBlocks(content)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.kind {
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .heading(let level, let text):
                    HeadingView(level: level, text: text)
                case .blockquote(let text):
                    BlockquoteView(text: text)
                case .bulletItem(let bullet, let text):
                    BulletItemView(bullet: bullet, text: text)
                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                case .paragraph(let text):
                    ParagraphView(text: text, isError: isError)
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Block Parsing

    private enum BlockKind {
        case code(language: String, code: String)
        case heading(level: Int, text: String)
        case blockquote(text: String)
        case bulletItem(bullet: String, text: String)
        case divider
        case paragraph(text: String)
    }

    private struct MarkdownBlock: Identifiable {
        let id = UUID()
        let kind: BlockKind
    }

    private func parseMarkdownBlocks(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ```[language]
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .code(language: language, code: codeLines.joined(separator: "\n"))))
                continue
            }

            // Horizontal rule: --- or ***
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(MarkdownBlock(kind: .divider))
                index += 1
                continue
            }

            // Heading: #, ##, ###
            if trimmed.hasPrefix("### ") {
                blocks.append(MarkdownBlock(kind: .heading(level: 3, text: String(trimmed.dropFirst(4)))))
                index += 1
                continue
            } else if trimmed.hasPrefix("## ") {
                blocks.append(MarkdownBlock(kind: .heading(level: 2, text: String(trimmed.dropFirst(3)))))
                index += 1
                continue
            } else if trimmed.hasPrefix("# ") {
                blocks.append(MarkdownBlock(kind: .heading(level: 1, text: String(trimmed.dropFirst(2)))))
                index += 1
                continue
            }

            // Blockquote: >
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = [String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1))]
                index += 1
                while index < lines.count {
                    let nextTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("> ") || nextTrimmed == ">" {
                        quoteLines.append(String(nextTrimmed.dropFirst(nextTrimmed.hasPrefix("> ") ? 2 : 1)))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(kind: .blockquote(text: quoteLines.joined(separator: "\n"))))
                continue
            }

            // Bullet list: - or * or numbered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let bullet = "•"
                let itemText = String(trimmed.dropFirst(2))
                blocks.append(MarkdownBlock(kind: .bulletItem(bullet: bullet, text: itemText)))
                index += 1
                continue
            }

            // Numbered list: "1. ", "2. ", etc.
            if let dotIdx = trimmed.firstIndex(of: "."), dotIdx != trimmed.startIndex {
                let prefix = String(trimmed[..<dotIdx])
                if Int(prefix) != nil && trimmed[trimmed.index(after: dotIdx)...].hasPrefix(" ") {
                    let text = String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...])
                    blocks.append(MarkdownBlock(kind: .bulletItem(bullet: "\(prefix).", text: text)))
                    index += 1
                    continue
                }
            }

            // Empty line
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Regular paragraph: collect consecutive non-empty lines
            var paragraphLines: [String] = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix("#") || nextTrimmed.hasPrefix(">") || nextTrimmed.hasPrefix("- ") || nextTrimmed.hasPrefix("* ") || nextTrimmed == "---" {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }
            blocks.append(MarkdownBlock(kind: .paragraph(text: paragraphLines.joined(separator: "\n"))))
        }

        return blocks
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var isCopied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            Divider()

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Subviews

private struct HeadingView: View {
    let level: Int
    let text: String

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(headingFont)
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.top, level == 1 ? 4 : 2)
    }

    private var headingFont: Font {
        switch level {
        case 1: return .system(size: 15, weight: .bold)
        case 2: return .system(size: 14, weight: .bold)
        default: return .system(size: 13, weight: .semibold)
        }
    }
}

private struct BlockquoteView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)

            Text(LocalizedStringKey(text))
                .font(.system(size: 12.5, weight: .regular))
                .italic()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct BulletItemView: View {
    let bullet: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(bullet)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)

            Text(LocalizedStringKey(text))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
    }
}

private struct ParagraphView: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isError ? Color.red : Color(nsColor: .labelColor))
            .lineSpacing(3)
    }
}
