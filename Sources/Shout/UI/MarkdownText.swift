import SwiftUI

/// Renders the Markdown the language model writes (headings, bullets, numbered lists, paragraphs,
/// inline bold/italic/links) with native typography. Block-level only; no tables or images.
struct MarkdownText: View {
    let markdown: String
    var baseSize: CGFloat = 13.5

    enum Block: Hashable {
        case heading(Int, String)
        case bullet(String, level: Int)
        case numbered(Int, String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { i, block in
                view(block).padding(.top, topSpacing(block, first: i == 0))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: level <= 1 ? baseSize + 5 : (level == 2 ? baseSize + 1.5 : baseSize), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: baseSize))
            .lineSpacing(3)
            .padding(.leading, CGFloat(level) * 16 + 2)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: baseSize))
            .lineSpacing(3)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: baseSize)).lineSpacing(3.5).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func topSpacing(_ b: Block, first: Bool) -> CGFloat {
        if first { return 0 }
        switch b {
        case .heading: return 18
        case .bullet, .numbered: return 6
        case .paragraph: return 10
        }
    }

    static func inline(_ s: String) -> AttributedString {
        guard let out = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(s) }
        // The model writes this text, steered by whatever was said in the meeting, so only web and mail links stay
        // clickable. Anything else (file:, other apps' URL schemes) is shown as plain text.
        return out.transformingAttributes(\.link) { link in
            if let url = link.value, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { link.value = nil }
        }
    }

    /// The number of an ordered-list line ("3. Text"): 1 to 9 ASCII digits, then ". ", as in CommonMark.
    static func listNumber(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let n = Int(digits) else { return nil }
        let rest = line[digits.endIndex...]
        guard rest.hasPrefix(". ") else { return nil }
        return (n, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }


    /// 1–6 `#`s and a space, as in CommonMark, so "#1 priority" or "#hashtag" stay prose. Models sometimes leave
    /// the space out after `##`, so two or more `#`s right before a letter count too.
    static func headingLevel(_ line: String) -> Int? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        guard let next = line.dropFirst(level).first else { return level }
        return next == " " || next == "\t" || (level >= 2 && next.isLetter) ? level : nil
    }

    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        // A numbered list with no blank line or heading since its last item: any number continues it.
        var listOpen = false
        for raw in md.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); listOpen = false; continue }
            if let level = Self.headingLevel(line) {
                flush()
                listOpen = false
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2)), level: min(2, indent / 2)))
            } else if case let (n, text)? = listNumber(line),
                      // As in CommonMark, only "1." can break into a paragraph, so a wrapped line that happens to
                      // start with "2024. " stays prose. Inside a list any number continues it.
                      paragraph.isEmpty || n == 1 || listOpen {
                flush()
                out.append(.numbered(n, text))
                listOpen = true
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }
}
