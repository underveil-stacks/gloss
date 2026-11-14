/// An allowlist sanitizer for the HTML that cmark-gfm renders once raw HTML is
/// let through (`CMARK_OPT_UNSAFE`).
///
/// It is a tokenizer and a serializer, not a filter over the input text:
/// nothing reaches the output except tags this file writes itself, from an
/// element name and attribute names it found on the allowlist, with every
/// attribute value double-quoted and escaped, and text with `<` and `>`
/// escaped. Safety therefore does not depend on tokenizing exactly as a browser
/// does. Where the two could disagree, this tokenizer takes the reading that
/// removes more, and whatever is left over is tokenized and filtered again.
///
/// The allowlist is modelled on GitHub's (`html-pipeline`'s
/// `SanitizationFilter`). Differences are listed at `SanitizerPolicy`.
///
/// ## `id`, `name` and in-page links
///
/// A document must not be able to create an element whose `id` or `name` the
/// page's own scripts look up, so what the document names goes into a
/// namespace of its own:
///
/// - Every `id` and `name` value gets the prefix `user-content-`, unless it
///   already starts with it.
/// - An `href` on `<a>` that starts with `#` gets the same prefix after the
///   `#` when, and only when, this input itself contains an `id` or `name`
///   with that value (compared as written, and again with the fragment's
///   percent-escapes decoded). A link to an anchor the document wrote in
///   HTML therefore follows the anchor into the namespace. Any other in-page
///   link is left exactly as written: it can only be aimed at something
///   added after sanitizing, such as a heading's id, and rewriting it would
///   make it miss. A link names nothing, so leaving it alone opens nothing.
/// - Footnotes are the exception to the first rule, because cmark-gfm writes
///   their `id`s and the links between them itself. An `id` starting with
///   `fn-` on an `<li>`, or with `fnref-` on an `<a>`, is left alone, and so
///   is a link to it, whatever else in the document has the same name.
///   The exemption is by element, so `<a id="fn-x">` is prefixed like
///   anything else.
///
/// What the exemption costs: raw HTML can write `<ol><li id="fn-anything">`.
/// Page scripts must not look up ids beginning with `fn-` or `fnref-`.
///
/// Only a literal leading `#` is considered. Links to a fragment in another
/// document (`other.md#part`) are left alone; if that document's anchor was
/// written in HTML, whoever opens it has to add the prefix.
public enum HTMLSanitizer {
    /// Returns `html` with every element, attribute and URL outside the allowlist removed.
    public static func sanitize(_ html: String) -> String {
        sanitize(html, rememberingFailures: true)
    }

    /// For the tests. Remembering which unterminated markup has already been
    /// tried changes how long hostile input takes and must change nothing
    /// else; the tests compare the two.
    static func sanitize(_ html: String, rememberingFailures: Bool) -> String {
        var machine = Machine(html, remembersFailures: rememberingFailures)
        return machine.run()
    }
}

// MARK: - Policy

/// GitHub's allowlist, with these differences:
///
/// - Added elements: `picture` and `source` (GitHub.com allows them for
///   theme-dependent images), `section` (cmark-gfm's footnote wrapper), and
///   the form controls a document may ask its reader to fill in: `input`,
///   `textarea`, `select`, `option`, `optgroup`, `label`, `fieldset` and
///   `legend`. There is still no `form`, so nothing can be submitted, and
///   `input` is refused for the types that could prompt for a secret, reach
///   a file or act on the page (see `inputTypes`).
/// - Added attributes: `id` (namespaced), `class` (known values only),
///   `srcset` and `sizes` on `img` and `source`, `data-sourcepos` (checked
///   against the shape cmark-gfm writes) and cmark-gfm's `data-footnote*`.
/// - Removed: the `action` attribute, a URL that only means anything on the
///   disallowed `form`, and the link schemes `xmpp:`, `irc:`, `ircs:`,
///   `github-windows:` and `github-mac:`.
/// - GitHub removes only `script` together with its content, and relies on
///   cmark-gfm's tagfilter for the rest. The longer list here does not, and
///   Gloss does not attach tagfilter, which would escape `textarea`.
enum SanitizerPolicy {
    static let elements: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8", "br", "b", "i", "strong", "em", "a", "pre",
        "code", "img", "tt", "div", "ins", "del", "sup", "sub", "p", "ol", "ul", "table", "thead",
        "tbody", "tfoot", "blockquote", "dl", "dt", "dd", "kbd", "q", "samp", "var", "hr", "ruby",
        "rt", "rp", "li", "tr", "td", "th", "s", "strike", "summary", "details", "caption",
        "figure", "figcaption", "abbr", "bdo", "cite", "dfn", "mark", "small", "span", "time",
        "wbr", "picture", "source", "section", "input", "textarea", "select", "option", "optgroup",
        "label", "fieldset", "legend",
    ]

    static let voidElements: Set<String> = ["br", "hr", "img", "input", "source", "wbr"]

    /// A browser reads the content of these as text up to the matching end
    /// tag, so this does too. They are removed together with their content,
    /// except an allowed `textarea`, whose content is kept as escaped text.
    static let rawTextElements: Set<String> = [
        "script", "style", "iframe", "noscript", "textarea", "title", "xmp", "noembed",
        "noframes", "plaintext",
    ]

    /// Removed together with their content, which a browser tokenizes as
    /// ordinary markup, so nesting of the same element is counted.
    static let nestedRemovedElements: Set<String> = ["svg", "math", "object", "template"]

    static let globalAttributes: Set<String> = [
        "abbr", "accept", "accept-charset", "accesskey", "align", "alt", "aria-describedby",
        "aria-hidden", "aria-label", "aria-labelledby", "axis", "border", "cellpadding",
        "cellspacing", "char", "charoff", "charset", "checked", "clear", "cols", "colspan",
        "color", "compact", "coords", "datetime", "dir", "disabled", "enctype", "for", "frame",
        "headers", "height", "hreflang", "hspace", "ismap", "label", "lang", "maxlength", "media",
        "method", "multiple", "nohref", "noshade", "nowrap", "open", "progress", "prompt",
        "readonly", "rel", "rev", "role", "rows", "rowspan", "rules", "scope", "selected",
        "shape", "size", "span", "start", "summary", "tabindex", "target", "title", "type",
        "usemap", "valign", "value", "vspace", "width", "itemprop",
        "data-footnotes", "data-footnote-ref", "data-footnote-backref", "data-footnote-backref-idx",
    ]

    /// The only attributes an `input` may keep. Nothing that names a form,
    /// a list, a file or a URL, and no `autofocus` or `autocomplete`.
    static let inputAttributes: Set<String> = [
        "type", "name", "value", "checked", "disabled", "readonly", "class", "id", "placeholder", "min",
        "max", "step", "minlength", "maxlength", "size", "title", "dir", "lang", "aria-label",
        "aria-describedby", "aria-labelledby",
    ]

    /// The `input` types a document may use, compared exactly as written
    /// (lowercased). A missing `type` is a text box. Left out on purpose:
    /// `password` (a document must not be able to ask for one), `file`,
    /// `hidden`, `image`, and the `submit`, `reset` and `button` types.
    static let inputTypes: Set<String> = [
        "text", "search", "number", "range", "date", "time", "datetime-local", "month", "week",
        "email", "url", "tel", "color", "checkbox", "radio",
    ]

    /// Refused whatever the lists above say, so that a careless addition to
    /// them cannot let one of these through. Nothing on the lists is caught
    /// by it today, which is why the tests call it directly.
    static func isForbidden(attribute name: String) -> Bool {
        name.hasPrefix("on") || name == "style" || name == "srcdoc" || name == "formaction"
    }

    static let linkSchemes: Set<String> = ["http", "https", "mailto"]
    static let resourceSchemes: Set<String> = ["http", "https"]

    static func isAllowed(classToken token: String, on element: String) -> Bool {
        switch element {
        case "code": token.hasPrefix("language-")
        case "section": token == "footnotes"
        case "sup": token == "footnote-ref"
        case "a": token == "footnote-backref"
        case "li": token == "task-list-item"
        case "ul", "ol": token == "contains-task-list"
        case "input": token == "task-list-item-checkbox"
        default: false
        }
    }

    /// The open elements a start tag ends without an end tag being written,
    /// as in `<li>one<li>two`. Without this the balancing below would nest
    /// them and then write end tags the browser reads as stray.
    static func impliedlyClosed(by element: String) -> Set<String> {
        switch element {
        case "li": ["p", "li"]
        case "dt", "dd": ["p", "dt", "dd"]
        case "td", "th": ["p", "td", "th"]
        case "tr": ["p", "td", "th", "tr"]
        case "thead", "tbody", "tfoot": ["p", "td", "th", "tr", "thead", "tbody", "tfoot"]
        case "rt", "rp": ["rt", "rp"]
        case "option": ["option"]
        case "optgroup": ["option", "optgroup"]
        case "p", "div", "ul", "ol", "dl", "table", "blockquote", "pre", "hr", "details",
            "summary", "figure", "figcaption", "section", "h1", "h2", "h3", "h4", "h5", "h6":
            ["p"]
        default: []
        }
    }

    /// GitHub's rule: a list item outside a list, or a table part outside a
    /// table, could close a list or table the page itself wraps the document
    /// in. Such a tag is dropped and its content kept.
    static func isContained(_ element: String, in open: [String: Int]) -> Bool {
        switch element {
        case "li": open["ul", default: 0] + open["ol", default: 0] > 0
        case "tr", "td", "th", "thead", "tbody", "tfoot": open["table", default: 0] > 0
        case "option", "optgroup": open["select", default: 0] > 0
        default: true
        }
    }

    static let namespacePrefix = Array("user-content-".utf8)
}

// MARK: - Tokens

private struct Attribute {
    var name: String
    /// Undecoded, as written between the quotes. `nil` for an attribute
    /// written without `=`.
    var value: [UInt8]?
}

private struct Tag {
    /// Lowercased.
    var name: String
    var isEnd = false
    /// The first occurrence of each name, as a browser keeps.
    var attributes: [Attribute] = []
    var selfClosing = false
    /// Quotes, `<` or a leading `=` where a name or an unquoted value should
    /// be: a browser accepts these, but nothing well-meant is written so.
    var malformed = false
    /// The index after the closing `>`.
    var end = 0
}

/// The tokenizer's states inside a tag. The raw values are the bits of
/// `Machine.doomed`.
private enum TagState: UInt16 {
    case tagName = 1
    case beforeAttributeName = 2
    case afterSlash = 4
    case attributeName = 8
    case afterAttributeName = 16
    case beforeAttributeValue = 32
    case doubleQuotedValue = 64
    case singleQuotedValue = 128
    case unquotedValue = 256
}

private enum Byte {
    static let tab: UInt8 = 0x09
    static let space: UInt8 = 0x20
    static let bang = UInt8(ascii: "!")
    static let doubleQuote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let ampersand = UInt8(ascii: "&")
    static let singleQuote = UInt8(ascii: "'")
    static let comma = UInt8(ascii: ",")
    static let dash = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let colon = UInt8(ascii: ":")
    static let semicolon = UInt8(ascii: ";")
    static let lessThan = UInt8(ascii: "<")
    static let equals = UInt8(ascii: "=")
    static let greaterThan = UInt8(ascii: ">")
    static let question = UInt8(ascii: "?")
    static let backtick = UInt8(ascii: "`")
    /// Stand-ins used only while checking a URL; neither byte occurs in UTF-8.
    static let unknownReference: UInt8 = 0xFE
    static let nonASCII: UInt8 = 0xFF

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    static func hexValue(_ byte: UInt8) -> UInt32? {
        if isDigit(byte) { return UInt32(byte - UInt8(ascii: "0")) }
        let lower = byte | 0x20
        if lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "f") {
            return UInt32(lower - UInt8(ascii: "a")) + 10
        }
        return nil
    }

    static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
    }
}

// MARK: - Machine

private struct Machine {
    private let input: [UInt8]
    private var output: [UInt8] = []
    /// Allowed elements written and not yet closed, and how many of each.
    private var open: [String] = []
    private var openCount: [String: Int] = [:]
    /// Set while inside an element of `SanitizerPolicy.nestedRemovedElements`.
    private var removing: (name: String, depth: Int)?
    /// The `id` and `name` values in the namespace, without the prefix, and
    /// the footnote ids left out of it. Both as they are written to the
    /// output, so that sanitizing the output again compares the same bytes.
    private var namespacedNames: Set<[UInt8]> = []
    private var footnoteIDs: Set<[UInt8]> = []
    /// In-page links, by where in `output` the fragment starts. Whether one
    /// gets the prefix is known only once every id has been seen: a link can
    /// come before its target.
    private var fragments: [(offset: Int, fragment: [UInt8])] = []

    /// In-page links of the tag about to be written, by attribute position.
    private var pendingFragments: [(attribute: Int, fragment: [UInt8])] = []

    // A hostile document can be made of thousands of tags and comments that
    // never end. Each is text, and the next one is tried from the character
    // after its `<`; left alone, every try would read to the end of the
    // input again. These remember what is already known to fail.

    /// One bit per `TagState` for each input byte: set where a tag that
    /// reaches that byte in that state runs into the end of the input.
    /// Allocated when a tag first fails.
    private var doomed: [UInt16] = []
    /// No comment, CDATA section or `>` ends at or after these positions.
    private var noCommentEndFrom = Int.max
    private var noSectionEndFrom = Int.max
    private var noGreaterThanFrom = Int.max

    private let remembersFailures: Bool

    init(_ html: String, remembersFailures: Bool) {
        self.remembersFailures = remembersFailures
        // A browser replaces or ignores NUL depending on the state it is in;
        // removing it first means there is one reading.
        input = html.utf8.filter { $0 != 0 }
        output.reserveCapacity(input.count + input.count / 8)
    }

    mutating func run() -> String {
        var index = 0
        while index < input.count {
            if input[index] == Byte.lessThan {
                index = markup(at: index)
            } else {
                var end = index
                while end < input.count, input[end] != Byte.lessThan { end += 1 }
                text(index..<end)
                index = end
            }
        }
        while let element = open.popLast() { writeEndTag(element) }
        openCount.removeAll()
        return String(decoding: resolvingFragments(), as: UTF8.self)
    }

    // MARK: Data and markup declarations

    private mutating func text(_ range: Range<Int>) {
        guard removing == nil else { return }
        for byte in input[range] {
            switch byte {
            case Byte.lessThan: output.append(contentsOf: "&lt;".utf8)
            case Byte.greaterThan: output.append(contentsOf: "&gt;".utf8)
            default: output.append(byte)
            }
        }
    }

    /// Handles the `<` at `start` and returns where to continue. A `<` that
    /// does not begin a complete tag, comment or declaration is text: it is
    /// escaped, and tokenizing continues with the character after it.
    private mutating func markup(at start: Int) -> Int {
        let next = start + 1 < input.count ? input[start + 1] : 0
        if Byte.isLetter(next) || (next == Byte.slash && start + 2 < input.count && Byte.isLetter(input[start + 2])) {
            if let tag = parseTag(at: start) {
                return handle(tag)
            }
        } else if next == Byte.bang || next == Byte.question || next == Byte.slash {
            if let end = declarationEnd(at: start) {
                return end
            }
        }
        text(start..<start + 1)
        return start + 1
    }

    /// The index after a comment, CDATA section, doctype, processing
    /// instruction or `</` followed by a non-letter, or `nil` if it never ends.
    private mutating func declarationEnd(at start: Int) -> Int? {
        if matches("<!--", at: start) {
            var index = start + 4
            // `<!-->` and `<!--->` are complete, empty comments.
            if index < input.count, input[index] == Byte.greaterThan { return index + 1 }
            if matches("->", at: index) { return index + 2 }
            guard index < noCommentEndFrom else { return nil }
            let searchStart = index
            while index < input.count {
                if matches("-->", at: index) { return index + 3 }
                if matches("--!>", at: index) { return index + 4 }
                index += 1
            }
            if remembersFailures { noCommentEndFrom = searchStart }
            return nil
        }
        if matches("<![CDATA[", at: start), start + 9 < noSectionEndFrom {
            var index = start + 9
            while index < input.count {
                if matches("]]>", at: index) { return index + 3 }
                index += 1
            }
            if remembersFailures { noSectionEndFrom = start + 9 }
            // Unterminated: fall through to the browser's reading outside
            // SVG and MathML, a comment that ends at the first `>`.
        }
        var index = start + 2
        guard index < noGreaterThanFrom else { return nil }
        while index < input.count {
            if input[index] == Byte.greaterThan { return index + 1 }
            index += 1
        }
        if remembersFailures { noGreaterThanFrom = start + 2 }
        return nil
    }

    private func matches(_ literal: StaticString, at index: Int) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard index + count <= input.count else { return false }
        return literal.withUTF8Buffer { buffer in
            for offset in 0..<count where input[index + offset] != buffer[offset] { return false }
            return true
        }
    }

    // MARK: Tags

    /// Parses the start or end tag at `start`, where `input[start]` is `<`
    /// and a name follows. Returns `nil` if the input ends inside the tag.
    /// The states and their transitions are those of the HTML standard's
    /// tokenizer, with "after attribute value (quoted)" folded into "before
    /// attribute name", which treats every character the same way.
    private mutating func parseTag(at start: Int) -> Tag? {
        let count = input.count
        var index = start + 1
        var tag = Tag(name: "")
        if input[index] == Byte.slash {
            tag.isEnd = true
            index += 1
        }
        var state = TagState.tagName
        // Where the name or value being read began.
        var mark = index
        var attribute = Attribute(name: "")
        var seen: Set<String> = []
        // The first and last byte read in each state, for `doomed`.
        var trail: [(state: TagState, from: Int, through: Int)] = [(state, index, index)]

        func keep(_ attribute: Attribute, in tag: inout Tag) {
            if seen.insert(attribute.name).inserted {
                tag.attributes.append(attribute)
            }
        }

        scan: while index < count {
            if !doomed.isEmpty, doomed[index] & state.rawValue != 0 { break scan }
            let byte = input[index]
            let read = index
            let previous = state

            switch state {
            case .tagName:
                // Everything up to whitespace, `/` or `>`. That includes `<`,
                // so `<scr<script>` is one tag with a name no list contains.
                if Byte.isSpace(byte) || byte == Byte.slash || byte == Byte.greaterThan {
                    tag.name = lowercasedString(mark..<index)
                    state = .beforeAttributeName
                } else {
                    index += 1
                }

            case .beforeAttributeName:
                if Byte.isSpace(byte) {
                    index += 1
                } else if byte == Byte.slash {
                    state = .afterSlash
                    index += 1
                } else if byte == Byte.greaterThan {
                    tag.end = index + 1
                    return tag
                } else {
                    // Whatever it is, it starts a name; a leading `=` too.
                    if byte == Byte.equals || byte == Byte.doubleQuote || byte == Byte.singleQuote
                        || byte == Byte.lessThan
                    {
                        tag.malformed = true
                    }
                    mark = index
                    state = .attributeName
                    index += 1
                }

            case .afterSlash:
                // A `/` not followed by `>` separates attributes exactly as
                // whitespace does.
                if byte == Byte.greaterThan {
                    tag.selfClosing = true
                    tag.end = index + 1
                    return tag
                }
                state = .beforeAttributeName

            case .attributeName:
                if Byte.isSpace(byte) || byte == Byte.slash || byte == Byte.greaterThan || byte == Byte.equals {
                    attribute = Attribute(name: lowercasedString(mark..<index))
                    state = .afterAttributeName
                } else {
                    if byte == Byte.doubleQuote || byte == Byte.singleQuote || byte == Byte.lessThan {
                        tag.malformed = true
                    }
                    index += 1
                }

            case .afterAttributeName:
                if Byte.isSpace(byte) {
                    index += 1
                } else if byte == Byte.equals {
                    state = .beforeAttributeValue
                    index += 1
                } else {
                    keep(attribute, in: &tag)
                    state = .beforeAttributeName
                }

            case .beforeAttributeValue:
                if Byte.isSpace(byte) {
                    index += 1
                } else if byte == Byte.doubleQuote || byte == Byte.singleQuote {
                    state = byte == Byte.doubleQuote ? .doubleQuotedValue : .singleQuotedValue
                    index += 1
                    mark = index
                } else if byte == Byte.greaterThan {
                    attribute.value = []
                    keep(attribute, in: &tag)
                    state = .beforeAttributeName
                } else {
                    mark = index
                    state = .unquotedValue
                }

            case .doubleQuotedValue, .singleQuotedValue:
                if byte == (state == .doubleQuotedValue ? Byte.doubleQuote : Byte.singleQuote) {
                    attribute.value = Array(input[mark..<index])
                    keep(attribute, in: &tag)
                    state = .beforeAttributeName
                }
                index += 1

            case .unquotedValue:
                // Up to whitespace or `>`. A `/` is part of the value.
                if Byte.isSpace(byte) || byte == Byte.greaterThan {
                    attribute.value = Array(input[mark..<index])
                    keep(attribute, in: &tag)
                    state = .beforeAttributeName
                } else {
                    if byte == Byte.doubleQuote || byte == Byte.singleQuote || byte == Byte.lessThan
                        || byte == Byte.backtick
                    {
                        tag.malformed = true
                    }
                    index += 1
                }
            }

            if state != previous {
                trail[trail.count - 1].through = read
                trail.append((state, index, index))
            }
        }

        // The input ended, or the tag reached a byte in a state already
        // known to end that way. What happens from a byte depends only on the
        // byte's position and the state, so everything this tag passed
        // through ends that way too.
        guard remembersFailures else { return nil }
        if doomed.isEmpty { doomed = Array(repeating: 0, count: count) }
        trail[trail.count - 1].through = index - 1
        for step in trail where step.from <= step.through {
            for position in step.from...min(step.through, count - 1) {
                doomed[position] |= step.state.rawValue
            }
        }
        return nil
    }

    private func lowercasedString(_ range: Range<Int>) -> String {
        String(decoding: input[range].map(Byte.lowercased), as: UTF8.self)
    }

    /// Acts on a complete tag and returns where to continue.
    private mutating func handle(_ tag: Tag) -> Int {
        if tag.isEnd {
            if let current = removing {
                if tag.name == current.name {
                    removing = current.depth > 1 ? (current.name, current.depth - 1) : nil
                }
            } else {
                close(tag.name)
            }
            return tag.end
        }

        // Decided on the name alone, before anything can disqualify the tag:
        // `<script "">` still starts a script.
        if SanitizerPolicy.rawTextElements.contains(tag.name) {
            let end = rawTextEnd(of: tag.name, from: tag.end)
            if tag.name == "textarea", removing == nil, !tag.malformed,
                let attributes = filteredAttributes(of: tag)
            {
                // The content is written as text, with `<` escaped, so it
                // cannot contain the end tag that closes it early; the end
                // tag is always written, so it cannot run on either.
                writeStartTag(tag.name, attributes, selfClosing: false)
                text(tag.end..<end.contentEnd)
                writeEndTag(tag.name)
            }
            return end.end
        }
        // Only SVG and MathML honour `/>`.
        let opens = !(tag.selfClosing && (tag.name == "svg" || tag.name == "math"))
        if let current = removing {
            if tag.name == current.name, opens {
                removing = (current.name, current.depth + 1)
            }
            return tag.end
        }
        if SanitizerPolicy.nestedRemovedElements.contains(tag.name) {
            if opens { removing = (tag.name, 1) }
            return tag.end
        }
        guard !tag.malformed, SanitizerPolicy.elements.contains(tag.name),
            SanitizerPolicy.isContained(tag.name, in: openCount), let attributes = filteredAttributes(of: tag)
        else {
            return tag.end
        }

        let implied = SanitizerPolicy.impliedlyClosed(by: tag.name)
        while let top = open.last, implied.contains(top) {
            closeInnermost()
        }
        let isVoid = SanitizerPolicy.voidElements.contains(tag.name)
        writeStartTag(tag.name, attributes, selfClosing: isVoid && tag.selfClosing)
        if !isVoid {
            open.append(tag.name)
            openCount[tag.name, default: 0] += 1
        }
        return tag.end
    }

    /// Where the content of the raw-text element `name` ends and the index
    /// after the end tag that closes it, searching from `start`. With no end
    /// tag the element runs to the end of the input, as it does in a browser.
    private mutating func rawTextEnd(of name: String, from start: Int) -> (contentEnd: Int, end: Int) {
        let needle = Array(name.utf8)
        var index = start
        while index + 2 + needle.count < input.count {
            if input[index] == Byte.lessThan, input[index + 1] == Byte.slash {
                var matched = true
                for offset in 0..<needle.count where Byte.lowercased(input[index + 2 + offset]) != needle[offset] {
                    matched = false
                    break
                }
                let after = input[index + 2 + needle.count]
                if matched, Byte.isSpace(after) || after == Byte.slash || after == Byte.greaterThan {
                    return (index, parseTag(at: index)?.end ?? input.count)
                }
            }
            index += 1
        }
        return (input.count, input.count)
    }

    /// Writes the end tag for the innermost open `element`, closing what is
    /// open inside it first. An end tag with nothing to close is dropped, so
    /// the output can never close an element it did not open.
    private mutating func close(_ element: String) {
        // Asked of the count, not the stack: a long run of stray end tags
        // must not search a deep stack once each.
        guard openCount[element, default: 0] > 0 else { return }
        while let top = open.last {
            closeInnermost()
            if top == element { break }
        }
    }

    private mutating func closeInnermost() {
        let element = open.removeLast()
        openCount[element, default: 1] -= 1
        writeEndTag(element)
    }

    // MARK: Attributes

    /// The attributes of `tag` that may be written, or `nil` if the element
    /// itself must be dropped.
    private mutating func filteredAttributes(of tag: Tag) -> [Attribute]? {
        var kept: [Attribute] = []
        var fragmentLinks: [(attribute: Int, fragment: [UInt8])] = []

        for attribute in tag.attributes {
            let name = attribute.name
            if SanitizerPolicy.isForbidden(attribute: name) { continue }
            if tag.name == "input", !SanitizerPolicy.inputAttributes.contains(name) { continue }
            var value = attribute.value

            switch name {
            case "id", "name":
                guard let written = value, !written.isEmpty else { continue }
                let isFootnote =
                    name == "id"
                    && ((tag.name == "li" && written.starts(with: "fn-".utf8))
                        || (tag.name == "a" && written.starts(with: "fnref-".utf8)))
                let prefix = SanitizerPolicy.namespacePrefix
                if isFootnote {
                    footnoteIDs.insert(Self.escaped(written))
                } else if written.starts(with: prefix) {
                    namespacedNames.insert(Self.escaped(Array(written.dropFirst(prefix.count))))
                } else {
                    namespacedNames.insert(Self.escaped(written))
                    value = prefix + written
                }
            case "for":
                // Refers to an `id`, which is namespaced, so it follows it in.
                guard tag.name == "label", let written = value, !written.isEmpty else { continue }
                let prefix = SanitizerPolicy.namespacePrefix
                if !written.starts(with: prefix) { value = prefix + written }
            case "placeholder", "minlength":
                guard tag.name == "input" || tag.name == "textarea" else { continue }
            case "min", "max", "step":
                guard tag.name == "input" else { continue }
            case "class":
                let tokens = (value ?? []).split(whereSeparator: Byte.isSpace).filter {
                    SanitizerPolicy.isAllowed(classToken: String(decoding: $0, as: UTF8.self), on: tag.name)
                }
                guard !tokens.isEmpty else { continue }
                value = Array(tokens.joined(separator: [Byte.space]))
            case "href":
                guard tag.name == "a", Self.isAllowedURL(value ?? [], schemes: SanitizerPolicy.linkSchemes) else { continue }
                if let written = value, written.count > 1, written[0] == Byte.hash {
                    fragmentLinks.append((kept.count, Array(written.dropFirst())))
                }
            case "src", "longdesc":
                guard tag.name == "img", Self.isAllowedURL(value ?? [], schemes: SanitizerPolicy.resourceSchemes) else {
                    continue
                }
            case "cite":
                guard ["blockquote", "del", "ins", "q"].contains(tag.name),
                    Self.isAllowedURL(value ?? [], schemes: SanitizerPolicy.resourceSchemes)
                else { continue }
            case "srcset":
                guard tag.name == "img" || tag.name == "source", Self.isAllowedSourceSet(value ?? []) else {
                    continue
                }
            case "sizes":
                guard tag.name == "img" || tag.name == "source" else { continue }
            case "itemscope", "itemtype":
                guard tag.name == "div" else { continue }
            case "data-sourcepos":
                guard Self.isSourcePosition(value ?? []) else { continue }
            default:
                guard SanitizerPolicy.globalAttributes.contains(name) else { continue }
            }
            kept.append(Attribute(name: name, value: value))
        }

        if tag.name == "input" {
            // The first `type` a browser sees decides; the tokenizer kept only that one.
            if let type = tag.attributes.first(where: { $0.name == "type" }) {
                let written = String(decoding: (type.value ?? []).map(Byte.lowercased), as: UTF8.self)
                guard SanitizerPolicy.inputTypes.contains(written) else { return nil }
            }
        }
        pendingFragments = fragmentLinks
        return kept
    }

    private static func isSourcePosition(_ value: [UInt8]) -> Bool {
        // line:column-line:column
        var index = 0
        for separator in [Byte.colon, Byte.dash, Byte.colon, nil] {
            let start = index
            while index < value.count, Byte.isDigit(value[index]) { index += 1 }
            guard index > start else { return false }
            if let separator {
                guard index < value.count, value[index] == separator else { return false }
                index += 1
            }
        }
        return index == value.count
    }

    // MARK: URLs

    /// Whether a browser would resolve `value` as a relative URL or as one
    /// with a scheme in `schemes`.
    private static func isAllowedURL(_ value: [UInt8], schemes: Set<String>) -> Bool {
        isAllowedURL(decoded: decodedForCheck(value)[...], schemes: schemes)
    }

    private static func isAllowedURL(decoded: ArraySlice<UInt8>, schemes: Set<String>) -> Bool {
        // A browser drops tabs and newlines anywhere in a URL and control
        // characters and spaces around it. Dropping all of them everywhere
        // can only make more values look like they have a scheme.
        let stripped = decoded.filter { $0 > 0x20 && $0 != 0x7F }
        let delimiters = [Byte.colon, Byte.slash, Byte.question, Byte.hash]
        let cut = stripped.firstIndex(where: delimiters.contains) ?? stripped.endIndex
        let head = stripped[..<cut]
        if cut < stripped.endIndex, stripped[cut] == Byte.colon {
            // Anything before the first colon is taken as a scheme, whether or
            // not a browser would agree, and must be exactly an allowed one.
            return schemes.contains(String(decoding: head.map(Byte.lowercased), as: UTF8.self))
        }
        // Relative. A character reference this file cannot decode might be
        // the colon it did not see.
        return !head.contains(Byte.unknownReference)
    }

    /// `srcset` is a comma-separated list of URLs, each optionally followed
    /// by a descriptor. A URL may itself contain commas, so every piece is
    /// checked as if a URL started there, descriptor and all: a descriptor
    /// has no colon, so it cannot make an allowed URL look like a scheme.
    private static func isAllowedSourceSet(_ value: [UInt8]) -> Bool {
        let decoded = decodedForCheck(value)
        guard !decoded.contains(Byte.unknownReference) else { return false }
        return decoded.split(separator: Byte.comma).allSatisfy {
            isAllowedURL(decoded: $0, schemes: SanitizerPolicy.resourceSchemes)
        }
    }

    /// Named references that produce an ASCII character and matter to a URL
    /// check, plus the ones this file writes. A browser knows about two
    /// thousand more; any other name comes back as `Byte.unknownReference`.
    private static let namedReferences: [String: UInt8] = [
        "amp": 0x26, "AMP": 0x26, "lt": 0x3C, "LT": 0x3C, "gt": 0x3E, "GT": 0x3E, "quot": 0x22,
        "QUOT": 0x22, "apos": 0x27, "colon": 0x3A, "Tab": 0x09, "NewLine": 0x0A, "sol": 0x2F,
        "quest": 0x3F, "num": 0x23, "comma": 0x2C, "period": 0x2E, "grave": 0x60,
    ]

    /// `value` with character references decoded, for inspection only: the
    /// result is never written. Non-ASCII results become `Byte.nonASCII`.
    private static func decodedForCheck(_ value: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(value.count)
        var index = 0
        while index < value.count {
            let byte = value[index]
            guard byte == Byte.ampersand, index + 1 < value.count else {
                result.append(byte)
                index += 1
                continue
            }
            var cursor = index + 1
            if value[cursor] == Byte.hash {
                // Numeric. A browser decodes these with or without the `;`.
                cursor += 1
                var isHex = false
                if cursor < value.count, value[cursor] | 0x20 == UInt8(ascii: "x") {
                    isHex = true
                    cursor += 1
                }
                var scalar: UInt32 = 0
                let digitsStart = cursor
                while cursor < value.count, let digit = Byte.hexValue(value[cursor]), isHex || digit < 10 {
                    scalar = min(scalar * (isHex ? 16 : 10) + digit, 0x11_0000)
                    cursor += 1
                }
                if cursor > digitsStart {
                    if cursor < value.count, value[cursor] == Byte.semicolon { cursor += 1 }
                    result.append(scalar > 0 && scalar < 0x80 ? UInt8(scalar) : Byte.nonASCII)
                    index = cursor
                    continue
                }
            } else if Byte.isLetter(value[cursor]) {
                // Named. Only the `;` form: the names a browser accepts
                // without it produce no character a URL check cares about.
                while cursor < value.count, Byte.isLetter(value[cursor]) || Byte.isDigit(value[cursor]) { cursor += 1 }
                if cursor < value.count, value[cursor] == Byte.semicolon {
                    let name = String(decoding: value[(index + 1)..<cursor], as: UTF8.self)
                    result.append(namedReferences[name] ?? Byte.unknownReference)
                    index = cursor + 1
                    continue
                }
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    // MARK: Output

    private mutating func writeStartTag(_ name: String, _ attributes: [Attribute], selfClosing: Bool) {
        output.append(Byte.lessThan)
        output.append(contentsOf: name.utf8)
        for (position, attribute) in attributes.enumerated() {
            output.append(Byte.space)
            output.append(contentsOf: attribute.name.utf8)
            guard let value = attribute.value else { continue }
            output.append(Byte.equals)
            output.append(Byte.doubleQuote)
            if let link = pendingFragments.first(where: { $0.attribute == position }) {
                // The value is "#" + fragment; note where the fragment starts.
                fragments.append((output.count + 1, link.fragment))
            }
            output.append(contentsOf: Self.escaped(value))
            output.append(Byte.doubleQuote)
        }
        pendingFragments = []
        if selfClosing { output.append(contentsOf: " /".utf8) }
        output.append(Byte.greaterThan)
    }

    private mutating func writeEndTag(_ name: String) {
        output.append(contentsOf: "</".utf8)
        output.append(contentsOf: name.utf8)
        output.append(Byte.greaterThan)
    }

    /// Values are written undecoded, so a reference means afterwards what it
    /// meant before. An `&` is escaped unless it starts something shaped like
    /// a reference; one a browser would have decoded without its `;` thereby
    /// becomes literal text.
    private static func escaped(_ value: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(value.count)
        for (index, byte) in value.enumerated() {
            switch byte {
            case Byte.doubleQuote: output.append(contentsOf: "&quot;".utf8)
            case Byte.singleQuote: output.append(contentsOf: "&#39;".utf8)
            case Byte.backtick: output.append(contentsOf: "&#96;".utf8)
            case Byte.lessThan: output.append(contentsOf: "&lt;".utf8)
            case Byte.greaterThan: output.append(contentsOf: "&gt;".utf8)
            case Byte.ampersand where !Self.startsReference(value, at: index):
                output.append(contentsOf: "&amp;".utf8)
            default: output.append(byte)
            }
        }
        return output
    }

    /// Whether `value[index]`, an `&`, starts `&name;`, `&#1;` or `&#x1;`.
    private static func startsReference(_ value: [UInt8], at index: Int) -> Bool {
        var cursor = index + 1
        guard cursor < value.count else { return false }
        let start: Int
        if value[cursor] == Byte.hash {
            cursor += 1
            if cursor < value.count, value[cursor] | 0x20 == UInt8(ascii: "x") {
                cursor += 1
                start = cursor
                while cursor < value.count, Byte.hexValue(value[cursor]) != nil { cursor += 1 }
            } else {
                start = cursor
                while cursor < value.count, Byte.isDigit(value[cursor]) { cursor += 1 }
            }
        } else {
            start = cursor
            guard Byte.isLetter(value[cursor]) else { return false }
            while cursor < value.count, Byte.isLetter(value[cursor]) || Byte.isDigit(value[cursor]) { cursor += 1 }
        }
        return cursor > start && cursor < value.count && value[cursor] == Byte.semicolon
    }

    private static func percentDecoded(_ value: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(value.count)
        var index = 0
        while index < value.count {
            if value[index] == UInt8(ascii: "%"), index + 2 < value.count,
                let high = Byte.hexValue(value[index + 1]), let low = Byte.hexValue(value[index + 2])
            {
                result.append(UInt8(high * 16 + low))
                index += 3
            } else {
                result.append(value[index])
                index += 1
            }
        }
        return result
    }

    /// The output, with the namespace prefix inserted into every in-page
    /// link whose target this input put in the namespace.
    private func resolvingFragments() -> [UInt8] {
        let pending = fragments.filter { link in
            guard !link.fragment.starts(with: SanitizerPolicy.namespacePrefix) else { return false }
            // Escaped before anything else, as the names are: the answer must
            // be the same when this output is sanitized again.
            let written = Self.escaped(link.fragment)
            guard !footnoteIDs.contains(written) else { return false }
            return namespacedNames.contains(written)
                || namespacedNames.contains(Self.escaped(Self.percentDecoded(written)))
        }
        guard !pending.isEmpty else { return output }
        var result: [UInt8] = []
        result.reserveCapacity(output.count + pending.count * SanitizerPolicy.namespacePrefix.count)
        var copied = 0
        for link in pending {
            result.append(contentsOf: output[copied..<link.offset])
            result.append(contentsOf: SanitizerPolicy.namespacePrefix)
            copied = link.offset
        }
        result.append(contentsOf: output[copied...])
        return result
    }
}
