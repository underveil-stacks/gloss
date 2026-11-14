import Foundation
import GlossCore
import JavaScriptCore

/// Syntax highlighting at render time, by running highlight.js natively.
/// Nothing is highlighted in the page, so it works with page scripts off.
final class Highlighter: @unchecked Sendable {
    static let shared = Highlighter()

    private let lock = NSLock()
    private let highlight: JSValue?

    private init() {
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
            let source = try? String(contentsOf: url, encoding: .utf8),
            let context = JSContext()
        else {
            highlight = nil
            return
        }
        context.evaluateScript(source)
        // Returns null for a language highlight.js does not know, so the block
        // is left as plain text instead of being guessed at.
        highlight = context.evaluateScript(
            """
            (function (code, language) {
              if (!hljs.getLanguage(language)) return null;
              return hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
            })
            """)
    }

    var isAvailable: Bool { highlight != nil }

    func highlight(_ code: String, language: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let result = highlight?.call(withArguments: [code, language]), result.isString else { return nil }
        return result.toString()
    }

    var codeHighlighter: CodeHighlighter {
        { code, language in Highlighter.shared.highlight(code, language: language) }
    }
}
