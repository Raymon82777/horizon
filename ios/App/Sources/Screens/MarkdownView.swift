import SwiftUI

/// A project's full description (Markdown, often with HTML in it, as Modrinth and the registry
/// carry them) as blocks: headings, paragraphs, lists, quotes, code and pictures. Inline
/// formatting and links within a block are SwiftUI's own Markdown.
struct MarkdownView: View {
    let blocks: [Block]

    init(_ source: String) {
        blocks = Self.parse(source)
    }

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, ordered: String?, depth: Int)
        case quote(String)
        case code(String)
        case image(URL)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Self.inline(text)
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case let .paragraph(text):
            Self.inline(text).font(.callout)
        case let .bullet(text, ordered, depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordered.map { "\($0)." } ?? "•").font(.callout).foregroundStyle(.secondary)
                Self.inline(text).font(.callout)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case let .quote(text):
            Self.inline(text).font(.callout.italic()).foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.caption.monospaced()).padding(8)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case let .image(url):
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.secondary.opacity(0.12).frame(height: 120)
            }
            .frame(maxWidth: .infinity, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private static func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
    }

    // MARK: Parsing

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        for raw in htmlAsLines(source.replacingOccurrences(of: "\r\n", with: "\n")).components(separatedBy: "\n") {
            if code != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(raw)
                }
                continue
            }
            // Pictures stand alone, whether written as Markdown or as HTML.
            let images = imageURLs(in: raw)
            var line = stripHTML(removeImages(raw))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if !images.isEmpty {
                flush()
                blocks += images.map(Block.image)
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.allSatisfy({ "-*_ ".contains($0) }), trimmed.filter({ $0 != " " }).count >= 3 {
                flush()
                blocks.append(.rule)
                continue
            }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
               trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !quote.isEmpty { blocks.append(.quote(quote)) }
                continue
            }
            let depth = line.prefix { $0 == " " || $0 == "\t" }.count / 2
            if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2)), ordered: nil, depth: depth))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
               trimmed[trimmed.index(after: dot)...].first == " " {
                flush()
                blocks.append(.bullet(String(trimmed[trimmed.index(dot, offsetBy: 2)...]),
                                      ordered: String(trimmed[..<dot]), depth: depth))
                continue
            }
            line = trimmed
            paragraph.append(line)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// HTML written across lines as one line per tag, and HTML's headings and list items as
    /// Markdown's, so the line-by-line reading below sees them.
    private static func htmlAsLines(_ source: String) -> String {
        source
            .replacing(#/<[a-zA-Z][^>]*>/#) { $0.output.replacingOccurrences(of: "\n", with: " ") }
            .replacing(#/<h([1-6])[^>]*>/#.ignoresCase()) { "\n" + String(repeating: "#", count: Int($0.output.1) ?? 1) + " " }
            .replacing(#/<\/h[1-6]>/#.ignoresCase(), with: "\n")
            .replacing(#/<li[^>]*>/#.ignoresCase(), with: "\n- ")
            .replacing(#/<\/(p|li|div|ul|ol)>/#.ignoresCase(), with: "\n")
    }

    private static let markdownImage = #/!\[[^\]]*\]\(([^)\s]+)[^)]*\)/#
    private static let htmlImage = #/<img[^>]*?src=["']([^"']+)["'][^>]*>/#.ignoresCase()

    private static func imageURLs(in line: String) -> [URL] {
        let found = line.matches(of: markdownImage).map { String($0.1) }
            + line.matches(of: htmlImage).map { String($0.1) }
        return found.compactMap { URL(string: $0) }.filter { $0.scheme == "https" }
    }

    /// Without its pictures; a picture that's a link ([![alt](img)](url)) leaves nothing behind.
    private static func removeImages(_ line: String) -> String {
        line.replacing(#/\[!\[[^\]]*\]\([^)]*\)\]\([^)]*\)/#, with: "")
            .replacing(markdownImage, with: "")
            .replacing(htmlImage, with: "")
    }

    /// HTML's tags gone and its usual entities decoded: descriptions mix both in.
    private static func stripHTML(_ line: String) -> String {
        line.replacing(#/<br\s*\/?>/#.ignoresCase(), with: " ")
            .replacing(#/<\/?[a-zA-Z][^>]*>/#, with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
