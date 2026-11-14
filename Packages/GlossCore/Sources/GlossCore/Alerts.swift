import Foundation
import cmark_gfm

/// GitHub alerts: a blockquote whose first line is `[!NOTE]`, `[!TIP]`,
/// `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`.
enum Alerts {
    struct Alert {
        let kind: String
        let position: String
    }

    private static let kinds = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    /// Finds alert blockquotes and removes the marker from the tree, so it is
    /// not rendered as text. Returns where each one is.
    static func extract(from document: UnsafeMutablePointer<cmark_node>) -> [Alert] {
        // Blockquotes are collected first and edited afterwards: the edits free
        // nodes, and nothing freed may be visited again.
        var quotes: [UnsafeMutablePointer<cmark_node>] = []
        MarkdownRenderer.forEachNode(in: document) { node in
            if cmark_node_get_type(node) == CMARK_NODE_BLOCK_QUOTE { quotes.append(node) }
        }
        var alerts: [Alert] = []
        for node in quotes {
            guard let paragraph = cmark_node_first_child(node),
                cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                let first = cmark_node_first_child(paragraph),
                cmark_node_get_type(first) == CMARK_NODE_TEXT,
                let literal = cmark_node_get_literal(first)
            else { continue }

            let text = String(cString: literal)
            guard let kind = kinds.first(where: { text == "[!\($0)]" }) else { continue }
            // The marker must be alone on its line: followed by a line break
            // or by nothing.
            let next = cmark_node_next(first)
            if let next {
                let type = cmark_node_get_type(next)
                guard type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK else { continue }
                cmark_node_unlink(next)
                cmark_node_free(next)
            }
            cmark_node_unlink(first)
            cmark_node_free(first)
            if cmark_node_first_child(paragraph) == nil {
                cmark_node_unlink(paragraph)
                cmark_node_free(paragraph)
            }
            alerts.append(Alert(kind: kind.lowercased(), position: MarkdownRenderer.sourcePosition(of: node)))
        }
        return alerts
    }

    /// Rewrites one alert's `<blockquote>` in the rendered page as the
    /// `div.markdown-alert` structure GitHub uses.
    static func apply(_ alert: Alert, to page: String) -> String {
        let open = "<blockquote data-sourcepos=\"\(alert.position)\">"
        guard let start = page.range(of: open),
            let close = matchingClose(in: page, from: start.upperBound)
        else { return page }
        let title = alert.kind.prefix(1).uppercased() + alert.kind.dropFirst()
        var result = page
        result.replaceSubrange(close, with: "</div>")
        result.replaceSubrange(
            start,
            with: "<div class=\"markdown-alert markdown-alert-\(alert.kind)\" data-sourcepos=\"\(alert.position)\">"
                + "\n<p class=\"markdown-alert-title\">\(title)</p>")
        return result
    }

    /// The `</blockquote>` that closes the one opened just before `index`,
    /// allowing for blockquotes nested inside it.
    private static func matchingClose(in page: String, from index: String.Index) -> Range<String.Index>? {
        var depth = 1
        var cursor = index
        while cursor < page.endIndex {
            let rest = cursor..<page.endIndex
            let nextOpen = page.range(of: "<blockquote", range: rest)
            guard let nextClose = page.range(of: "</blockquote>", range: rest) else { return nil }
            if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                depth += 1
                cursor = nextOpen.upperBound
            } else {
                depth -= 1
                if depth == 0 { return nextClose }
                cursor = nextClose.upperBound
            }
        }
        return nil
    }
}
