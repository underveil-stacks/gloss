import Foundation

public enum FrontMatter {
    struct Split {
        let frontMatter: String?
        /// The source with any front matter replaced by the same number of
        /// blank lines, so line numbers still match the original file.
        let body: String
    }

    /// Front matter is a `---` line at the very top of the file, closed by a
    /// later `---` or `...` line. Anything else is ordinary Markdown.
    static func split(_ source: String) -> Split {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, isFence(first, closing: false) else {
            return Split(frontMatter: nil, body: source)
        }
        guard let close = lines.dropFirst().firstIndex(where: { isFence($0, closing: true) }) else {
            return Split(frontMatter: nil, body: source)
        }
        let yaml = lines[1..<close].joined(separator: "\n")
        let blanks = Array(repeating: Substring(""), count: close + 1)
        let body = (blanks + lines[(close + 1)...]).joined(separator: "\n")
        return Split(frontMatter: yaml, body: body)
    }

    private static func isFence(_ line: Substring, closing: Bool) -> Bool {
        let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
        return trimmed == "---" || (closing && trimmed == "...")
    }

    public struct Entry: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    /// The top-level keys of a front-matter block, for display. This is not a
    /// YAML parser: a scalar is shown as written, a list is joined with
    /// commas, and anything nested is shown as its text. It never fails; a
    /// block it cannot read as `key: value` lines yields no entries, and the
    /// caller shows the raw text instead.
    public static func entries(in yaml: String) -> [Entry] {
        var entries: [Entry] = []
        var key: String?
        var parts: [String] = []

        func flush() {
            if let key { entries.append(Entry(key: key, value: parts.joined(separator: ", "))) }
            key = nil
            parts = []
        }

        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indented = line.first == " " || line.first == "\t"
            if !indented, !trimmed.hasPrefix("- "), let colon = trimmed.firstIndex(of: ":") {
                let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let after = trimmed.index(after: colon)
                guard !name.isEmpty, after == trimmed.endIndex || trimmed[after] == " " else { return [] }
                flush()
                key = name
                let value = scalar(String(trimmed[after...]))
                if !value.isEmpty { parts.append(value) }
            } else if key != nil {
                parts.append(scalar(trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed))
            } else {
                return []
            }
        }
        flush()
        return entries
    }

    private static func scalar(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("["), value.hasSuffix("]") {
            return value.dropFirst().dropLast().split(separator: ",")
                .map { scalar(String($0)) }.joined(separator: ", ")
        }
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
