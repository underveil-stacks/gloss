import AppKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "gloss", category: "forms")

/// One form field as the page describes it. The page's answer is decoded
/// strictly: it comes from a page showing an untrusted document, so it is
/// checked and written out again here, never passed along as it came.
struct FormField: Codable, Equatable, Sendable {
    var type: String
    var name: String?
    var section: String?
    var row: String?
    var column: String?
    var label: String?
    /// The line in the file the field is on, when Gloss can tell.
    var line: Int?
    var value: FormValue
    /// For a group of radio buttons or checkboxes: every choice offered.
    var options: [String]?

    /// A readable key: the field's name, or where it is.
    var key: String {
        if let name, !name.isEmpty { return name }
        let path = [section, row, column, label].compactMap { $0 }.filter { !$0.isEmpty }
        return path.isEmpty ? type : path.joined(separator: " / ")
    }
}

enum FormValue: Codable, Equatable, Sendable {
    case text(String)
    case flag(Bool)
    case list([String])
    case none

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .list(try container.decode([String].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .flag(let flag): try container.encode(flag)
        case .list(let list): try container.encode(list)
        case .none: try container.encodeNil()
        }
    }
}

/// What an export contains: every field, and a flat map of the same values
/// for whoever only wants the answers.
struct FormExport: Encodable {
    var document: String
    var exported: String
    var values: [String: FormValue]
    var fields: [FormField]

    init(document: String, exported: Date, fields: [FormField]) {
        self.document = document
        self.exported = exported.ISO8601Format()
        self.fields = fields
        var values: [String: FormValue] = [:]
        var counts: [String: Int] = [:]
        for field in fields {
            let key = field.key
            counts[key, default: 0] += 1
            let count = counts[key]!
            values[count == 1 ? key : "\(key) (\(count))"] = field.value
        }
        self.values = values
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Copying, saving and sharing a document's answers. Each counts as an export,
/// so closing the window afterwards does not warn.
@MainActor
enum FormExporter {
    static func copy(_ model: PageModel) async {
        do {
            let json = try await model.exportForm()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: json, as: UTF8.self), forType: .string)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Returns whether a file was written.
    @discardableResult
    static func save(_ model: PageModel) async -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let name = model.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        panel.nameFieldStringValue = "\(name) form.json"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try await model.exportForm().write(to: url, options: .atomic)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func share(_ model: PageModel) async {
        guard let view = NSApp.keyWindow?.contentView else { return }
        do {
            let export = try await model.formJSON()
            let picker = NSSharingServicePicker(items: [String(decoding: export.json, as: UTF8.self)])
            let delegate = ShareDelegate { model.markExported(export.fields) }
            picker.delegate = delegate
            ShareDelegate.active = delegate
            let anchor = NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 4, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @MainActor
    private final class ShareDelegate: NSObject, @MainActor NSSharingServicePickerDelegate {
        static var active: ShareDelegate?
        let chosen: () -> Void
        init(chosen: @escaping () -> Void) { self.chosen = chosen }

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service != nil { chosen() }
            Self.active = nil
        }
    }
}

/// Answers typed into a page are kept nowhere but the page, so closing a
/// window that holds answers not yet exported asks first.
///
/// SwiftUI owns the window's delegate. This stands in front of it, forwards
/// everything, and answers only `windowShouldClose` and
/// `windowWillReturnUndoManager`. It also keeps the document from ever being
/// marked as edited (see `init`).
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {
    /// Read by the forwarding overrides, which AppKit calls on the main
    /// thread but which cannot be marked so.
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private weak var model: PageModel?
    private var confirmed = false

    init(model: PageModel) {
        self.model = model
        super.init()
    }

    /// Makes this the window's delegate, keeping whatever it replaces to
    /// forward to. Called again whenever the window becomes key: if anything
    /// has put its own delegate back, the guard returns in front of it
    /// instead of silently going away, and says so in the log.
    func attach(to window: NSWindow) {
        guard window.delegate !== self else { return }
        if attached {
            log.error("the window's delegate was replaced; the close guard put itself back in front of it")
        }
        original = window.delegate
        window.delegate = self
        if !attached {
            attached = true
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let self, let window { self.attach(to: window) }
                }
            }
        }
        // Typing into a field registers undo actions. With the document's undo
        // manager in reach, SwiftUI counts each one as an edit to the file and
        // macOS tries (and fails) to autosave it. A viewer has nothing to undo,
        // so the document has no undo manager; the window then asks this
        // delegate, which gives the page one of its own.
        (window.windowController?.document as? NSDocument)?.hasUndoManager = false
    }

    private var attached = false

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    /// Undo for typing in the page's fields, kept apart from the document.
    private let pageUndoManager = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        return pageUndoManager
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard !confirmed, let model, model.formFieldCount > 0 else {
            confirmed = false
            return original?.windowShouldClose?(window) ?? true
        }
        Task { await ask(window, model) }
        return false
    }

    private func ask(_ window: NSWindow, _ model: PageModel) async {
        guard await model.hasUnexportedAnswers() else { return close(window) }
        let alert = Self.alert(
            message: "Export your answers before closing?",
            detail: "You filled in fields in \u{201C}\(model.fileURL?.lastPathComponent ?? "this document")\u{201D}. "
                + "Gloss never changes the file, so your answers are lost when the window closes unless you export them.")
        alert.addButton(withTitle: "Save as JSON\u{2026}")
        alert.addButton(withTitle: "Copy and Close")
        let discard = alert.addButton(withTitle: "Close Without Exporting")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn:
            if await FormExporter.save(model) { close(window) }
        case .alertSecondButtonReturn:
            await FormExporter.copy(model)
            close(window)
        case .alertThirdButtonReturn:
            close(window)
        default:
            break
        }
    }

    /// For a document window, `performClose` may ask the document first and
    /// reach `windowShouldClose` later, so the confirmation is used up there,
    /// not reset here.
    private func close(_ window: NSWindow) {
        confirmed = true
        window.performClose(nil)
    }

    static func alert(message: String, detail: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        return alert
    }

    /// Asked when the app is about to quit.
    static func confirmQuit() async -> Bool {
        var waiting: [String] = []
        for model in PageRegistry.all where await model.hasUnexportedAnswers() {
            waiting.append(model.fileURL?.lastPathComponent ?? "Untitled")
        }
        guard !waiting.isEmpty else { return true }
        let names = waiting.map { "\u{201C}\($0)\u{201D}" }.formatted(.list(type: .and))
        let alert = alert(
            message: waiting.count == 1
                ? "A document has answers you haven\u{2019}t exported."
                : "\(waiting.count) documents have answers you haven\u{2019}t exported.",
            detail: "Answers typed into \(names) are lost when Gloss quits unless you export them.")
        alert.addButton(withTitle: "Don\u{2019}t Quit")
        alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
